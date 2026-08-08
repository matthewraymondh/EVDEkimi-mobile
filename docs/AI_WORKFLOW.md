# AI coding-agent workflow

Required deliverable: *"Evidence of AI coding-agent usage (prompts, generated code,
and your review/corrections)."*

**Agent:** Claude Code (Claude Opus 5), single session, ~3 hours.
**Split:** the agent wrote effectively all of the ~9,500 lines. My contribution was
direction, architectural decisions, and review — which is where the defects below
were caught.

This document is written to be checkable. Every correction names a file, and the
bugs are the ones that actually happened, not illustrative examples.

---

## 1. How the session was driven

### Fix the toolchain before writing code

The machine had Flutter 3.32 (May 2025). The brief says *latest stable*. First
action was `flutter upgrade` → 3.44.9 / Dart 3.12.2.

This mattered more than it sounds. Writing against 3.32 and upgrading later would
have meant retrofitting three deprecations the agent could not have known about —
`RadioListTile.groupValue`, `speech_to_text`'s `listen()` arguments, and
`flutter_secure_storage` v11's `AndroidOptions`. All three were hit anyway (§3) and
resolved by reading the installed package source rather than trusting memory.

### Decide architecture first, generate second

Before any feature code, I fixed:

- Clean Architecture with `core` never importing `features/`
- **No code generation** (reasoning in [ARCHITECTURE.md](ARCHITECTURE.md#no-code-generation))
- Local database as the source of truth
- `InferenceEngine` as the swap point for on-device models
- `Result`/`Failure` instead of exceptions above the data layer

Those constraints removed most of the drift you get from an agent choosing
per-file conventions. Nearly every later review comment was a *bug*, not a
"that's not how we do it here".

### Strict lints as a review multiplier

`analysis_options.yaml` was written **before** the first feature file, with
`strict-casts`, `strict-inference`, `strict-raw-types`, and `unawaited_futures`
promoted to errors.

This was the single highest-leverage decision. An agent producing thousands of
lines will drop an `await`; making that a build error means the compiler reviews the
mechanical layer so a human can spend attention on logic. `flutter analyze` is clean
under that set.

### Verify continuously, not at the end

`flutter analyze` was run at roughly ten checkpoints rather than once. The final run
before docs reported *2 issues*, because problems were fixed while the context was
still fresh instead of accumulating into a cleanup phase.

---

## 2. Representative prompts

Abbreviated; the shape is what matters.

> Build a production-minded Flutter AI chat app for the EVDEkimi assessment.
> Clean architecture, Riverpod, streaming SSE, offline-first with SQLite, secure
> auth, dark mode, and all the bonus items including ONNX Runtime. Make it
> advanced.

> Before writing the SSE parser: chunk boundaries are arbitrary and a multi-byte
> UTF-8 character can be split across two reads. Handle both, and use an idle
> timeout rather than a total timeout — a model can pause between tokens.

> Python is available. Rather than stubbing on-device AI, train a real small ONNX
> model and ship it. It must do something genuinely useful offline, and the Dart
> feature extraction must be provably identical to the Python that produced the
> training data.

> Don't fake local generation. If the on-device model can't answer something, it
> should say so and point at the cloud model.

> The analyzer reports a provider cycle. Don't paper over it with a lazy provider —
> find out whether the dependency is real.

The last two are the ones that changed the output most. Left alone, an agent will
happily produce a template-based "local LLM" that demos well and is dishonest, and
will reach for indirection to silence a cycle rather than questioning the design.

---

## 3. Corrections made in review

The substantive ones, with enough detail to verify.

### 3.1 `Utf8Decoder` with `Stream.transform` — would have broken every response

**Generated:**

```dart
final lines = byteStream
    .transform(const Utf8Decoder(allowMalformed: true))
    .transform(const LineSplitter());
```

This type checks and looks obviously correct.

**Caught by:** the SSE test suite, which feeds byte chunks the way a socket does.

```
type 'Utf8Decoder' is not a subtype of type 'StreamTransformer<Uint8List, String>'
```

**Why it matters:** `Stream.transform` checks the transformer against the stream's
*reified* type argument. Dio's `ResponseBody.stream` is `Stream<Uint8List>`, and a
`Converter<List<int>, String>` is not a `StreamTransformer<Uint8List, String>`. It
would have thrown on **every real streaming response** — while passing any test that
fed it a `Stream<List<int>>`.

**Fix** (`lib/core/network/sse/sse_parser.dart`): use `Converter.bind`, which takes
`Stream<List<int>>` and accepts the subtype cleanly. The reasoning is in a comment
so nobody "simplifies" it back.

**Lesson:** this is exactly the failure an agent cannot catch by reasoning about its
own code, and exactly why the test fed *bytes in awkward chunks* rather than tidy
strings. The test was written because I asked for the transport's real failure modes;
the bug was found because of that framing.

### 3.2 A real dependency cycle, fixed by design rather than indirection

**Generated:** `onDeviceEngineProvider` took the chat repository as its
`LocalKnowledgeSource`:

```dart
knowledge: ref.watch(chatRepositoryProvider) as LocalKnowledgeSource,
```

The analyzer refused it:

```
The type of 'onDeviceEngineProvider' can't be inferred because it depends on
itself through the cycle: chatRepositoryProvider, engineRouterProvider,
onDeviceEngineProvider.
```

The tempting fix is a lazy provider or a late setter. I asked whether the dependency
was real instead.

It was not. Semantic search only ever needed the message DAO and the embedder — not
the repository, its engine router, its outbox, or its HTTP client. Extracting
`SemanticSearchService` (`lib/features/chat/data/semantic_search_service.dart`)
removed the cycle **and** produced a smaller unit that is testable without a network
stack.

**Lesson:** a cycle is usually a design smell, not a wiring problem. The `as` cast in
the generated line was itself the tell — a cast to an interface a class already
implements means the types are being fought.

### 3.3 A fabricated exception class

**Generated** — in `attachment_service.dart`, to detect a denied permission:

```dart
} on PlatformException_ catch (error) {
  ...
}

/// Narrow stand-in so this file does not depend on Flutter's services layer.
class PlatformException_ implements Exception {
  const PlatformException_({required this.isPermanent});
  final bool isPermanent;
}
```

It compiled. It is also nonsense: `image_picker` throws Flutter's real
`PlatformException`, so this `catch` could never fire and every permission denial
would have fallen through to the generic handler.

**Fix:** import the real `PlatformException` and match on the documented codes
(`camera_access_denied`, `photo_access_denied`), with a comment recording that the
plugin cannot distinguish "denied once" from "don't ask again", so the UI points at
system settings rather than re-prompting pointlessly.

**Lesson:** the most dangerous agent output is the plausible-looking helper class.
It satisfies the compiler and the shape of the code looks right. Only checking the
package's actual behaviour catches it.

### 3.4 A comment that contradicted its code

**Generated** — `secure_store.dart`:

```dart
} catch (error) {
  // A corrupt keystore entry must not wedge the app in a crash loop at startup:
  // treat it as "no value" and let the caller fall through.
  throw LocalStoreException('Failed to read secure key "$key"', cause: error);
}
```

The comment says it degrades gracefully. The code throws.

The comment described the *right* behaviour, in the wrong layer. Deciding that an
unreadable token means "signed out" is a policy call belonging to the auth
repository, not a storage primitive.

**Fix:** the storage layer wraps and rethrows; `AuthRepositoryImpl.restoreSession`
catches `LocalStoreException` and resolves to signed-out. Both comments now say what
their code does, and the policy lives in one place.

**Lesson:** worth grepping agent output specifically for comments that *promise*
behaviour. A wrong comment is worse than none — the next reader trusts it.

### 3.5 Three API-drift errors, fixed by reading the package

Each was written from a plausible but outdated API:

| Generated | Reality | Fix |
|---|---|---|
| `AndroidOptions(encryptedSharedPreferences: true)` | Removed in `flutter_secure_storage` 11; AES-GCM + keystore-wrapped RSA is now the default | Dropped it; kept the iOS `first_unlock_this_device` override, which *is* a deliberate non-default |
| `speech.listen(pauseFor:, listenFor:, localeId:)` | Deprecated in `speech_to_text` 7; moved into `SpeechListenOptions` | Moved them; also `hasPermission` is `Future<bool>`, not `bool` |
| `RadioListTile(groupValue:, onChanged:)` | Deprecated in Flutter 3.44 | Wrapped in a `RadioGroup<ThemeMode>` ancestor |

All three were resolved by reading the installed source in the pub cache, not by
guessing again. When an agent is wrong about an API, asking it again usually produces
a different wrong answer.

### 3.6 A lint that could not be satisfied

`prefer_initializing_formals` fired on every constructor doing
`: _delegate = delegate`. The suggested `this._delegate` **is** legal Dart in 3.12 —
I verified with a throwaway file rather than assuming.

But a private-named parameter is library-private, so no other file could pass it.
The lint's suggestion is inapplicable for a public constructor assigning to a
private field.

**Fix:** disabled the rule with the reasoning recorded in `analysis_options.yaml`.

**Lesson:** the agent's first instinct was to satisfy the lint by making the fields
public. Verifying the language rule took one minute and produced the correct answer
— disable the lint, keep the encapsulation.

### 3.7 Two wrong test expectations, one of which documented real behaviour

The first test run: 84 passing, 2 failing. Both were *my expectations*, not the code.

The interesting one asserted that inserting a duplicate `(conversation_id,
sequence)` would throw. It does not — `insert` uses `ConflictAlgorithm.replace`,
chosen so re-inserting the same message id is idempotent (both the outbox and the
streaming path do it).

Rather than deleting the test, I rewrote it to assert the real behaviour and the
invariant that matters — never two rows at one sequence — plus a comment recording
*why* `replace` is correct and why the collision cannot happen in practice
(`nextSequence` is read inside the insert transaction).

**Lesson:** a failing test is a question, not a defect report. This one turned into
documentation of a deliberate design choice.

### 3.8 Smaller catches

- **A raw NUL byte in source.** The SSE parser's spec-correct `value.contains('\u0000')`
  was emitted with a literal control byte inside the quotes. Correct behaviour,
  fragile file — replaced with the escape.
- **A Devanagari digit in a hex literal.** `Color(0xFF1E7A४4)` — caught by the
  compiler, worth noting as a reminder that agent output can contain characters that
  look right at a glance.
- **`Dio().fetch()` for request replay.** The auth interceptor replayed a request on
  a throwaway `Dio`, silently dropping the configured adapter and transformer. Fixed
  by injecting the owning client via `attach()`.
- **`@visibleForTesting` on a production helper.** `watchQuery` is used by every
  reactive repository; the annotation would have made every legitimate use a warning.

---

## 3b. What only running it could find

Everything above was caught by reading, by the analyzer, or by tests. The next
three needed the app on an actual device — which is the point: each verification
stage catches a class the previous one structurally cannot.

| Stage | Caught |
|---|---|
| Analyzer | The provider cycle (§3.2), unused imports, missing awaits |
| Tests | The `Utf8Decoder` transport bug (§3.1), wrong assumptions (§3.7) |
| Building | Three toolchain conflicts (§3.11) |
| **Running it** | Startup zone mismatch, a latch that did not latch, unusable output |

### 3.9 Zone mismatch on every launch

`bootstrap()` called `WidgetsFlutterBinding.ensureInitialized()` in the root zone
but `runApp()` inside `runZonedGuarded`. Flutter warns because the binding records
the zone it was initialised in, and zone-specific configuration then resolves
inconsistently depending on which zone was active when a callback was registered.

Invisible to the analyzer, invisible to tests, printed on every single launch.
Fixed by initialising the binding inside the guarded zone.

### 3.10 A latch that did not latch — the same defect as §3.4

The emulator log showed this warning **ten times in one session**:

```
WRN [ai.onnx] ONNX router unavailable ... Failed to load dynamic library
             'libonnxruntime.so': dlopen failed
```

`_ensureInitialised` cleared the in-flight future on failure, and `predict()` /
`embed()` never checked the `_unavailable` flag — so every completed message and
every backfill row retried a doomed `dlopen`.

The comment sitting directly above that code read:

> `// Latch the failure so we do not retry a broken runtime on every send.`

It described the intent. The code did the opposite. **This is exactly the defect
class documented in §3.4** — a comment that promises behaviour its code does not
implement — which is a fair reminder that finding one instance of a pattern does
not mean you have found them all, and that the review pass has to read code and
comment *against each other* rather than trusting either alone.

Fixing it surfaced a second, quieter problem: the first failure threw a raw
`FlutterError` while later ones threw `EngineUnavailableException`, so
`ErrorMapper` classified one condition two different ways. Both now throw the
typed exception. A regression test asserts `initialisationAttempts == 1` after
repeated calls.

### 3.11 Three toolchain conflicts, and getting the fix wrong twice

The Android build failed three times in a row, each for a different reason:

1. `Failed to find target with hash string 'android-37'` — a plugin declares a bare
   `compileSdk = 37`, but Google now publishes only minor-versioned platforms.
   There is no `android-37`, only `android-37.0`.
2. `:onnxruntime:checkDebugAarMetadata` failed — that plugin still pins
   `compileSdk 33`, below what the AndroidX artefacts in its own graph require.
3. `Could not close incremental caches` — Kotlin's Build Tools API cannot reliably
   release its `.tab` handles on Windows.

Worth recording honestly: **the fix for (1) and (2) was wrong twice before it was
right.** `plugins.withId` is overwritten by the module's own `android {}` block; an
`afterEvaluate` registered inside that callback runs after AGP has already read the
value and AGP 9 hard-fails; and `subprojects { afterEvaluate {} }` in the root
script throws because Flutter's plugin loader has already evaluated those projects.
Only `gradle.beforeProject` in `settings.gradle.kts` registers early enough. All
three failed attempts are documented in that file so the next person does not
repeat them.

For (3) I removed the flag, ran a clean build, watched it fail, and put it back —
rather than leaving a cargo-culted setting nobody could justify later.

### 3.12 Output that was technically correct and practically useless

Asking the app "test" returned the same paragraph every time. Not a client bug —
the mock backend matched keywords and fell through to one hard-coded response.

Worth listing because it is the failure mode an agent is least equipped to notice:
every layer worked exactly as written, and the result was still unusable. It took
looking at the screen. The mock now varies replies by a stable hash of the prompt
and labels itself as canned text.

---

## 4. What the agent did well

Balance matters here — the review found real bugs, but the leverage was enormous.

- **Genuinely good first-draft architecture.** Given the constraints, the layering,
  port placement (`AuthTokenDelegate` and `LocalKnowledgeSource` both correctly in
  the inner layer) and sealed-hierarchy design needed no rework.
- **Edge cases I did not ask for.** The idle-vs-total timeout distinction, draining
  a non-2xx stream body before reporting it, and collapsing concurrent outbox
  flushes were all unprompted and all correct.
- **Volume with consistency.** ~9,500 lines across ~60 files with uniform naming,
  error handling and comment style. That is the part that is genuinely hard by hand.
- **The ONNX training script.** Hand-building the graph with `onnx.helper`, and
  emitting the parity fixture from the same script that trains the weights, was a
  better idea than what I asked for (I asked for a fixture; tying it to the
  training run so they cannot diverge was the agent's).

---

## 5. How I would run this on a team

1. **Constrain before generating.** Layering, state management, and codegen policy
   decided up front. Most "AI slop" is an agent making a reasonable local choice
   inconsistent with a global one.
2. **Strict lints from commit one.** Non-negotiable. The compiler should review the
   mechanical layer.
3. **Tests target the boundaries the agent cannot reason about** — transport framing,
   real SQLite, cross-language parity. Not coverage for its own sake: three of the
   bugs above were found by tests aimed deliberately at seams.
4. **Read the dependency's source, not the agent's memory** of it. Every API-drift
   error was fixed in one pass this way, and would have taken several by re-asking.
5. **Treat plausible helper classes as suspect.** `PlatformException_` is the
   archetype: compiles, reads fine, provably dead.
6. **Make it say what it cannot do.** The most valuable prompt in the session was
   *"don't fake local generation."* Left alone, agents optimise for a working demo,
   and honest limitations are a product feature.
7. **Do not stop at "it compiles" or even "tests pass."** Four of the twelve
   findings here (§3.9–§3.12) were reachable only by building and then actually
   using the app. Green tests and a clean analyzer say the code does what it says;
   they cannot say whether what it says is useful.
8. **Assume a defect pattern recurs.** §3.10 is the same "comment contradicts its
   code" defect as §3.4, in a different file, found much later. Having fixed one
   instance, I should have grepped for the pattern instead of assuming it was
   isolated.

---

## 6. Reproducing the verification

```bash
flutter analyze            # No issues found!
flutter test               # All tests passed! (123 tests)
flutter build apk --debug  # per-ABI APKs; needs platform android-37.0
python tools/train_router_model.py   # retrains; then flutter test re-checks parity
```

On-device inference needs an **arm64** device or emulator image — the `onnxruntime`
package ships `arm64-v8a` and `armeabi-v7a` native libraries only. Verified on a
physical Android device: ONNX Runtime 1.15.1, 130 KB model, ~560 ms load.

The parity test is the one to run if you change anything about feature extraction.
It is the only thing standing between a one-character change and a silently worse
model.
