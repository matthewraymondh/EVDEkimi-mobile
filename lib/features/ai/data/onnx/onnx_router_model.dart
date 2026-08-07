import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:evdekimi_ai/core/error/exceptions.dart';
import 'package:evdekimi_ai/core/logging/app_logger.dart';
import 'package:evdekimi_ai/features/ai/data/onnx/hashing_vectorizer.dart';
import 'package:flutter/services.dart' show AssetBundle, rootBundle;
import 'package:onnxruntime/onnxruntime.dart';

/// What the on-device model thinks a message is asking for.
enum RouterIntent {
  greeting,
  gratitude,

  /// Asking about something earlier in the user's own history.
  recall,
  code,
  summarize,
  question;

  static RouterIntent fromName(String name) => RouterIntent.values.firstWhere(
    (intent) => intent.name == name,
    orElse: () => RouterIntent.question,
  );

  /// Whether the local path can plausibly answer this without the cloud.
  ///
  /// Greetings, thanks and history lookups are answerable from templates plus
  /// the user's own stored messages. Anything requiring world knowledge or
  /// generation is not, and must not be faked locally.
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
  RouterMetadata? _metadata;

  RouterMetadata? get metadata => _metadata;

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

  Future<void> _ensureInitialised() =>
      _initialising ??= _initialise().catchError((Object error) {
        // Latch the failure so we do not retry a broken runtime on every send.
        _unavailable = true;
        _initialising = null;
        throw error;
      });

  Future<void> _initialise() async {
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
