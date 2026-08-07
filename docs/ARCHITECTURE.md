# Architecture

The decisions, and what each one cost.

---

## 1. Layering

Clean Architecture, per feature, dependencies pointing inward.

```
presentation  ──▶  domain  ◀──  data
     │                            │
     └──────▶  core  ◀────────────┘
```

| Layer | Contains | May import |
|---|---|---|
| `domain` | Entities, repository interfaces, value objects | Nothing but `core` primitives |
| `data` | DAOs, DTO mapping, HTTP/ONNX adapters, repository impls | `domain`, `core` |
| `presentation` | Screens, widgets, Riverpod controllers | `domain`, `core`, `design_system` |
| `core` | Config, logging, errors, transport, persistence primitives | Nothing feature-specific |

The rule that keeps this honest: **`core` never imports `features/`.** When the
HTTP layer needed to authenticate requests, the interface (`AuthTokenDelegate`)
was declared in `core/network/` and *implemented* by the auth feature. The
transport has no idea that a `User` or a session store exists.

The same inversion appears at the AI boundary. `OnDeviceEngine` needs to search
stored messages, but the AI layer must not depend on the chat feature — so it
declares `LocalKnowledgeSource` and the chat layer satisfies it.

### Feature independence

`chat` does not import `auth`. `auth` does not import `chat`. When signing out
needs to wipe conversations, the auth repository takes an `onSignedOut` callback
that `providers.dart` wires to the database — the coupling lives in the
composition root, where coupling belongs, instead of being baked into a feature.

---

## 2. No code generation

**Decision:** no `freezed`, `json_serializable`, `riverpod_generator`, or `drift`.

**Why.** Dart 3 already has what `freezed`'s unions were bought for: `sealed`
classes with exhaustive `switch` (see `Result`, `Failure`, `InferenceEvent` — the
compiler rejects an unhandled case). What is left is `copyWith` and `fromJson`
boilerplate. Against that:

- `git clone && flutter pub get && flutter run` works. No `build_runner` step to
  forget, no stale-generated-file class of bug.
- Nothing generated appears in a review diff. On an assessment about *reviewing*
  AI-written code, every line being human-readable matters.
- CI is meaningfully faster without a codegen stage.
- Serialisation is explicit at the boundary, so tolerating a backend that renames
  `access_token` to `accessToken` is three lines rather than an annotation dance.

**What it costs.** Hand-written `copyWith` on `Message` is 30 lines of real
boilerplate, and `ChatMappers` is ~200 lines a generator would have written. On a
team of five shipping for two years, I would probably take `freezed` and pay the
codegen tax. For a codebase of this size, reviewed by people who did not write it,
explicit won.

**Where the cost concentrated:** `chat_mappers.dart`. If this grew past ~10
entities I would revisit.

---

## 3. Persistence: sqflite over Drift/Isar

**Decision:** sqflite with hand-written SQL and an ordered migration list.

Drift would have generated the DAOs and given `watch()` for free. The cost of
choosing sqflite is one class — `AppDatabase`, with a `DatabaseChangeNotifier`
and a `watchQuery` helper, about 120 lines that Drift would have written.

What was bought:

- No codegen (see above).
- The exact SQL that runs is readable in one file, including the composite index
  the conversation-list ORDER BY relies on.
- Migrations are an explicit `Map<int, List<String>>`, and a fresh install replays
  the same migrations as an upgrade — so the two paths cannot drift apart, which
  is the failure mode that actually bites.

**Trade-off accepted:** `DatabaseChangeNotifier` publishes coarse topics
(`messages:<conversationId>`, not per-row). A streaming reply writes on a throttle
and each write re-runs the conversation query. At chat-history scale that is
cheaper than maintaining fine-grained invalidation; at 100k messages per thread it
would not be, and the fix would be pagination rather than finer topics.

### Schema notes

- Timestamps are **UTC milliseconds** (`INTEGER`). Local time would silently
  reorder a conversation when the user changes timezone.
- Enums persist as `name`, not index, so reordering an enum cannot corrupt rows —
  and every `fromName` has an `orElse` fallback so a row written by a newer build
  does not crash an older one.
- `messages.sequence` is the sort key, not `created_at`: two messages created in
  the same millisecond still need a total order. A unique index on
  `(conversation_id, sequence)` enforces it, and `nextSequence` is read *inside*
  the insert transaction so the slot is reserved atomically.
- `PRAGMA foreign_keys = ON` in `onConfigure`. It is off by default in SQLite, and
  without it `ON DELETE CASCADE` is silently ignored. There is a test for this.

---

## 4. Offline-first: the local database is the source of truth

This is the decision the rest of the app is shaped around.

`sendMessage` commits three things in **one transaction** — the user message, an
empty assistant placeholder, and an outbox row — then returns. Delivery happens
afterwards and is allowed to fail.

Consequences worth naming:

- **There is no "offline mode" branch.** The online path is the offline path plus a
  successful request. Nothing in the UI asks "am I online?" to decide what to do;
  it renders message *status*.
- **A crash mid-send cannot lose the message,** because the state lives in the same
  row as the content, not in a separate in-memory queue.
- **Connectivity is a hint, not a truth.** `connectivity_plus` reports interface
  state, so a captive-portal Wi-Fi reports "online" while every request fails. The
  outbox therefore re-queues based on the *request outcome*, not on what the
  connectivity service says. The service only decides when to *try*.

### The outbox

`outbox.id` **is** the message id. Enqueueing the same message twice is a
primary-key conflict rather than a duplicate send, and the derived
`idempotency_key` travels to the server so a retry after a lost response is
recognised as the same write.

Backoff is a fixed coarse schedule (5s → 20s → 1m → 5m → 15m) with ±20% jitter,
capped at 8 attempts. Jitter matters because a batch queued during an outage would
otherwise retry in lockstep. The schedule is deliberately unhurried: the flush on
reconnect is what recovers the common case, so aggressive polling would only cost
battery.

Concurrent flushes collapse into one pass — reconnect, timer, and app-resume can
all fire within the same second, and three passes would send duplicates.

---

## 5. Streaming

### The transport

`SseParser` is hand-written rather than taken from a package, for reasons that all
bite in practice:

- Chunk boundaries are arbitrary. One token can be split across two TCP reads, and
  a multi-byte UTF-8 character can be split mid-sequence. Chaining the streaming
  UTF-8 decoder and `LineSplitter` handles both, because each buffers its own
  partial state.
- The useful failure signal is an **idle** timeout, not a total-duration cap — a
  model may legitimately think for seconds between tokens.
- Cancellation must free the socket promptly, which means owning the subscription
  lifecycle.

`SseClient` disables `validateStatus` and checks the status itself, because with
`ResponseType.stream` Dio hands back an unread byte stream even for a 500. Draining
that body first is the difference between a real server message and an opaque
parse error.

**This is where the review caught a real bug.** The first implementation used
`stream.transform(const Utf8Decoder(...))`. That compiles, but `transform` checks
the transformer against the stream's *reified* type argument, and Dio returns a
`Stream<Uint8List>` — so it threw `type 'Utf8Decoder' is not a subtype of
StreamTransformer<Uint8List, String>` on every real response. `Converter.bind`
takes `Stream<List<int>>` and accepts the subtype cleanly. Details in
[`AI_WORKFLOW.md`](AI_WORKFLOW.md).

### Rendering at token rate

Live tokens reach the widget tree from an **in-memory buffer**, not from SQLite.

`ChatRepositoryImpl` keeps an `_ActiveGeneration` per conversation holding a
`StringBuffer`. `watchMessages` merges the database rows with that buffer, so the
UI updates per token while SQLite is written on a 250 ms throttle purely for crash
durability. A 200-token answer costs ~8 `UPDATE`s instead of 200.

Persisting per token and letting the UI observe the database would have been
simpler and is the obvious first design — but it caps rendering at the persistence
interval, which looks like jank.

### Cancellation

The `InferenceEngine` contract states that cancelling the returned stream's
subscription must abort the underlying work. No separate cancellation token: a
`StreamSubscription` already expresses exactly that lifetime, and adding a token
would create two ways to express one thing. `SseClient` cancels its `CancelToken`
in `onCancel`; `OnDeviceEngine`'s inter-token `await` is its abort point.

---

## 6. The AI boundary

`InferenceEngine` is the seam the whole "future on-device models" requirement rests
on:

```dart
abstract interface class InferenceEngine {
  EngineKind get kind;
  EngineCapabilities get capabilities;
  Future<bool> isAvailable();
  Stream<InferenceEvent> generate(InferenceRequest request);
  Future<void> dispose();
}
```

`InferenceEvent` is a **sealed** hierarchy (`Started` / `Delta` / `Status` /
`Completed`) rather than a bare `Stream<String>`, so consumers exhaustively handle
lifecycle as well as content. That is what makes it possible to record latency and
which engine actually ran, and to distinguish "finished" from "stopped by the user"
without out-of-band flags.

`PromptTurn` exists so the AI layer never sees the chat feature's `Message`. It
takes roles and text; it knows nothing about persistence status or upload state.
That is why the same engine serves chat, offline answers, and search.

### Routing policy

All engine selection lives in `EngineRouter.resolve` — one readable function,
unit-testable without a database or a network:

1. Honour the user's model choice if that engine is available.
2. Cloud model chosen but no network → fall back on-device, **only if** the
   on-device engine can serve it.
3. On-device model chosen but the runtime is broken → use the cloud.
4. Otherwise queue.

**What it deliberately does not do:** route on prompt content to save money. Answer
quality changing based on a hidden classifier is exactly the behaviour users find
untrustworthy. Cross-engine routing happens only when the preferred engine
genuinely cannot run, and the reason is surfaced in the UI.

---

## 7. Errors

`Failure` is a sealed hierarchy of **values**, not exceptions. Repositories return
`Result<T>`; nothing above the repository boundary throws, so error paths are
visible in the type signature and impossible to forget.

Exceptions are confined to `data`, where SDKs throw at us, and are translated in
exactly one place: `ErrorMapper`. One file to read to understand how the app
classifies errors, and one file to change.

Two properties live on the failure rather than in each screen:

- `isRetryable` — so the "Try again" affordance appears from the domain's decision
  rather than a per-screen guess.
- `userMessage` — so every surface renders the same wording, and adopting ARB
  localisation later becomes a key lookup with no call-site changes.

`ErrorMapper.parseApiException` probes several error-envelope shapes rather than
assuming one, because mock servers and real providers rarely agree.

---

## 8. State management

Riverpod 3, hand-written providers, `Notifier`/`AsyncNotifier`.

`di/providers.dart` is the single composition root. No service locator, no globals.
Anything needing `await` at startup (`AppConfig`, preferences, connectivity, the
logger) throws until overridden, and `bootstrap()` installs the overrides — so a
missing override fails immediately and loudly rather than handing out a
half-initialised object.

### A real cycle, and the fix

The first wiring had:

```
onDeviceEngine → chatRepository → engineRouter → onDeviceEngine
```

because the on-device engine needed the repository's semantic search. The analyzer
caught it as a type-inference cycle. The fix was better design, not a lazy
provider: search only ever needed the message DAO and the embedder, so it was
extracted into `SemanticSearchService`. That removed the cycle *and* left a smaller
independently testable unit. Extracting a collaborator beat breaking the cycle with
indirection.

The one place indirection *was* correct is `DeferredAuthTokenDelegate`: Dio needs a
token delegate, the auth repository is that delegate, and it needs Dio. Before
binding it behaves as a no-op delegate — which is the right behaviour anyway, since
no session can exist before the repository does.

### Composer state

`MessageComposer` owns its `TextEditingController` locally instead of mirroring the
draft into Riverpod. Routing every keystroke through a provider would rebuild the
transcript on each character. The controller only publishes text at the moment of
sending.

---

## 9. Design system

Tokens (`AppSpacing`, `AppRadius`, `AppDuration`, `AppSizes`) mean every magic
number in the UI resolves to a name. On a codebase where an agent wrote the
first-draft widgets, a reviewer can spot an invented value (`padding: 13`)
instantly.

`ChatTheme` is a `ThemeExtension` for what `ColorScheme` has no slot for — bubble
fills, the streaming caret, code chrome, the on-device accent. These are domain
concepts, not Material roles. Putting them there rather than reaching for
`Colors.grey[200]` means dark mode is resolved in one place and a widget cannot
render a colour that only works in one theme. A widget test renders the transcript
in both themes to keep that true.

The colour scheme is seeded from the brand teal, then a handful of surface roles
are overridden by hand. That override is the point: `ColorScheme.fromSeed` in dark
mode produces surfaces with a violet cast that fights a teal brand, and a chat app
is mostly surface.

**Typography uses the platform font deliberately.** A bundled webfont means a
larger download and a runtime fetch that fails offline — unacceptable in an app
whose selling point is working without a network. The tuning is in the metrics
(1.5 line height on body copy, negative tracking on large type), not the family.

---

## 10. Security

- Tokens in the platform keystore (`flutter_secure_storage`), never
  `SharedPreferences`. The two are behind separate interfaces so the choice is
  explicit at every call site.
- iOS accessibility is pinned to `first_unlock_this_device`: `first_unlock` lets a
  background outbox flush read the token after a reboot, and `_this_device` stops
  the credential being restored onto a different device from a backup.
- **Single-flight refresh.** A chat screen can fire several requests at once; if
  the token just expired they all 401 simultaneously. Refreshing per request would
  burn a rotating refresh token N times and invalidate the session outright. The
  first 401 starts a refresh; every concurrent 401 awaits that same future.
- The logger redacts a known set of field names *in the logger*, not at call sites,
  so forgetting to scrub a token at one site cannot leak it. `AuthSession.toString`
  and `AuthCredentials.toString` never include secrets, and there are tests.
- The HTTP logger records shape and timing, never bodies. Prompts are user content
  and tokens are credentials.
- LLM-supplied links are **copied, not opened.** Silently launching a URL a model
  produced is a phishing vector.

---

## 11. What I would do next

In priority order, with the reasoning:

1. **Paginate messages.** `watchMessages` loads a whole conversation. Fine at
   hundreds of messages, wrong at ten thousand. The `sequence` column already
   supports keyset pagination.
2. **Finish server sync.** `SyncState` and tombstones exist for it; the push/pull
   loop does not.
3. **A real tokeniser for context trimming.** Currently a 4-characters-per-token
   approximation. It is conservative, so it under-fills the window rather than
   overflowing it — acceptable, but it wastes context on non-Latin scripts where
   the ratio is very different.
4. **Golden tests for the transcript.** Widget tests assert structure; they would
   not catch a spacing regression in a bubble.
5. **Integration tests on a real device** for the ONNX path, which unit tests
   cannot reach.
6. **Localisation**, if the product needs Indonesian. Deferred deliberately: not in
   the requirements, and retrofitting is mechanical.
7. **Reconsider `freezed`** if the entity count grows past roughly ten.
