# On-device AI

What actually ships, and the concrete path from here to a local LLM.

---

## 1. What is real

**A trained ONNX model is bundled in the app and executed on device through ONNX
Runtime Mobile.** Not a stub, not a mock, not a placeholder.

| | |
|---|---|
| File | `assets/models/evdekimi_router_v1.onnx` |
| Size | 130 KB |
| Runtime | ONNX Runtime Mobile via FFI (`onnxruntime` 1.4.1) |
| Inputs | `features` — `float32[1, 512]` |
| Outputs | `embedding` — `float32[1, 64]`, `intent_probs` — `float32[1, 7]` |
| Network | none, ever |
| Trained by | `tools/train_router_model.py` (committed) |

Verified on a physical Android device:

```
INF [ai.onnx] ONNX router ready ort=1.15.1 model=evdekimi-router-onnx-v1
             sizeKb=130 loadMs=559
```

ONNX Runtime 1.15.1 loads the graph in ~560 ms on first use (lazily, not at app
start), after which embedding runs on every completed message.

**It cannot run on an x86_64 emulator.** The `onnxruntime` package ships native
libraries for `arm64-v8a` and `armeabi-v7a` only, so `dlopen` fails there and the
app falls back to cloud models — which is the graceful-degradation path working as
designed, not a defect. Use an arm64 system image or a real device.

The graph:

```
features[1,512] ──MatMul(W1)──Add(b1)──Tanh──▶ embedding[1,64]
                                                    │
                                    MatMul(W2)──Add(b2)──Softmax──▶ intent_probs[1,7]
```

Seven intents, chosen for what a property assistant actually receives:
`greeting`, `gratitude`, `recall`, `property_search`, `pricing`, `viewing`,
`legal` — the last covering the leasehold/freehold/PT PMA questions that dominate
Bali real estate.

### What it is *not*

**It is not a local large language model.** It cannot write you an essay, explain
photosynthesis, or generate code. It is a classifier plus an embedder.

I am stating that plainly because the alternative — shipping something that looks
like local generation but is a template engine — is the kind of thing that survives
a demo and fails a code review. When the model is asked for something it cannot
honestly do, `OnDeviceEngine` **says so and points at the cloud model**:

> You are asking me to quote a price, which changes too often to answer from a
> cached model. The on-device model cannot do that. It classified your message as
> **pricing** (99% confidence) in a few milliseconds, but it is a small
> classifier and embedder — not a local LLM, and not connected to our listings.

A confidently wrong local answer is worse than no answer.

---

## 2. What it is genuinely used for

Three real features, none of which need a network:

### Offline semantic search (`SearchScreen`)

Every completed message is embedded locally and the vector stored as a BLOB. A
search query is embedded the same way and ranked by cosine similarity. This finds
related wording, not just substring matches, and works in airplane mode.

This is the feature that justifies the model existing. A 64-dimension supervised
bottleneck is not a general sentence encoder — but it clusters the vocabulary this
app actually sees, which is what the ranking needs.

### Offline recall answers

When the classifier reports `recall` ("what did I say about Riverpod earlier?"),
`OnDeviceEngine` retrieves the most similar stored messages above a 0.55 similarity
threshold and answers by quoting them. Entirely local, and genuinely useful.

### Engine routing

`isAvailable()` on the model decides whether the on-device path can serve a request
at all, which `EngineRouter` uses when the network is down.

---

## 3. Feature extraction, and why it is tested so hard

Text becomes a vector via a **hashing vectorizer**: word unigrams, word bigrams, and
character trigrams over a space-padded string, hashed with FNV-1a (32-bit) into 512
buckets, then L2-normalised.

Hashing rather than a learned vocabulary because there is no vocab file to bundle or
version, unbounded vocabulary is handled gracefully, and the memory footprint is
fixed. The cost is hash collisions, which at 512 buckets for short chat messages are
rare enough that training absorbs them.

**The critical risk:** the model was trained on features produced by
`tools/train_router_model.py`. `HashingVectorizer` in Dart is a port of that Python
code. If the two disagree by even one bucket, the model receives features from a
different distribution than it was trained on — and **nothing fails loudly.** No
crash, no exception. Inference just quietly gets worse.

So `tools/train_router_model.py` writes a golden fixture
(`test/fixtures/onnx_router_golden.json`) at training time, containing the exact
sparse vectors, embeddings and probabilities the Python reference produced. 
`test/features/ai/hashing_vectorizer_parity_test.dart` asserts the Dart output
matches, bucket for bucket, to 1e-5. Regenerating the model necessarily regenerates
the expectations, so the two cannot drift apart silently.

Details that had to match exactly, each of which was a real opportunity to get it
wrong:

- FNV-1a masked back to 32 bits after every multiply. Dart ints are 64-bit; without
  the mask the hashes diverge immediately.
- Feature families prefixed (`w:`, `b:`, `c:`) so a word and a trigram sharing
  characters cannot collide into one feature.
- Character trigrams computed over `" $text "` — the padding is what lets the model
  see word boundaries.
- Non-alphanumeric runs collapsed to a single space, then trimmed, in that order.

An all-zero vector (empty or punctuation-only input) is treated as *no signal* and
inference is skipped, because the model's output for a zero vector is just its bias
term — a confidently meaningless prediction.

---

## 4. Operational engineering

These are the parts that matter for a real local LLM, and they are already done:

**Lazy single-flight initialisation.** The ONNX session is built on first use, not
at app start, so a cold launch is not slowed by loading weights many sessions never
need. Concurrent first callers share one future. For a 2 GB model this becomes the
difference between a usable app and a five-second launch.

**Failure is never fatal.** If the runtime cannot load — unsupported ABI, stripped
native library — `isAvailable()` returns false, the failure is latched so a broken
runtime is not retried on every send, and the app falls back to the cloud. On-device
inference is an enhancement; it must never be the reason a message cannot be sent.

**Explicit native memory management.** `OrtValueTensor`, `OrtRunOptions` and output
values are FFI allocations, not GC-managed objects. Every one is released in a
`finally`, including on the error path. This is the class of bug that shows up as a
slow leak over a long session rather than an immediate crash.

**Metadata sidecar.** `evdekimi_router_v1.json` carries the feature dimension,
label order, SHA-256 and size. The Dart code reads dimensions from it rather than
hard-coding them, and **asserts the model's feature dimension matches the
vectorizer's** at load time — so an asset and a vectorizer built from different
revisions fail loudly instead of producing garbage.

**Off the UI thread.** Inference goes through `session.runAsync`, which the package
runs on a background isolate.

**Single-threaded session options.** The graph is tiny; spawning a thread pool costs
more than the matrix multiply it would parallelise. For a real LLM this flips, and
it is one line.

---

## 5. The path to a real local LLM

This is the question the assessment actually asks. The answer is that the
architecture already carries every concern a local LLM needs, and the swap is one
new class.

### What does not change

```dart
abstract interface class InferenceEngine {
  EngineKind get kind;
  EngineCapabilities get capabilities;
  Future<bool> isAvailable();
  Stream<InferenceEvent> generate(InferenceRequest request);
  Future<void> dispose();
}
```

A local Gemma or Llama implements exactly this. No change to `ChatRepositoryImpl`,
`EngineRouter`, any controller, or any widget — because they all depend on the
interface, and the streaming contract, cancellation semantics and event shape are
already what a decode loop produces.

Concretely, the diff is:

1. Add `LlamaCppEngine implements InferenceEngine`.
2. Register it in `EngineRouter` (constructor takes engines; one line in
   `providers.dart`).
3. Add its `ModelDescriptor` to `KnownModels`.

That is the whole integration surface. Everything below is already exercised by the
shipped model.

### What is already solved

| Concern | Status today |
|---|---|
| Native runtime lifecycle | `OnnxRouterModel`: lazy init, single-flight, disposal |
| Weights loading from a bundle | `rootBundle.load` → `OrtSession.fromBuffer` |
| Tensor marshalling | `Float32List` ↔ `OrtValueTensor`, shape `[1, N]` |
| Token-by-token streaming | `Stream<InferenceEvent>`, identical to the cloud engine |
| Cancellation | Subscription cancel aborts the loop; already wired to the stop button |
| Engine attribution in UI | `Message.engine`, badge per message |
| Routing / fallback | `EngineRouter`, with the reason surfaced |
| Graceful degradation | Latched unavailability, cloud fallback |
| Capability negotiation | `EngineCapabilities` (context window, vision, network) |
| Context trimming | `_buildPromptHistory` trims to the engine's window |

### What genuinely remains

Honestly, not architecture — logistics:

1. **Model delivery.** A 1–3 B quantised model is 0.6–2 GB and cannot go in the app
   bundle. Needs a downloader with resumable transfer, SHA-256 verification (the
   metadata sidecar pattern already exists), storage-space checks, and a Wi-Fi-only
   default. `ModelDescriptor.isInstalled` and `sizeBytes` are already in the domain
   for this.
2. **A tokeniser.** SentencePiece or BPE, matched to the model. This is the piece
   with no equivalent today — `HashingVectorizer` is not a tokeniser. It also
   replaces the 4-characters-per-token approximation in context trimming.
3. **A KV-cached decode loop.** `llama.cpp` via FFI, or ONNX Runtime GenAI. Emits
   `InferenceDelta` per token — the contract is unchanged.
4. **Thermal and battery policy.** Sustained generation heats a phone and throttles.
   Needs a decision about pausing under thermal pressure and refusing on low
   battery. Not built, and it is a product decision as much as a technical one.
5. **Memory headroom checks.** A 2 GB model on a 4 GB device will be OOM-killed.
   Needs a pre-flight check against available RAM.

### Why ONNX Runtime and not llama.cpp today

ONNX Runtime Mobile ships prebuilt Android and iOS binaries through a Flutter
plugin, so the integration is real with no custom native build. `llama.cpp` would
need CMake/Xcode plumbing per platform — the right investment when there is a real
LLM to run, and unjustifiable to prove a 130 KB classifier.

The `InferenceEngine` boundary means that choice is reversible, which is the point.

---

## 6. Retraining

```bash
pip install onnx numpy onnxruntime
python tools/train_router_model.py
```

Writes the model, the metadata sidecar, and the golden fixture. Then
`flutter test` verifies Dart still matches Python.

The training corpus is hand-authored templates in the script (~100 examples,
expanded to 309 with casing and punctuation variants). Training accuracy is 1.000,
which on a corpus that small means **it is overfit to this vocabulary** — it is a
keyword-ish router, not a general intent classifier, and I would not claim
otherwise. It classifies the phrasings this app sees, including Indonesian
greetings and thanks (`halo`, `terima kasih`), because those were in the corpus.

Making it genuinely general would mean real labelled data and a held-out
evaluation set. For deciding "can the local path answer this?", the current model
is adequate and its failure mode is safe: an unrecognised request is classified as
`question`, which the on-device engine declines and routes to the cloud.
