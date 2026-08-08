# EVDEkimi AI

A production-minded Flutter chat client for Android and iOS: streaming AI
responses, offline-first local persistence, secure authentication, and a **real
ONNX model running on-device**.

Built for the EVDEkimi Senior Flutter Mobile Developer (AI & On-Device AI)
take-home assessment.

| | |
|---|---|
| **Flutter** | 3.44.9 (stable) · Dart 3.12.2 |
| **State** | Riverpod 3 (no code generation) |
| **Persistence** | sqflite + hand-written migrations |
| **Networking** | Dio + a hand-written server-sent-events parser |
| **On-device AI** | ONNX Runtime Mobile, 130 KB model bundled in the app |
| **Tests** | 209 passing · `flutter analyze` clean under a strict lint set |

---

## Quick start

```bash
# 1. Dependencies
flutter pub get

# 2. Mock backend (separate terminal, zero npm install needed)
node tools/mock_server.js

# 3. Run against it
#    Android emulator — 10.0.2.2 is the host machine
flutter run --dart-define=API_BASE_URL=http://10.0.2.2:3001

#    iOS simulator — shares the host network
flutter run --dart-define=API_BASE_URL=http://localhost:3001

#    Physical device over USB — no LAN, no firewall, no IP hunting
adb reverse tcp:3001 tcp:3001
flutter run --dart-define=API_BASE_URL=http://localhost:3001

#    Physical device over Wi-Fi — needs the phone on the same subnet as the
#    host, an inbound firewall allowance for node on that network profile, and
#    the host's real LAN IP (not a WSL/Hyper-V virtual adapter address)
flutter run --dart-define=API_BASE_URL=http://192.168.1.50:3001
```

`adb reverse` is the reliable option: it tunnels the phone's `localhost:3001` to
the host over USB, so none of the Wi-Fi variables apply. A LAN IP that times out
rather than refusing the connection is almost always a firewall profile mismatch
or the wrong adapter's address.

**Sign in with any email and any password of 8+ characters.** The mock accepts
anything; use the password `wrongpassword` to see the invalid-credentials path.

> **Use an arm64 emulator image (or a real device) to see the on-device AI.**
> The `onnxruntime` package ships native libraries for `arm64-v8a` and
> `armeabi-v7a` only — there is no `x86_64` build. On a standard x86_64 emulator
> the runtime cannot load, Settings says exactly that, and the app falls back to
> cloud models. Everything else (streaming, offline outbox, OCR, dictation) works
> on any emulator.

### Verify

```bash
flutter analyze            # No issues found!
flutter test               # All tests passed!  (209 tests)
flutter build apk --debug  # per-ABI APKs in build/app/outputs/flutter-apk/
```

**Android SDK requirement:** the build needs platform **`android-37.0`** installed.
`flutter_secure_storage` 11 compiles against API 37, and Google now publishes only
minor-versioned platforms — there is no plain `android-37`. Install it with:

```bash
sdkmanager "platforms;android-37.0"
```

`android/settings.gradle.kts` aligns every plugin module onto that platform and
drags stale plugins forward (`onnxruntime` 1.4.1 still pins `compileSdk 33`, which
modern AndroidX rejects). The comment there explains why the fix has to live in
settings rather than the root build script.

### Regenerate the on-device model (optional)

The trained model and its golden test fixture are committed, so nothing below is
needed to build or run. To retrain:

```bash
pip install onnx numpy onnxruntime
python tools/train_router_model.py
```

This rewrites `assets/models/evdekimi_router_v1.onnx`, its metadata sidecar, and
`test/fixtures/onnx_router_golden.json` — the fixture that pins the Dart feature
extractor to the Python reference.

---

## What it does

- **Streaming chat.** Token-by-token rendering over SSE, with a stop button that
  actually tears down the socket. Markdown, fenced code blocks with copy buttons,
  and per-message latency and engine attribution.
- **Offline-first.** Every message is written to SQLite *before* the network is
  touched. A durable outbox retries with jittered exponential backoff on
  reconnect, on a timer, and on app resume. There is no "offline mode" branch —
  the online path is the offline path plus a successful request.
- **On-device inference.** A real ONNX graph classifies intent and produces a
  64-dimension embedding in single-digit milliseconds, powering offline answers
  and semantic search over your own history. See
  [`docs/ON_DEVICE_AI.md`](docs/ON_DEVICE_AI.md).
- **Secure auth.** Tokens in the platform keystore/Keychain, never in
  SharedPreferences. Single-flight refresh so a burst of concurrent 401s does not
  burn a rotating refresh token N times.
- **Dark mode**, responsive layout, and a token-driven design system.

### Bonus features

| Bonus | Status |
|---|---|
| Speech-to-text | Platform recogniser with live interim transcripts and a level meter |
| OCR / camera | ML Kit, on-device, at attach time — **and the local model answers from it with the network off**, quoting what it read and matching it against your own history. Three of these bonuses firing at once, offline. |
| Image upload | Multipart upload with per-attachment retry state |
| ONNX Runtime Mobile | **Real trained model**, bundled and executed via FFI |
| CI/CD | GitHub Actions: analyze, test, ONNX reproducibility, Android + iOS builds |

---

## Architecture

Clean Architecture, three layers per feature, dependencies pointing inward.

```
lib/
├── app/                    router, routes, app shell
├── bootstrap.dart          composition + global error handling
├── core/                   config · error · logging · network · persistence · result
├── design_system/          tokens · palette · ChatTheme · themes · shared widgets
├── di/providers.dart       the single composition root
└── features/
    ├── ai/                 domain: InferenceEngine port, ModelDescriptor
    │                       data:   RemoteSseEngine, OnDeviceEngine, EngineRouter, ONNX
    ├── auth/               domain · data · presentation
    ├── chat/               domain · data (DAOs, repos, outbox, search) · presentation
    ├── input/              speech-to-text, OCR + image attachment services
    ├── settings/           preferences
    └── diagnostics/        in-app log console
```

**The rule:** `presentation → domain ← data`. Domain declares interfaces
(`ChatRepository`, `InferenceEngine`, `AuthTokenDelegate`); data implements them;
presentation depends only on domain plus Riverpod providers. `core` knows nothing
about any feature.

Full reasoning, including the decisions I would defend in review and the ones I
would revisit, is in [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

### Three decisions worth stating up front

**1. No code generation.** No `freezed`, no `json_serializable`, no
`riverpod_generator`, no `drift`. Dart 3 sealed classes and pattern matching cover
what `freezed` unions were for, and `git clone && flutter run` works with no
`build_runner` step, no generated files in review diffs, and a faster CI. The cost
is hand-written `copyWith` and `fromJson` — real boilerplate, and a deliberate
trade. See [ARCHITECTURE.md](docs/ARCHITECTURE.md#no-code-generation).

**2. The local database is the source of truth.** The UI streams from SQLite, and
the network only ever feeds it. This is what makes offline the default rather than
a special case.

**3. Streamed tokens bypass the database on the way to the screen.** Writing every
token to SQLite would throttle rendering to the persistence interval. Live tokens
reach the widget tree from an in-memory buffer at full rate; SQLite is written on
a 250 ms throttle purely for crash durability. A 200-token answer costs ~8
`UPDATE`s instead of 200.

---

## Testing

```
test/
├── core/network/sse_parser_test.dart          transport framing edge cases
├── features/ai/hashing_vectorizer_parity_test.dart   Dart ↔ Python parity
├── features/ai/onnx_router_model_test.dart    runtime-unavailable degradation
├── features/chat/outbox_dao_test.dart         real SQLite via FFI
├── features/chat/domain_test.dart             pure domain logic
└── widget/message_bubble_test.dart            transcript rendering, both themes
```

Two of these earn their place more than the rest:

- **`hashing_vectorizer_parity_test.dart`** pins the Dart feature extractor to the
  Python one that produced the model's training data. Drift there would not crash
  or throw — inference would just quietly get worse. Nothing else would catch it.
- **`sse_parser_test.dart`** drives the cases a local mock never produces: an event
  split mid-token across TCP writes, a multi-byte character split across chunks,
  CRLF endings, comment keep-alives, a stream that closes without a terminator.
  **This suite caught a real bug** — `Utf8Decoder` used with `Stream.transform`
  throws at runtime on the `Stream<Uint8List>` that Dio actually returns. It type
  checked fine and would have failed on every real response.

---

## Documentation

| Document | What is in it |
|---|---|
| [`docs/DIAGRAM.md`](docs/DIAGRAM.md) | **Start here.** The whole system in diagrams: the dependency rule, the three ports, the send path, streaming, engine routing, on-device AI |
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | Layer rules, every significant decision and its trade-off, what I would change next |
| [`docs/ON_DEVICE_AI.md`](docs/ON_DEVICE_AI.md) | What the shipped model really is, and the concrete path to a 1–3 B parameter LLM |
| [`docs/AI_WORKFLOW.md`](docs/AI_WORKFLOW.md) | How this was built with an AI coding agent: prompts, generated code, and the bugs I caught in review |

---

## Honest limitations

Stated plainly, because a reviewer will find them anyway and the reasoning matters
more than the gap:

- **The on-device model is a classifier and embedder, not a local LLM.** It cannot
  write you an essay, and it refuses rather than pretending. What is proven
  end-to-end is the whole path a real local LLM needs — bundled weights, native
  session lifecycle, tensor marshalling, streaming through the same contract as
  the cloud engine, cancellation, graceful degradation. `ON_DEVICE_AI.md` sets out
  exactly what changes to swap in llama.cpp.
- **ONNX inference is not covered by unit tests.** The FFI runtime needs the
  Android/iOS native libraries, so it cannot load in a desktop `flutter test`
  process. The feature extraction *is* fully tested against golden vectors; the
  inference call itself is verified on device and by the Python runtime in the
  training script.
- **iOS is configured but unverified on hardware.** No Mac was available. The
  Podfile, permission strings and CI build step are in place; I have not run it on
  a device and will not claim otherwise.
- **Android is verified on a physical device**, including on-device inference:
  ONNX Runtime 1.15.1 loads the bundled 130 KB model in ~560 ms and embedding runs
  on every completed message. On an x86_64 emulator the runtime cannot load at all
  (see the note in Quick start) and the app falls back to cloud models.
- **Server-side conversation sync is scaffolded, not finished.** `SyncState` and
  soft-delete tombstones exist so deletions and edits can be reconciled, but no
  push/pull loop is implemented. The mock returns an empty list, which the
  offline-first client treats as correct.
- **No localisation.** Strings are inline English. The seam is not built; adding
  ARB files later means touching every widget. A deliberate scope cut, not an
  oversight — i18n was not in the requirements and the effort was better spent on
  architecture and the on-device path.
- **Only 3 physical form factors were checked** (emulator phone, tablet, foldable
  via emulator). Layouts use tokens and breakpoints, so I expect them to hold, but
  "expect" is the right word.

---

## Configuration

Everything environment-dependent enters via `--dart-define` and is read in exactly
one place (`AppConfig`).

| Key | Default | Purpose |
|---|---|---|
| `API_BASE_URL` | `http://10.0.2.2:3001` | Backend origin |
| `FLAVOR` | `dev` | `dev` / `staging` / `prod`; gates logging and diagnostics |
| `ENABLE_ON_DEVICE` | `true` | Disables the ONNX path entirely |

### Mock server scenarios

The mock injects realistic failures so error handling can be demonstrated rather
than described:

```
POST /chat/completions?scenario=slow        # 30s silence → idle timeout
POST /chat/completions?scenario=error       # 200, then an error mid-stream
POST /chat/completions?scenario=truncate    # connection drops, no [DONE]
POST /chat/completions?scenario=ratelimit   # 429 with Retry-After
POST /chat/completions?scenario=server      # 500 before streaming
```

Access tokens expire after 5 minutes and refresh tokens rotate, so a normal
session exercises the real refresh path rather than a happy-path stub.

**The mock is not a model.** Replies are canned Markdown selected by keyword
(listings, pricing, viewings, ownership structures, greeting, thanks) with a few generic variants chosen by
a stable hash of the prompt, so repeated questions do not return byte-identical
text. The *streaming* is real — chunked SSE, jittered token pacing, one token in
seventeen deliberately split across two TCP writes. Point `API_BASE_URL` at any
OpenAI-compatible endpoint to get real answers; no client code changes.
