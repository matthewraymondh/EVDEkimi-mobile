import 'dart:typed_data';

import 'package:evdekimi_ai/core/logging/app_logger.dart';
import 'package:evdekimi_ai/features/ai/data/engines/on_device_engine.dart';
import 'package:evdekimi_ai/features/ai/data/onnx/onnx_router_model.dart';
import 'package:evdekimi_ai/features/ai/domain/inference_engine.dart';
import 'package:flutter_test/flutter_test.dart';

/// Answering from an attached image, offline.
///
/// This is the one thing the local engine does that a cloud model would not do
/// better, and the reason it works is a plumbing decision that is easy to undo:
/// OCR text travels as its own field rather than concatenated onto the user's
/// question. Fold it back into the prompt and everything still compiles, the
/// cloud path still works, and the local model quietly starts classifying the
/// contents of photographs instead of the questions about them.
void main() {
  late _FakeKnowledge knowledge;
  late _RecordingRouter router;
  late OnDeviceEngine engine;

  setUp(() {
    knowledge = _FakeKnowledge();
    router = _RecordingRouter();
    engine = OnDeviceEngine(
      model: router,
      knowledge: knowledge,
      logger: AppLogger.silent(),
    );
  });

  Future<String> answer({
    required String typed,
    List<String> recognised = const [],
  }) async {
    final events = await engine
        .generate(
          InferenceRequest(
            modelId: 'on-device',
            turns: [PromptTurn.user(typed)],
            recognisedText: recognised,
          ),
        )
        .toList();

    return events.whereType<InferenceDelta>().map((e) => e.text).join();
  }

  const listing = '''
Villa Melati — Berawa, Canggu
2 bed / 2 bath / private pool
Leasehold to 2049
USD 212,000''';

  test('quotes what it read and says where the reading happened', () async {
    final reply = await answer(typed: 'Read this', recognised: [listing]);

    expect(reply, contains('Villa Melati'));
    expect(reply, contains('${listing.length} characters'));
    expect(
      reply.toLowerCase(),
      contains('never left the phone'),
      reason: 'the privacy claim is the point of doing it locally',
    );
  });

  test('never asks the classifier about an image', () async {
    await answer(typed: 'Read this', recognised: [listing]);

    expect(
      router.prompts,
      isEmpty,
      reason:
          'the classifier has seven property intents and none of them is '
          '"here is a photograph"',
    );
  });

  test(
    'searches history using the image text, not the typed question',
    () async {
      await answer(typed: 'Read this', recognised: [listing]);

      expect(knowledge.queries, hasLength(1));
      expect(knowledge.queries.single, contains('Villa Melati'));
      expect(
        knowledge.queries.single,
        isNot(equals('Read this')),
        reason: 'searching on "read this" would match nothing, every time',
      );
    },
  );

  test('reports matches from the user history', () async {
    knowledge.hits = [
      LocalKnowledgeHit(
        text: 'Are there 2 bed villas in Berawa under 250k?',
        conversationTitle: 'Canggu budget',
        score: 0.82,
        createdAt: DateTime.now().subtract(const Duration(days: 1)),
      ),
    ];

    final reply = await answer(typed: '', recognised: [listing]);

    expect(reply, contains('Canggu budget'));
    expect(reply, contains('villas in Berawa'));
  });

  test('says so plainly when nothing in history relates', () async {
    final reply = await answer(typed: '', recognised: [listing]);
    expect(reply, contains('Nothing in your saved messages'));
  });

  test('ignores a match the embeddings are not confident about', () async {
    knowledge.hits = [
      LocalKnowledgeHit(
        text: 'What time is the flight',
        conversationTitle: 'Travel',
        score: 0.2,
        createdAt: DateTime.now(),
      ),
    ];

    final reply = await answer(typed: '', recognised: [listing]);
    expect(reply, isNot(contains('Travel')));
    expect(reply, contains('Nothing in your saved messages'));
  });

  test('points at the cloud only when something was actually asked', () async {
    final asked = await answer(
      typed: 'What is the price here?',
      recognised: [listing],
    );
    expect(asked, contains('needs a cloud model'));

    final unasked = await answer(typed: '', recognised: [listing]);
    expect(
      unasked,
      isNot(contains('needs a cloud model')),
      reason: 'a bare photo is not an unanswered question',
    );
  });

  test('falls back to classification when there is no image', () async {
    await answer(typed: 'Show me villas in Canggu');

    expect(router.prompts, equals(['Show me villas in Canggu']));
  });
}

/// Records what the classifier was asked, and answers the same way every time.
///
/// Subclasses the real model rather than reimplementing it, so the fake cannot
/// drift out of sync with the interface it stands in for.
class _RecordingRouter extends OnnxRouterModel {
  _RecordingRouter() : super(logger: AppLogger.silent());

  final List<String> prompts = [];

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<RouterPrediction?> predict(String text) async {
    prompts.add(text);
    return RouterPrediction(
      intent: RouterIntent.propertySearch,
      confidence: 0.9,
      embedding: Float32List(64),
      probabilities: const {RouterIntent.propertySearch: 0.9},
    );
  }

  @override
  Future<Float32List?> embed(String text) async => Float32List(64);

  @override
  Future<void> dispose() async {}
}

class _FakeKnowledge implements LocalKnowledgeSource {
  final List<String> queries = [];
  List<LocalKnowledgeHit> hits = const [];

  @override
  Future<List<LocalKnowledgeHit>> findSimilar(String query, {int limit = 5}) {
    queries.add(query);
    return Future.value(hits);
  }
}
