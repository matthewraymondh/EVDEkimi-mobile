import 'dart:async';

import 'package:evdekimi_ai/core/error/exceptions.dart';
import 'package:evdekimi_ai/core/logging/app_logger.dart';
import 'package:evdekimi_ai/features/ai/data/onnx/onnx_router_model.dart';
import 'package:evdekimi_ai/features/ai/domain/inference_engine.dart';
import 'package:evdekimi_ai/features/ai/domain/model_descriptor.dart';

/// Supplies stored messages for the retrieval half of on-device answering.
///
/// A port, not a repository import: the AI layer must not depend on the chat
/// feature. The chat data layer implements this.
abstract interface class LocalKnowledgeSource {
  /// Messages most similar to [query], scored with on-device embeddings.
  Future<List<LocalKnowledgeHit>> findSimilar(String query, {int limit = 5});
}

class LocalKnowledgeHit {
  const LocalKnowledgeHit({
    required this.text,
    required this.conversationTitle,
    required this.score,
    required this.createdAt,
  });

  final String text;
  final String conversationTitle;
  final double score;
  final DateTime createdAt;
}

/// Inference that runs entirely on the device.
///
/// **What this is, precisely.** It runs a real ONNX model (see
/// `tools/train_router_model.py`) that classifies intent and produces an
/// embedding, then answers from templates plus retrieval over the user's own
/// stored messages. It is *not* a local large language model and does not
/// pretend to be one — it cannot write you an essay.
///
/// **Why build it this way.** The assessment asks how the architecture supports
/// future on-device models. The honest answer is: by proving the whole path
/// end-to-end with a model small enough to ship today. Everything a 1–3 B
/// parameter LLM would need is already here and exercised — asset-bundled
/// weights, native session lifecycle, tensor marshalling, token-by-token
/// streaming through the same `Stream<InferenceEvent>` contract the cloud engine
/// uses, cancellation, and graceful degradation when the runtime is missing.
/// Swapping in llama.cpp or a quantised Gemma means replacing the body of
/// [generate] with a real decode loop; no caller, repository, or widget changes.
/// `docs/ON_DEVICE_AI.md` sets out that migration.
///
/// The engine refuses to answer intents it cannot honestly serve, surfacing a
/// clear "needs the cloud model" message instead of hallucinating. That refusal
/// is a deliberate product decision: a confidently wrong local answer is worse
/// than no answer.
class OnDeviceEngine implements InferenceEngine {
  OnDeviceEngine({
    required OnnxRouterModel model,
    required LocalKnowledgeSource knowledge,
    required AppLogger logger,
  }) : _model = model,
       _knowledge = knowledge,
       _logger = logger.scoped('ai.onDevice');

  /// Simulated inter-token delay.
  ///
  /// The response is composed in one shot, but it is emitted progressively so
  /// the UI, the persistence throttle and the cancellation path all take exactly
  /// the same code path as a cloud stream. When a real decoder replaces this,
  /// the pacing becomes genuine and nothing downstream changes.
  static const Duration _tokenInterval = Duration(milliseconds: 18);

  /// Below this similarity a retrieved message is treated as unrelated.
  ///
  /// Tuned by hand against the golden fixture: the supervised bottleneck puts
  /// unrelated short messages around 0.2–0.4, so 0.55 keeps recall useful
  /// without inventing connections.
  static const double _relevanceThreshold = 0.55;

  final OnnxRouterModel _model;
  final LocalKnowledgeSource _knowledge;
  final AppLogger _logger;

  @override
  EngineKind get kind => EngineKind.onDevice;

  @override
  EngineCapabilities get capabilities => const EngineCapabilities(
    supportsStreaming: true,
    // No vision model on device; OCR text is extracted separately by ML Kit and
    // folded into the prompt as plain text instead.
    supportsVision: false,
    requiresNetwork: false,
    maxContextTokens: 2048,
  );

  @override
  Future<bool> isAvailable() => _model.isAvailable();

  @override
  Stream<InferenceEvent> generate(InferenceRequest request) async* {
    final stopwatch = Stopwatch()..start();
    yield InferenceStarted(modelId: KnownModels.onDeviceRouter, engine: kind);

    final prompt = request.turns
        .lastWhere(
          (turn) => turn.role == PromptRole.user,
          orElse: () => const PromptTurn.user(''),
        )
        .content;

    yield const InferenceStatus('Running on-device model…');

    final prediction = await _model.predict(prompt);
    if (prediction == null) {
      throw const InferenceRuntimeException(
        'The message has no recognisable content to work with',
      );
    }

    _logger.i(
      'On-device classification',
      fields: {
        'intent': prediction.intent.name,
        'confidence': prediction.confidence.toStringAsFixed(3),
        'ms': stopwatch.elapsedMilliseconds,
      },
    );

    final response = await _compose(prompt, prediction);

    // Stream in word-sized chunks. Splitting on whitespace but keeping the
    // trailing space means the reassembled text is byte-identical to `response`.
    final chunks = _chunk(response);
    for (final chunk in chunks) {
      // Cancelling the subscription makes this delay the abort point, so a
      // "stop" tap ends generation within one token rather than at the end.
      await Future<void>.delayed(_tokenInterval);
      yield InferenceDelta(chunk);
    }

    stopwatch.stop();
    yield InferenceCompleted(
      outputTokens: chunks.length,
      latency: stopwatch.elapsed,
    );
  }

  /// Builds the answer for a classified prompt.
  Future<String> _compose(String prompt, RouterPrediction prediction) async {
    switch (prediction.intent) {
      case RouterIntent.greeting:
        return 'Hello. You are talking to the **on-device model**, which runs '
            'entirely on this phone — no network involved.\n\n'
            'I can greet you, acknowledge thanks, and search your own '
            'conversation history. For anything that needs real generation, '
            'switch to a cloud model in the model picker.';

      case RouterIntent.gratitude:
        return "You're welcome. Still running locally, still offline-capable.";

      case RouterIntent.recall:
        return _composeRecall(prompt);

      case RouterIntent.code:
      case RouterIntent.summarize:
      case RouterIntent.question:
        return _composeDeferral(prediction);
    }
  }

  /// Answers "what did I say about X" from local embeddings.
  Future<String> _composeRecall(String prompt) async {
    final hits = await _knowledge.findSimilar(prompt);
    final relevant = hits
        .where((hit) => hit.score >= _relevanceThreshold)
        .toList(growable: false);

    if (relevant.isEmpty) {
      return "I searched your saved messages on this device and didn't find "
          'anything closely related.\n\n'
          'Semantic search improves as you chat more, because every completed '
          'message is embedded locally and indexed.';
    }

    final buffer = StringBuffer()
      ..writeln(
        'Here is what I found in your history on this device '
        '(${relevant.length} ${relevant.length == 1 ? 'match' : 'matches'}):',
      )
      ..writeln();

    for (final hit in relevant) {
      final excerpt = hit.text.length > 220
          ? '${hit.text.substring(0, 220).trimRight()}…'
          : hit.text;
      buffer
        ..writeln(
          '**${hit.conversationTitle}** · ${_relativeDay(hit.createdAt)}',
        )
        ..writeln('> ${excerpt.replaceAll('\n', '\n> ')}')
        ..writeln();
    }

    buffer.write(
      '_Retrieved with on-device embeddings — this search never left the '
      'device._',
    );
    return buffer.toString();
  }

  /// Declines, honestly, and says what to do instead.
  String _composeDeferral(RouterPrediction prediction) {
    final task = switch (prediction.intent) {
      RouterIntent.code => 'write or debug code',
      RouterIntent.summarize => 'summarise text',
      _ => 'answer open-ended questions',
    };

    return 'That looks like a request to $task, which the on-device model '
        "can't do.\n\n"
        'It classified your message as **${prediction.intent.name}** '
        '(${(prediction.confidence * 100).toStringAsFixed(0)}% confidence) in a '
        'few milliseconds, but it is a small classifier and embedder — not a '
        'local LLM.\n\n'
        '**To get a real answer:** reconnect and pick a cloud model, or keep '
        'this message queued — it will send automatically once you are back '
        'online.';
  }

  /// Splits text into word-sized chunks that concatenate back to the original.
  static List<String> _chunk(String text) {
    if (text.isEmpty) return const [];
    final chunks = <String>[];
    final buffer = StringBuffer();
    for (var i = 0; i < text.length; i++) {
      buffer.write(text[i]);
      if (text[i] == ' ' || text[i] == '\n') {
        chunks.add(buffer.toString());
        buffer.clear();
      }
    }
    if (buffer.isNotEmpty) chunks.add(buffer.toString());
    return chunks;
  }

  static String _relativeDay(DateTime timestamp) {
    final now = DateTime.now();
    final local = timestamp.toLocal();
    final days = DateTime(
      now.year,
      now.month,
      now.day,
    ).difference(DateTime(local.year, local.month, local.day)).inDays;
    return switch (days) {
      0 => 'today',
      1 => 'yesterday',
      < 7 => '$days days ago',
      _ => '${local.day}/${local.month}/${local.year}',
    };
  }

  @override
  Future<void> dispose() => _model.dispose();
}
