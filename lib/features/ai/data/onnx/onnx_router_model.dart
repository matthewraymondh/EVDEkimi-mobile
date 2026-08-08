import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:evdekimi_ai/core/error/exceptions.dart';
import 'package:evdekimi_ai/core/logging/app_logger.dart';
import 'package:evdekimi_ai/features/ai/data/onnx/hashing_vectorizer.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart' show AssetBundle, rootBundle;
import 'package:onnxruntime/onnxruntime.dart';

/// What the on-device model thinks a message is asking for.
/// The intents the model is trained on.
///
/// These are the classes an EVDEkimi property assistant actually sees, not
/// generic chatbot categories — searching listings, asking price, booking a
/// viewing, and the ownership questions that dominate Bali real estate.
///
/// Declaration order **is** the softmax output order and is part of the contract
/// with `tools/train_router_model.py`. Append only; reordering silently remaps
/// every prediction, which is why a test pins it.
enum RouterIntent {
  greeting('greeting'),
  gratitude('gratitude'),

  /// Asking about something earlier in the user's own history.
  recall('recall'),

  /// Looking for listings — area, bedrooms, features.
  propertySearch('property_search'),

  /// Price, budget, yield, fees.
  pricing('pricing'),

  /// Arranging a site visit or a call.
  viewing('viewing'),

  /// Ownership structures: leasehold, freehold, Hak Pakai, PT PMA.
  legal('legal');

  const RouterIntent(this.wireName);

  /// The label as the training script writes it.
  ///
  /// Kept separate from the Dart identifier because the model's labels are
  /// snake_case and Dart enum names are lowerCamelCase. Deriving one from the
  /// other by string munging would be a silent failure waiting to happen.
  final String wireName;

  static RouterIntent fromName(String name) => RouterIntent.values.firstWhere(
    (intent) => intent.wireName == name,
    // An unrecognised label means the asset is newer than this build. Falling
    // back to a cloud-routed intent is the safe direction: it defers rather
    // than answering locally with a class we do not understand.
    orElse: () => RouterIntent.propertySearch,
  );

  /// Whether the local path can plausibly answer this without the cloud.
  ///
  /// Greetings, thanks and history lookups are answerable from templates plus
  /// the user's own stored messages. Anything needing live inventory, a price,
  /// a calendar or legal advice is not, and must not be faked locally — a
  /// confidently wrong answer about property law is worse than no answer.
  bool get isLocallyAnswerable =>
      this == RouterIntent.greeting ||
      this == RouterIntent.gratitude ||
      this == RouterIntent.recall;
}

/// One inference result.
class RouterPrediction {
  const RouterPrediction({
    required this.intent,
    required this.confidence,
    required this.embedding,
    required this.probabilities,
  });

  final RouterIntent intent;

  /// Probability of [intent], in `[0, 1]`.
  final double confidence;

  /// 64-d supervised bottleneck, used for semantic search.
  final Float32List embedding;

  final Map<RouterIntent, double> probabilities;
}

/// Loads and runs the bundled ONNX router through ONNX Runtime Mobile.
///
/// Real native inference: `OrtEnv` initialises the runtime, the graph is loaded
/// from the asset bundle into a session once, and each call runs a MatMul →
/// tanh → MatMul → Softmax forward pass on the CPU execution provider.
///
/// Two operational details worth noting:
///
/// * **Lazy, single-flight initialisation.** The session is built on first use,
///   not at app start, so a cold launch is not slowed by loading weights that
///   many sessions never need. Concurrent first callers share one future.
/// * **Failure is not fatal.** If the runtime is unavailable (an unsupported
///   ABI, a stripped native library), [isAvailable] reports false and the app
///   falls back to the cloud engine. On-device inference is an enhancement, and
///   it must never be the reason the app cannot send a message.
class OnnxRouterModel {
  OnnxRouterModel({
    required AppLogger logger,
    AssetBundle? bundle,
    HashingVectorizer vectorizer = const HashingVectorizer(),
  }) : _logger = logger.scoped('ai.onnx'),
       _bundle = bundle,
       _vectorizer = vectorizer;

  static const String modelAsset = 'assets/models/evdekimi_router_v1.onnx';
  static const String metadataAsset = 'assets/models/evdekimi_router_v1.json';

  static const String _inputName = 'features';
  static const String _embeddingOutput = 'embedding';
  static const String _intentOutput = 'intent_probs';

  final AppLogger _logger;
  final AssetBundle? _bundle;
  final HashingVectorizer _vectorizer;

  OrtSession? _session;
  Future<void>? _initialising;
  bool _unavailable = false;
  String? _unavailableReason;
  int _initialisationAttempts = 0;
  RouterMetadata? _metadata;

  RouterMetadata? get metadata => _metadata;

  /// Why the runtime is unusable, once we know. Surfaced in Settings.
  String? get unavailableReason => _unavailableReason;

  /// Whether inference can run. Triggers initialisation if it has not happened.
  Future<bool> isAvailable() async {
    if (_unavailable) return false;
    try {
      await _ensureInitialised();
      return _session != null;
    } catch (_) {
      return false;
    }
  }

  /// Loads the runtime at most once, ever.
  ///
  /// The latch matters more than it looks. `dlopen` of a missing or incompatible
  /// `libonnxruntime.so` costs milliseconds and fails identically every time, and
  /// `embed()` is called on every completed message and every backfill row — so a
  /// broken runtime without this guard means dozens of doomed load attempts and a
  /// wall of identical warnings.
  ///
  /// Note `_initialising` is deliberately *not* cleared on failure: retaining the
  /// failed future is what guarantees `_initialise()` runs once, and the
  /// `_unavailable` check short-circuits every later caller before it even gets
  /// that far.
  Future<void> _ensureInitialised() async {
    if (_unavailable) {
      throw EngineUnavailableException(
        _unavailableReason ?? 'The ONNX runtime failed to load on this device',
      );
    }
    try {
      await (_initialising ??= _initialise());
    } catch (error) {
      _unavailable = true;
      _unavailableReason = _describeFailure(error);
      // Typed on the first failure as well as on every later one. Rethrowing the
      // raw error here would mean callers saw a FlutterError once and an
      // EngineUnavailableException thereafter, and ErrorMapper would classify the
      // same condition two different ways.
      throw EngineUnavailableException(_unavailableReason!, cause: error);
    }
  }

  /// Turns a native loader failure into something a human can act on.
  static String _describeFailure(Object error) {
    final text = error.toString();
    if (text.contains('libonnxruntime.so') || text.contains('dlopen')) {
      // The common case by far: onnxruntime 1.4.1 ships arm64-v8a and
      // armeabi-v7a only, so every x86_64 emulator lands here.
      return 'ONNX Runtime has no native library for this CPU architecture. '
          'The bundled package supports arm64-v8a and armeabi-v7a, so on-device '
          'inference needs an arm64 emulator image or a physical device.';
    }
    // Anything else is shown to a user, so it must not be a raw exception
    // string. The detail is already in the logs for whoever needs it.
    return 'The on-device model could not be loaded on this device. '
        'The app will use cloud models instead.';
  }

  /// How many times [_initialise] has actually run. Must never exceed 1.
  @visibleForTesting
  int get initialisationAttempts => _initialisationAttempts;

  Future<void> _initialise() async {
    _initialisationAttempts++;
    final stopwatch = Stopwatch()..start();
    final bundle = _bundle ?? rootBundle;

    try {
      OrtEnv.instance.init();

      final metadataJson = await bundle.loadString(metadataAsset);
      final metadata = RouterMetadata.fromJson(
        jsonDecode(metadataJson) as Map<String, dynamic>,
      );

      if (metadata.featureDim != _vectorizer.dimensions) {
        // A mismatch here means the asset and the Dart vectorizer were built
        // from different revisions; failing loudly beats silent garbage.
        throw InferenceRuntimeException(
          'Feature dimension mismatch: model expects ${metadata.featureDim}, '
          'vectorizer produces ${_vectorizer.dimensions}',
        );
      }

      final modelBytes = await bundle.load(modelAsset);
      final options = OrtSessionOptions()
        // Single-threaded: the graph is tiny, and spawning a thread pool costs
        // more than the matrix multiply it would parallelise.
        ..setIntraOpNumThreads(1)
        ..setInterOpNumThreads(1)
        ..setSessionGraphOptimizationLevel(GraphOptimizationLevel.ortEnableAll);

      _session = OrtSession.fromBuffer(
        modelBytes.buffer.asUint8List(
          modelBytes.offsetInBytes,
          modelBytes.lengthInBytes,
        ),
        options,
      );
      _metadata = metadata;

      stopwatch.stop();
      _logger.i(
        'ONNX router ready',
        fields: {
          'ort': OrtEnv.version,
          'model': metadata.modelId,
          'sizeKb': (metadata.sizeBytes / 1024).round(),
          'loadMs': stopwatch.elapsedMilliseconds,
        },
      );
    } catch (error, stackTrace) {
      _logger.w(
        'ONNX router unavailable; on-device inference disabled',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  /// Classifies [text] and returns its embedding.
  ///
  /// Returns `null` when the text carries no features (empty or punctuation
  /// only) — the model's output for a zero vector is just its bias and would be
  /// a confidently wrong answer.
  Future<RouterPrediction?> predict(String text) async {
    if (!HashingVectorizer.hasSignal(text)) return null;

    await _ensureInitialised();
    final session = _session;
    if (session == null) {
      throw const EngineUnavailableException('ONNX session is not initialised');
    }

    final features = _vectorizer.transform(text);

    OrtValueTensor? input;
    OrtRunOptions? runOptions;
    List<OrtValue?>? outputs;
    try {
      // Shape [1, featureDim]: the graph is exported with a fixed batch of one.
      input = OrtValueTensor.createTensorWithDataList(features, [
        1,
        _vectorizer.dimensions,
      ]);
      runOptions = OrtRunOptions();

      outputs = await session.runAsync(
        runOptions,
        {_inputName: input},
        [_embeddingOutput, _intentOutput],
      );

      if (outputs == null || outputs.length < 2) {
        throw const InferenceRuntimeException('ONNX run returned no outputs');
      }

      final embedding = _firstRow(outputs[0]?.value);
      final probabilities = _firstRow(outputs[1]?.value);

      if (embedding == null || probabilities == null) {
        throw const InferenceRuntimeException(
          'ONNX outputs had an unexpected shape',
        );
      }

      const intents = RouterIntent.values;
      final scores = <RouterIntent, double>{};
      var bestIndex = 0;
      for (var i = 0; i < probabilities.length && i < intents.length; i++) {
        scores[intents[i]] = probabilities[i];
        if (probabilities[i] > probabilities[bestIndex]) bestIndex = i;
      }

      return RouterPrediction(
        intent: intents[bestIndex.clamp(0, intents.length - 1)],
        confidence: probabilities[bestIndex],
        embedding: embedding,
        probabilities: scores,
      );
    } finally {
      // Native memory: these are FFI allocations, not GC-managed objects, so
      // every one has to be released even on the error path.
      input?.release();
      runOptions?.release();
      if (outputs != null) {
        for (final output in outputs) {
          output?.release();
        }
      }
    }
  }

  /// Just the embedding, for indexing stored messages.
  Future<Float32List?> embed(String text) async =>
      (await predict(text))?.embedding;

  /// Flattens the `[1, N]` tensor the runtime returns into a `Float32List`.
  static Float32List? _firstRow(Object? value) {
    if (value is List && value.isNotEmpty) {
      final first = value.first;
      if (first is List) {
        return Float32List.fromList(
          first.whereType<num>().map((n) => n.toDouble()).toList(),
        );
      }
      return Float32List.fromList(
        value.whereType<num>().map((n) => n.toDouble()).toList(),
      );
    }
    return null;
  }

  Future<void> dispose() async {
    _session?.release();
    _session = null;
    _initialising = null;
    // OrtEnv is process-wide; releasing it here would break any other consumer.
  }
}

/// Sidecar metadata describing the bundled graph.
///
/// Shipping this next to the weights keeps the Dart code from hard-coding
/// dimensions and label order that only the training script really knows.
class RouterMetadata {
  const RouterMetadata({
    required this.modelId,
    required this.version,
    required this.featureDim,
    required this.embeddingDim,
    required this.intents,
    required this.sha256,
    required this.sizeBytes,
  });

  factory RouterMetadata.fromJson(Map<String, dynamic> json) => RouterMetadata(
    modelId: json['modelId'] as String,
    version: (json['version'] as num).toInt(),
    featureDim: (json['featureDim'] as num).toInt(),
    embeddingDim: (json['embeddingDim'] as num).toInt(),
    intents: (json['intents'] as List).cast<String>(),
    sha256: json['sha256'] as String? ?? '',
    sizeBytes: (json['sizeBytes'] as num?)?.toInt() ?? 0,
  );

  final String modelId;
  final int version;
  final int featureDim;
  final int embeddingDim;
  final List<String> intents;
  final String sha256;
  final int sizeBytes;
}
