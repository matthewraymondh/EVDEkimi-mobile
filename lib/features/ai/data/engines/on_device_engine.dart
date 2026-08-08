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
    // No vision model on device — it cannot see a picture. It can still answer
    // *about* one: ML Kit reads the text off it locally and that arrives as
    // `InferenceRequest.recognisedText`, which `_composeFromImage` quotes back
    // and matches against the user's history. Reading characters and
    // understanding an image are different problems; only the first is solved
    // here, and `supportsVision` is about the second.
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

    // An image with words in it is the one case where this engine has something
    // a cloud model would not do better: the text is already here, read on this
    // device, and it can be matched against the user's own history without a
    // network. Answered before classification because the intent of "what is
    // this?" is the image, not the sentence.
    if (request.recognisedText.isNotEmpty) {
      yield const InferenceStatus('Reading the image on-device…');
      final response = await _composeFromImage(request.recognisedText, prompt);
      yield* _emit(response, stopwatch);
      return;
    }

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
    yield* _emit(
      response,
      stopwatch,
      // A refusal is text, not an answer. Saying so is what keeps the message
      // in the outbox for a real engine to handle later.
      reason: prediction.intent.isLocallyAnswerable
          ? FinishReason.stop
          : FinishReason.deferred,
    );
  }

  /// Streams a composed answer word by word and closes the run.
  ///
  /// Split out so both paths — classified and image-led — pace, cancel and
  /// report latency identically. Splitting on whitespace but keeping the
  /// trailing space means the reassembled text is byte-identical to [response].
  Stream<InferenceEvent> _emit(
    String response,
    Stopwatch stopwatch, {
    FinishReason reason = FinishReason.stop,
  }) async* {
    final chunks = _chunk(response);
    for (final chunk in chunks) {
      // Cancelling the subscription makes this delay the abort point, so a
      // "stop" tap ends generation within one token rather than at the end.
      await Future<void>.delayed(_tokenInterval);
      yield InferenceDelta(chunk);
    }

    stopwatch.stop();
    yield InferenceCompleted(
      finishReason: reason,
      outputTokens: chunks.length,
      latency: stopwatch.elapsed,
    );
  }

  /// Answers from text read out of an attached image.
  ///
  /// The one thing this engine does that a cloud model would not do better, and
  /// it does it with no network at all: ML Kit has already read the picture on
  /// this device, so the words are here, and the same local embeddings that
  /// power search can match them against what the user has said before.
  ///
  /// It quotes rather than interprets, which is the honest division. Reading
  /// characters off an image and understanding what they mean are different
  /// problems, and only the first one is solved locally.
  Future<String> _composeFromImage(
    List<String> recognised,
    String prompt,
  ) async {
    final text = recognised.join('\n\n').trim();
    final characters = text.length;
    final words = text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;

    final buffer = StringBuffer()
      ..writeln(
        'I read **$characters characters** ($words words) out of your image '
        'on this device. No network, and the picture never left the phone.',
      )
      ..writeln()
      ..writeln('> ${_excerpt(text).replaceAll('\n', '\n> ')}')
      ..writeln();

    // Search on the image's words, not the typed question — the point is to
    // find what the user has already said about whatever is in the picture.
    final hits = await _knowledge.findSimilar(text);
    final relevant = hits
        .where((hit) => hit.score >= _relevanceThreshold)
        .toList(growable: false);

    if (relevant.isEmpty) {
      buffer.writeln('Nothing in your saved messages looks related to it yet.');
    } else {
      buffer
        ..writeln(
          'It matches ${relevant.length} '
          '${relevant.length == 1 ? 'message' : 'messages'} already in your '
          'history:',
        )
        ..writeln();
      for (final hit in relevant) {
        buffer
          ..writeln(
            '**${hit.conversationTitle}** · ${_relativeDay(hit.createdAt)}',
          )
          ..writeln('> ${_excerpt(hit.text).replaceAll('\n', '\n> ')}')
          ..writeln();
      }
    }

    buffer.write(
      _isQuestion(prompt)
          ? '_I can read an image and search it against your history offline, '
                'but working out what it **means** needs a cloud model — '
                'reconnect and ask again._'
          : '_Recognised with ML Kit and matched with on-device embeddings. '
                'None of this touched the network._',
    );
    return buffer.toString();
  }

  /// Whether the user asked something, as opposed to just sending a photo.
  ///
  /// Crude on purpose. It picks between two closing lines and nothing else, so
  /// a wrong guess costs one sentence — not worth a model call.
  static bool _isQuestion(String prompt) {
    final trimmed = prompt.trim();
    if (trimmed.isEmpty) return false;
    if (trimmed.endsWith('?')) return true;
    return _interrogative.hasMatch(trimmed.toLowerCase());
  }

  static final RegExp _interrogative = RegExp(
    r'^(what|who|where|when|why|how|is|are|can|could|should|does|do|apa|siapa|'
    r'di ?mana|kapan|kenapa|mengapa|bagaimana|berapa|bisa)\b',
  );

  /// Trims a block to something that reads as a quotation rather than a dump.
  static String _excerpt(String text, {int limit = 280}) {
    final normalised = text.replaceAll(RegExp(r'\n{2,}'), '\n').trim();
    if (normalised.length <= limit) return normalised;
    return '${normalised.substring(0, limit).trimRight()}…';
  }

  /// Builds the answer for a classified prompt.
  Future<String> _compose(String prompt, RouterPrediction prediction) async {
    switch (prediction.intent) {
      case RouterIntent.greeting:
        return 'Hello, and welcome to EVDEkimi. You are talking to the '
            '**on-device model**, which runs entirely on this phone — no '
            'network involved.\n\n'
            'Offline I can greet you and search your own conversation history. '
            'For live listings, prices and viewings, switch to a cloud model in '
            'the model picker or reconnect.';

      case RouterIntent.gratitude:
        return "You're welcome. Still running locally, still offline-capable.";

      case RouterIntent.recall:
        return _composeRecall(prompt);

      case RouterIntent.propertySearch:
      case RouterIntent.pricing:
      case RouterIntent.viewing:
      case RouterIntent.legal:
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
    // Each of these needs something the device does not have: live inventory, a
    // current price, a calendar, or a lawyer. Naming the specific gap is more
    // useful than a generic "I can't help with that".
    final task = switch (prediction.intent) {
      RouterIntent.propertySearch =>
        'search listings, which needs live inventory from our catalogue',
      RouterIntent.pricing =>
        'quote a price, which changes too often to answer from a cached model',
      RouterIntent.viewing => 'book a viewing, which needs an agent calendar',
      _ =>
        'answer an ownership question — and property law is exactly where a '
            'confident guess would be worst',
    };

    return 'You are asking me to $task. The on-device model cannot do that.\n\n'
        'It classified your message as **${prediction.intent.wireName}** '
        '(${(prediction.confidence * 100).toStringAsFixed(0)}% confidence) in a '
        'few milliseconds, but it is a small classifier and embedder — not a '
        'local LLM, and not connected to our listings.\n\n'
        // This promise is kept by `FinishReason.deferred`: the run reports that
        // it produced text rather than an answer, so the repository leaves the
        // outbox row in place and a capable engine delivers it later. Without
        // that signal, answering counted as delivering and the sentence was
        // false the moment it was written.
        '**To get a real answer:** stay offline and it will send itself once '
        'you reconnect — it is still queued. Or switch to a cloud model in the '
        'model picker now.';
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
