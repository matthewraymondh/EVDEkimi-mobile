#!/usr/bin/env node
/**
 * Zero-dependency mock backend for EVDEkimi AI.
 *
 *   node tools/mock_server.js            # listens on :3001
 *   PORT=4000 node tools/mock_server.js
 *
 * Why a script rather than a Mockoon export: the interesting behaviour of this
 * app is a *streaming* chat endpoint, and a real server-sent-events response —
 * chunked, token-paced, with a `[DONE]` terminator and occasional injected
 * failures — is what actually exercises the client. Static mock tooling replays
 * a fixed body in one write, which would make the SSE parser look fine even if
 * it could not handle chunk boundaries at all.
 *
 * Deliberate rough edges, so the client is tested against reality:
 *   - Tokens are emitted with jittered delays, and a token is sometimes split
 *     across two TCP writes mid-word.
 *   - Access tokens expire after ACCESS_TOKEN_TTL_MS, forcing a real refresh
 *     round trip (and exercising the single-flight refresh in AuthInterceptor).
 *   - `?scenario=` on /chat/completions injects specific failures.
 *
 * Scenarios:
 *   ?scenario=slow          long pause before the first token (idle timeout)
 *   ?scenario=error         200 then an error event mid-stream
 *   ?scenario=truncate      stream closes without [DONE]
 *   ?scenario=ratelimit     429 with Retry-After
 *   ?scenario=server        500 before streaming starts
 */

'use strict';

const http = require('node:http');
const crypto = require('node:crypto');

const PORT = Number(process.env.PORT || 3001);
const ACCESS_TOKEN_TTL_MS = Number(process.env.ACCESS_TOKEN_TTL_MS || 5 * 60_000);

/** In-memory state. Resets on restart, which is fine for a mock. */
const sessions = new Map(); // accessToken -> { email, expiresAt }
const refreshTokens = new Map(); // refreshToken -> email
const uploads = new Map();

const MODELS = [
  {
    id: 'gpt-4o-mini',
    name: 'Aurora Mini',
    provider: 'evdekimi-cloud',
    engine: 'remote',
    context_window: 128000,
    supports_streaming: true,
    supports_vision: true,
    is_default: true,
    description: 'Fast general-purpose model. Good default for everyday chat.',
  },
  {
    id: 'gpt-4o',
    name: 'Aurora Large',
    provider: 'evdekimi-cloud',
    engine: 'remote',
    context_window: 128000,
    supports_streaming: true,
    supports_vision: true,
    description: 'Stronger reasoning, slower and more expensive.',
  },
  {
    id: 'llama-3.1-8b',
    name: 'Llama 3.1 8B',
    provider: 'together',
    engine: 'remote',
    context_window: 32768,
    supports_streaming: true,
    supports_vision: false,
    description: 'Open-weights model. Cheap, no vision support.',
  },
];

// --------------------------------------------------------------------------
// Helpers
// --------------------------------------------------------------------------

const token = (prefix) => `${prefix}_${crypto.randomBytes(18).toString('hex')}`;
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const jitter = (base, spread) => base + Math.floor(Math.random() * spread);

function sendJson(res, status, body, headers = {}) {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(payload),
    ...headers,
  });
  res.end(payload);
}

function sendError(res, status, message, code, extra = {}) {
  // Nested envelope, matching what most hosted providers emit — and what
  // ErrorMapper.parseApiException is written to tolerate.
  sendJson(res, status, { error: { message, code }, ...extra });
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > 25 * 1024 * 1024) {
        reject(new Error('payload too large'));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => {
      const raw = Buffer.concat(chunks).toString('utf8');
      if (!raw) return resolve({});
      try {
        resolve(JSON.parse(raw));
      } catch {
        // Multipart uploads land here; we only care about the size.
        resolve({ __raw: raw });
      }
    });
    req.on('error', reject);
  });
}

function issueSession(email) {
  const accessToken = token('at');
  const refreshToken = token('rt');
  const expiresAt = Date.now() + ACCESS_TOKEN_TTL_MS;

  sessions.set(accessToken, { email, expiresAt });
  refreshTokens.set(refreshToken, email);

  return {
    access_token: accessToken,
    refresh_token: refreshToken,
    // Relative seconds, the more common of the two shapes the client parses.
    expires_in: Math.floor(ACCESS_TOKEN_TTL_MS / 1000),
    token_type: 'Bearer',
    user: {
      id: crypto.createHash('sha1').update(email).digest('hex').slice(0, 12),
      email,
      name: email.split('@')[0].replace(/[._-]+/g, ' '),
    },
  };
}

/** Returns the session for a request, or null when missing/expired. */
function authenticate(req) {
  const header = req.headers.authorization || '';
  if (!header.startsWith('Bearer ')) return null;
  const accessToken = header.slice(7);
  const session = sessions.get(accessToken);
  if (!session) return null;
  if (session.expiresAt < Date.now()) {
    // Expire it for real so the client has to refresh.
    sessions.delete(accessToken);
    return null;
  }
  return session;
}

// --------------------------------------------------------------------------
// Reply generation
// --------------------------------------------------------------------------

/** Builds a plausible Markdown reply so the renderer gets exercised. */
function composeReply(messages) {
  const lastUser = [...messages].reverse().find((m) => m.role === 'user');
  const prompt =
    typeof lastUser?.content === 'string'
      ? lastUser.content
      : Array.isArray(lastUser?.content)
        ? lastUser.content.map((p) => p.text).filter(Boolean).join(' ')
        : '';
  const lower = prompt.toLowerCase();

  if (/\b(code|function|dart|flutter|debounce|sort|parse)\b/.test(lower)) {
    return [
      'Here is a compact implementation:',
      '',
      '```dart',
      'Timer? _timer;',
      '',
      'void debounce(Duration wait, void Function() action) {',
      '  _timer?.cancel();',
      '  _timer = Timer(wait, action);',
      '}',
      '```',
      '',
      'A few notes:',
      '',
      '1. Cancel the pending timer before scheduling a new one, or every',
      '   keystroke leaves a timer behind.',
      '2. Cancel it in `dispose()` too — otherwise the callback can fire after',
      '   the widget is gone.',
      '3. For search-as-you-type, 250–300 ms is usually the sweet spot.',
      '',
      'Want a `Debouncer` class with a `dispose()` instead?',
    ].join('\n');
  }

  if (/\b(summar|tldr|tl;dr|key points|condense)\b/.test(lower)) {
    return [
      '**Summary**',
      '',
      '- The main claim is that latency dominates perceived quality.',
      '- Two supporting points: streaming hides model think-time, and local',
      '  persistence hides network variance.',
      '- The caveat is that neither helps if the first token never arrives.',
      '',
      'Net: optimise for *time to first token*, not total generation time.',
    ].join('\n');
  }

  if (/\b(on-device|onnx|offline|local model|inference)\b/.test(lower)) {
    return [
      'On-device inference trades capability for independence.',
      '',
      '| Concern | Cloud | On-device |',
      '| --- | --- | --- |',
      '| Capability | High | Bounded by RAM |',
      '| Latency | Network-bound | Steady, no round trip |',
      '| Privacy | Data leaves device | Stays local |',
      '| Cost | Per token | Battery only |',
      '',
      'The usual answer is *both*: route to the cloud when reachable, and keep',
      'a small local model for classification, embeddings and search.',
    ].join('\n');
  }

  if (prompt.trim().length === 0) {
    return 'I did not catch a question there — what would you like to know?';
  }

  return [
    `You asked about **${prompt.slice(0, 72)}${prompt.length > 72 ? '…' : ''}**.`,
    '',
    'Short answer: it depends on where the bottleneck actually is. Three things',
    'usually explain most of it:',
    '',
    '1. **Measure first.** Assumptions about hot paths are wrong more often',
    '   than not.',
    '2. **Fix the biggest term.** A 10× win on 2% of the time is nothing.',
    '3. **Keep it observable.** If you cannot see a regression, it will return.',
    '',
    'Tell me which part you want to dig into and I will go deeper.',
  ].join('\n');
}

/** Splits text into token-ish pieces that reassemble exactly. */
function tokenise(text) {
  return text.match(/\s*\S+|\s+/g) || [];
}

// --------------------------------------------------------------------------
// Streaming endpoint
// --------------------------------------------------------------------------

async function handleChatCompletions(req, res, url, body) {
  const scenario = url.searchParams.get('scenario');

  if (scenario === 'ratelimit') {
    return sendError(res, 429, 'Too many requests. Slow down.', 'rate_limited', {}, );
  }
  if (scenario === 'server') {
    return sendError(res, 500, 'Upstream model provider is unavailable.', 'upstream_error');
  }

  const messages = Array.isArray(body.messages) ? body.messages : [];
  const model = body.model || 'gpt-4o-mini';

  if (!MODELS.some((m) => m.id === model)) {
    return sendError(res, 400, `Unknown model "${model}".`, 'invalid_model');
  }

  res.writeHead(200, {
    'Content-Type': 'text/event-stream; charset=utf-8',
    'Cache-Control': 'no-cache, no-transform',
    Connection: 'keep-alive',
    // Disable proxy buffering, which otherwise defeats streaming entirely.
    'X-Accel-Buffering': 'no',
  });

  const id = `chatcmpl-${crypto.randomBytes(8).toString('hex')}`;
  const send = (payload) => res.write(`data: ${JSON.stringify(payload)}\n\n`);

  const delta = (content) => ({
    id,
    object: 'chat.completion.chunk',
    model,
    choices: [{ index: 0, delta: { content }, finish_reason: null }],
  });

  let aborted = false;
  req.on('close', () => {
    aborted = true;
  });

  // A comment line is a valid SSE keep-alive; the client must ignore it.
  res.write(': stream open\n\n');

  if (scenario === 'slow') {
    // Long enough to trip a client idle timeout.
    await sleep(30_000);
  }

  const reply = composeReply(messages);
  const tokens = tokenise(reply);

  // Time to first token: the number users actually feel.
  await sleep(jitter(180, 220));

  for (let i = 0; i < tokens.length; i++) {
    if (aborted) {
      // The client cancelled (stop button, screen disposed). Stop burning CPU.
      console.log(`  ↯ client aborted after ${i}/${tokens.length} tokens`);
      return;
    }

    if (scenario === 'error' && i === Math.floor(tokens.length / 3)) {
      // An error *inside* a 200 stream: the status code said nothing about it.
      send({ error: { message: 'The model failed mid-generation.', code: 'model_error' } });
      return res.end();
    }

    if (scenario === 'truncate' && i === Math.floor(tokens.length / 2)) {
      // Close without [DONE], as a dropped connection would.
      return res.destroy();
    }

    const piece = tokens[i];

    // Every so often, split one token across two writes. This is the case that
    // breaks clients which assume one chunk equals one event.
    if (i % 17 === 5 && piece.length > 3) {
      const cut = Math.ceil(piece.length / 2);
      res.write(`data: ${JSON.stringify(delta(piece.slice(0, cut)))}`);
      await sleep(5);
      res.write('\n\n');
      send(delta(piece.slice(cut)));
    } else {
      send(delta(piece));
    }

    await sleep(jitter(14, 26));
  }

  send({
    id,
    object: 'chat.completion.chunk',
    model,
    choices: [{ index: 0, delta: {}, finish_reason: 'stop' }],
    usage: {
      prompt_tokens: messages.length * 24,
      completion_tokens: tokens.length,
    },
  });
  res.write('data: [DONE]\n\n');
  res.end();
}

// --------------------------------------------------------------------------
// Router
// --------------------------------------------------------------------------

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  const path = url.pathname.replace(/\/+$/, '') || '/';
  const method = req.method.toUpperCase();

  console.log(`${method} ${url.pathname}${url.search}`);

  if (method === 'OPTIONS') {
    res.writeHead(204, {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'GET,POST,PATCH,DELETE,OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type,Authorization',
    });
    return res.end();
  }

  let body = {};
  if (method !== 'GET' && method !== 'HEAD') {
    try {
      body = await readBody(req);
    } catch {
      return sendError(res, 413, 'Request body too large.', 'payload_too_large');
    }
  }

  // --- Public routes ---------------------------------------------------

  if (path === '/health') {
    return sendJson(res, 200, { status: 'ok', models: MODELS.length });
  }

  if (path === '/auth/login' && method === 'POST') {
    const { email, password } = body;
    if (!email || !password) {
      return sendJson(res, 422, {
        error: { message: 'Email and password are required.', code: 'validation_failed' },
        errors: {
          ...(email ? {} : { email: ['is required'] }),
          ...(password ? {} : { password: ['is required'] }),
        },
      });
    }
    // Any password of 8+ characters works, except the literal "wrongpassword",
    // which is reserved for demonstrating the invalid-credentials path.
    if (password === 'wrongpassword' || String(password).length < 8) {
      return sendError(res, 401, 'Incorrect email or password.', 'invalid_credentials');
    }
    await sleep(jitter(120, 180));
    return sendJson(res, 200, issueSession(String(email).toLowerCase()));
  }

  if (path === '/auth/register' && method === 'POST') {
    const { email, password } = body;
    if (!email || !password) {
      return sendError(res, 422, 'Email and password are required.', 'validation_failed');
    }
    if (String(email).toLowerCase() === 'taken@evdekimi.id') {
      return sendError(res, 409, 'An account with that email already exists.', 'email_already_in_use');
    }
    await sleep(jitter(200, 200));
    return sendJson(res, 201, issueSession(String(email).toLowerCase()));
  }

  if (path === '/auth/refresh' && method === 'POST') {
    const provided = body.refresh_token || body.refreshToken;
    const email = refreshTokens.get(provided);
    if (!email) {
      return sendError(res, 401, 'The refresh token is invalid or expired.', 'invalid_refresh_token');
    }
    // Rotate: the old refresh token stops working, which is what makes the
    // client's single-flight refresh actually necessary.
    refreshTokens.delete(provided);
    console.log('  ↻ refreshed session');
    return sendJson(res, 200, issueSession(email));
  }

  // --- Authenticated routes -------------------------------------------

  const session = authenticate(req);
  if (!session) {
    return sendError(res, 401, 'Your session has expired.', 'token_expired');
  }

  if (path === '/auth/logout' && method === 'POST') {
    return sendJson(res, 200, { ok: true });
  }

  if (path === '/auth/me' && method === 'GET') {
    return sendJson(res, 200, {
      user: {
        id: crypto.createHash('sha1').update(session.email).digest('hex').slice(0, 12),
        email: session.email,
        name: session.email.split('@')[0],
      },
    });
  }

  if (path === '/models' && method === 'GET') {
    return sendJson(res, 200, { data: MODELS });
  }

  if (path === '/conversations' && method === 'GET') {
    // The client is offline-first and treats its local database as the source of
    // truth, so an empty server list is the correct default.
    return sendJson(res, 200, { data: [] });
  }

  if (path === '/uploads' && method === 'POST') {
    const size = body.__raw ? Buffer.byteLength(body.__raw) : 0;
    const key = crypto.randomBytes(10).toString('hex');
    uploads.set(key, size);
    await sleep(jitter(150, 250));
    return sendJson(res, 201, {
      url: `http://localhost:${PORT}/uploads/${key}`,
      size_bytes: size,
    });
  }

  if (path === '/chat/completions' && method === 'POST') {
    return handleChatCompletions(req, res, url, body);
  }

  return sendError(res, 404, `No route for ${method} ${path}`, 'not_found');
});

server.listen(PORT, () => {
  console.log(`
EVDEkimi AI mock backend
  listening   http://localhost:${PORT}
  health      GET  /health
  token TTL   ${ACCESS_TOKEN_TTL_MS / 1000}s  (forces a real refresh round trip)

Point the app at it:
  Android emulator   --dart-define=API_BASE_URL=http://10.0.2.2:${PORT}
  iOS simulator      --dart-define=API_BASE_URL=http://localhost:${PORT}
  physical device    --dart-define=API_BASE_URL=http://<your-lan-ip>:${PORT}

Sign in with any email and any password of 8+ characters.
Use the password "wrongpassword" to exercise the failure path.
`);
});
