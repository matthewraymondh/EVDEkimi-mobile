import 'dart:async';

import 'package:evdekimi_ai/core/config/app_config.dart';
import 'package:evdekimi_ai/core/connectivity/connectivity_service.dart';
import 'package:evdekimi_ai/core/logging/app_logger.dart';
import 'package:evdekimi_ai/core/network/api_client.dart';
import 'package:evdekimi_ai/core/network/auth_token_delegate.dart';
import 'package:evdekimi_ai/core/network/dio_factory.dart';
import 'package:evdekimi_ai/core/network/sse/sse_client.dart';
import 'package:evdekimi_ai/core/persistence/app_database.dart';
import 'package:evdekimi_ai/features/ai/data/engines/engine_router.dart';
import 'package:evdekimi_ai/features/ai/data/onnx/onnx_router_model.dart';
import 'package:evdekimi_ai/features/ai/domain/inference_engine.dart';
import 'package:evdekimi_ai/features/ai/domain/model_descriptor.dart';
import 'package:evdekimi_ai/features/chat/data/local/conversation_dao.dart';
import 'package:evdekimi_ai/features/chat/data/local/message_dao.dart';
import 'package:evdekimi_ai/features/chat/data/local/outbox_dao.dart';
import 'package:evdekimi_ai/features/chat/data/repositories/chat_repository_impl.dart';
import 'package:evdekimi_ai/features/chat/data/semantic_search_service.dart';
import 'package:evdekimi_ai/features/chat/domain/entities/conversation.dart';
import 'package:evdekimi_ai/features/chat/domain/entities/message.dart';
import 'package:evdekimi_ai/features/settings/domain/app_settings.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Lifecycle guarantees for a streaming generation.
///
/// Every test here corresponds to a defect found in review. They are grouped
/// because they share a root cause: a generation has **three** exits — done,
/// error, and cancelled — and code wired to only the first two silently skips
/// cleanup on the third.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  late AppDatabase database;
  late MessageDao messageDao;
  late OutboxDao outboxDao;
  late ConversationDao conversationDao;
  late _ScriptedEngine engine;

  /// The on-device slot. Separate from [engine] so a test can make the remote
  /// engine unreachable and observe a genuine offline fallback — with one
  /// instance in both slots the router can never produce one.
  late _ScriptedEngine localEngine;
  late ChatRepositoryImpl repository;

  const conversationId = 'conv-1';

  setUp(() async {
    database = AppDatabase(
      logger: AppLogger.silent(),
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    messageDao = MessageDao(database);
    outboxDao = OutboxDao(database);
    conversationDao = ConversationDao(database);
    engine = _ScriptedEngine();
    localEngine = _ScriptedEngine();

    final config = AppConfig.test();
    final logger = AppLogger.silent();
    final connectivity = FakeConnectivityService();
    final onnx = OnnxRouterModel(logger: logger, bundle: _DeadBundle());
    final apiClient = ApiClient(
      dio: DioFactory.create(
        config: config,
        logger: logger,
        authDelegate: const NoopAuthTokenDelegate(),
      ),
      sseClient: SseClient(
        dio: DioFactory.create(
          config: config,
          logger: logger,
          authDelegate: const NoopAuthTokenDelegate(),
        ),
        logger: logger,
        authDelegate: const NoopAuthTokenDelegate(),
      ),
    );

    repository = ChatRepositoryImpl(
      database: database,
      conversationDao: conversationDao,
      messageDao: messageDao,
      outboxDao: outboxDao,
      engineRouter: EngineRouter(
        remoteEngine: engine,
        onDeviceEngine: localEngine,
        connectivity: connectivity,
        logger: logger,
        fallbackRemoteModelId: () => 'gpt-4o-mini',
      ),
      embedder: onnx,
      search: SemanticSearchService(
        messageDao: messageDao,
        embedder: onnx,
        logger: logger,
      ),
      connectivity: connectivity,
      apiClient: apiClient,
      config: config,
      logger: logger,
      readSettings: () => const AppSettings(),
    );

    await conversationDao.insert(
      Conversation.draft(
        id: conversationId,
        modelId: 'gpt-4o-mini',
        engine: EngineKind.remote,
        now: DateTime.utc(2026, 8, 8),
      ),
    );
  });

  tearDown(() async {
    await repository.dispose();
    await database.close();
  });

  Future<Message> assistantMessage() async {
    final messages = await messageDao.findByConversation(conversationId);
    return messages.firstWhere((message) => message.isFromAssistant);
  }

  group('stopping a generation', () {
    test('keeps the partial answer instead of blanking it', () async {
      // Regression: the throttled persist timer kept running after Stop and
      // wrote the just-cleared buffer over the row, destroying the partial text
      // the user had already read.
      await repository.sendMessage(
        conversationId: conversationId,
        content: 'hello',
      );
      await engine.emitted.future;
      engine.emit(const InferenceDelta('Partial answer'));
      await pumpEventQueue();

      await repository.stopGeneration(conversationId);
      // Well past the 250 ms persist interval.
      await Future<void>.delayed(const Duration(milliseconds: 600));

      final assistant = await assistantMessage();
      expect(assistant.content, equals('Partial answer'));
      expect(assistant.status, equals(MessageStatus.cancelled));
    });

    test('completes rather than hanging forever', () async {
      // Regression: cancellation fires neither onDone nor onError, so the
      // completer never resolved. Any awaited generation — every flushOutbox
      // pass — deadlocked, and the outbox never delivered again.
      await repository.sendMessage(
        conversationId: conversationId,
        content: 'hello',
      );
      await engine.emitted.future;

      await expectLater(
        repository
            .stopGeneration(conversationId)
            .timeout(const Duration(seconds: 5)),
        completes,
      );
    });

    test('leaves the outbox able to flush again afterwards', () async {
      // The user-visible consequence of the deadlock above.
      await repository.sendMessage(
        conversationId: conversationId,
        content: 'hello',
      );
      await engine.emitted.future;
      await repository.stopGeneration(conversationId);

      // The message is still queued, so this starts a fresh generation. Let it
      // terminate on its own; what is under test is that the flush is reachable
      // at all, not what the second attempt returns.
      engine
        ..reset()
        ..autoFailWith = StateError('offline again');

      final result = await repository.flushOutbox().timeout(
        const Duration(seconds: 5),
      );
      expect(result.isOk, isTrue);
    });
  });

  group('a failing generation', () {
    test('marks the message failed and keeps partial content', () async {
      await repository.sendMessage(
        conversationId: conversationId,
        content: 'hello',
      );
      await engine.emitted.future;
      engine.emit(const InferenceDelta('Half an ans'));
      await pumpEventQueue();
      engine.fail(StateError('upstream exploded'));
      await pumpEventQueue(times: 40);

      final assistant = await assistantMessage();
      expect(assistant.status, equals(MessageStatus.failed));
      // Deleting text the user already read is worse than leaving it marked.
      expect(assistant.content, equals('Half an ans'));
      expect(assistant.errorMessage, isNotNull);
    });

    test('applies outbox backoff instead of retrying forever', () async {
      // Regression: _runGeneration swallowed stream errors and returned
      // normally, so flushOutbox's catch was unreachable — no backoff, no
      // abandonment, and failures counted as delivered.
      await repository.sendMessage(
        conversationId: conversationId,
        content: 'hello',
      );
      await engine.emitted.future;
      engine.fail(StateError('boom'));
      await pumpEventQueue(times: 40);

      expect(await outboxDao.count(), equals(1), reason: 'still queued');

      engine
        ..reset()
        ..autoFailWith = StateError('still broken');
      final delivered = await repository.flushOutbox();

      // The entry failed again, so it must be backed off rather than reported
      // as delivered.
      expect(delivered.valueOrNull, equals(0));
      expect(await outboxDao.findDue(), isEmpty);
    });
  });

  group('a deferred reply', () {
    test(
      'stays queued when it only landed here because we were offline',
      () async {
        // The demo case: the conversation is on a cloud model, the network is
        // down, and the local engine takes it as a fallback and refuses. A cloud
        // engine will answer properly on reconnect, so the row has to survive —
        // otherwise the offline banner promises a send that never happens.
        engine.available = false;

        await repository.sendMessage(
          conversationId: conversationId,
          content: 'how much is a villa in canggu',
        );
        await localEngine.emitted.future;
        localEngine
          ..emit(const InferenceDelta('I cannot answer that on this device.'))
          ..completeWith(FinishReason.deferred);
        await pumpEventQueue(times: 40);

        final assistant = await assistantMessage();
        expect(assistant.content, contains('cannot answer'));
        expect(assistant.status, equals(MessageStatus.queued));
        expect(
          await outboxDao.count(),
          equals(1),
          reason: 'a cloud engine still owes this answer',
        );
      },
    );

    test('completes when the user chose this model themselves', () async {
      // The regression that made the first version of this fix worse than the
      // bug. If the conversation is pinned to the local model, reconnecting
      // routes straight back to it, so a queued row is re-run by every flush —
      // the same refusal streaming in over and over, badge never clearing.
      // For that conversation the refusal *is* the answer.
      await repository.sendMessage(
        conversationId: conversationId,
        content: 'how much is a villa in canggu',
      );
      await engine.emitted.future;
      engine
        ..emit(const InferenceDelta('I cannot answer that on this device.'))
        ..completeWith(FinishReason.deferred);
      await pumpEventQueue(times: 40);

      expect((await assistantMessage()).status, equals(MessageStatus.complete));
      expect(
        await outboxDao.count(),
        isZero,
        reason: 'nothing will ever answer this differently, so it is not owed',
      );
    });

    test('a real answer still clears the outbox', () async {
      await repository.sendMessage(
        conversationId: conversationId,
        content: 'hello',
      );
      await engine.emitted.future;
      engine
        ..emit(const InferenceDelta('Hello back.'))
        ..complete();
      await pumpEventQueue(times: 40);

      expect((await assistantMessage()).status, equals(MessageStatus.complete));
      expect(await outboxDao.count(), isZero);
    });
  });

  group('a flush while a reply is streaming', () {
    test('leaves the in-flight generation alone', () async {
      // The bug this exists for: an outbox entry stays due for the whole time
      // its reply is streaming, because it is only removed once the answer
      // lands. A flush firing in that window used to call `_runGeneration`
      // again, which opens by cancelling whatever is in flight — so a reply the
      // user was watching finish got blanked and typed out a second time.
      await repository.sendMessage(
        conversationId: conversationId,
        content: 'hello',
      );
      await engine.emitted.future;
      engine.emit(const InferenceDelta('Half an answer'));
      await pumpEventQueue(times: 10);

      final generationsBefore = engine.generateCalls;
      await repository.flushOutbox();
      await pumpEventQueue(times: 10);

      expect(
        engine.generateCalls,
        equals(generationsBefore),
        reason: 'the entry is due, but it is already being delivered',
      );

      // And the original stream is still live, so the answer finishes normally.
      engine
        ..emit(const InferenceDelta(' arrives'))
        ..complete();
      await pumpEventQueue(times: 40);

      final assistant = await assistantMessage();
      expect(assistant.content, equals('Half an answer arrives'));
      expect(assistant.status, equals(MessageStatus.complete));
      expect(
        assistant.status,
        isNot(equals(MessageStatus.cancelled)),
        reason: 'a flush must never cancel a healthy generation',
      );
      expect(await outboxDao.count(), isZero);
    });

    test('still delivers once the generation has finished', () async {
      // The guard must not turn into a permanent skip: once the conversation is
      // idle again a genuinely stuck entry has to flush as normal.
      await repository.sendMessage(
        conversationId: conversationId,
        content: 'hello',
      );
      await engine.emitted.future;
      engine.fail(Exception('network died'));
      await pumpEventQueue(times: 40);

      expect(await outboxDao.count(), equals(1));

      engine.reset();
      await outboxDao.markDueNow(
        (await outboxDao.findDue(limit: 10)).first.messageId,
      );
      final generationsBefore = engine.generateCalls;

      unawaited(repository.flushOutbox());
      await engine.emitted.future;
      expect(engine.generateCalls, equals(generationsBefore + 1));

      engine
        ..emit(const InferenceDelta('Recovered'))
        ..complete();
      await pumpEventQueue(times: 40);

      expect((await assistantMessage()).content, equals('Recovered'));
      expect(await outboxDao.count(), isZero);
    });
  });

  group('a successful generation', () {
    test('completes the message and clears the outbox', () async {
      await repository.sendMessage(
        conversationId: conversationId,
        content: 'hello',
      );
      await engine.emitted.future;
      engine
        ..emit(const InferenceDelta('All '))
        ..emit(const InferenceDelta('done'))
        ..complete();
      await pumpEventQueue(times: 40);

      final assistant = await assistantMessage();
      expect(assistant.content, equals('All done'));
      expect(assistant.status, equals(MessageStatus.complete));
      expect(await outboxDao.count(), isZero);
    });

    test(
      'does not get resurrected as streaming by a late timer write',
      () async {
        await repository.sendMessage(
          conversationId: conversationId,
          content: 'hello',
        );
        await engine.emitted.future;
        engine
          ..emit(const InferenceDelta('Final text'))
          ..complete();
        await pumpEventQueue(times: 40);
        await Future<void>.delayed(const Duration(milliseconds: 600));

        final assistant = await assistantMessage();
        expect(assistant.status, equals(MessageStatus.complete));
        expect(assistant.content, equals('Final text'));
      },
    );
  });

  group('EngineRouter model selection', () {
    test('swaps the model id when redirecting on-device to cloud', () async {
      // Regression: the cloud request kept the on-device model id, so the
      // backend rejected it as an unknown model.
      final unavailable = _ScriptedEngine(available: false);
      final router = EngineRouter(
        remoteEngine: _ScriptedEngine(),
        onDeviceEngine: unavailable,
        connectivity: FakeConnectivityService(),
        logger: AppLogger.silent(),
        fallbackRemoteModelId: () => 'gpt-4o-mini',
      );

      final decision = await router.resolve(model: KnownModels.onDevice);

      expect(decision.canGenerateNow, isTrue);
      expect(decision.reason, equals(RoutingReason.onDeviceUnavailable));
      expect(decision.modelId, equals('gpt-4o-mini'));
      expect(decision.modelId, isNot(equals(KnownModels.onDeviceRouter)));
    });

    test('honours the on-device-when-offline preference', () async {
      // The Settings toggle was previously ignored on the send path.
      final router = EngineRouter(
        remoteEngine: _ScriptedEngine(available: false),
        onDeviceEngine: _ScriptedEngine(),
        connectivity: FakeConnectivityService(NetworkStatus.offline),
        logger: AppLogger.silent(),
        fallbackRemoteModelId: () => 'gpt-4o-mini',
      );

      const cloudModel = ModelDescriptor(
        id: 'gpt-4o-mini',
        name: 'Cloud',
        provider: 'test',
        engine: EngineKind.remote,
      );

      final allowed = await router.resolve(model: cloudModel);
      expect(allowed.reason, equals(RoutingReason.offlineFallback));

      final refused = await router.resolve(
        model: cloudModel,
        allowOnDeviceFallback: false,
      );
      expect(refused.reason, equals(RoutingReason.queued));
      expect(refused.canGenerateNow, isFalse);
    });
  });
}

/// An engine driven imperatively by the test.
class _ScriptedEngine implements InferenceEngine {
  _ScriptedEngine({this.available = true});

  /// Mutable so a test can take the remote engine offline mid-setup.
  bool available;

  StreamController<InferenceEvent>? _controller;

  /// Resolves once `generate` has been subscribed to and has emitted its start
  /// event, so tests do not race the repository.
  Completer<void> emitted = Completer<void>();

  /// When set, a generation terminates on its own instead of waiting to be
  /// driven. Needed because a flush starts a *new* generation, and a scripted
  /// engine that waits forever would hang the flush rather than test it.
  Object? autoFailWith;

  /// How many times `generate` has been subscribed to. The whole point of the
  /// flush guard is that this does not go up while one is already running.
  int generateCalls = 0;

  @override
  EngineKind get kind => EngineKind.remote;

  @override
  EngineCapabilities get capabilities => const EngineCapabilities(
    supportsStreaming: true,
    supportsVision: false,
    requiresNetwork: false,
  );

  @override
  Future<bool> isAvailable() async => available;

  @override
  Stream<InferenceEvent> generate(InferenceRequest request) {
    // Closed by complete(), fail() or dispose(); the test drives its lifetime.
    // ignore: close_sinks
    final controller = StreamController<InferenceEvent>();
    _controller = controller;
    controller.onListen = () {
      generateCalls++;
      controller.add(InferenceStarted(modelId: request.modelId, engine: kind));
      if (!emitted.isCompleted) emitted.complete();
      final failure = autoFailWith;
      if (failure != null) {
        controller.addError(failure);
        unawaited(controller.close());
      }
    };
    return controller.stream;
  }

  void emit(InferenceEvent event) => _controller?.add(event);

  void complete() {
    _controller?.add(const InferenceCompleted());
    unawaited(_controller?.close());
  }

  /// Ends the stream with an explicit finish reason, so a test can produce the
  /// on-device engine's "I produced text but not an answer" outcome.
  void completeWith(FinishReason reason) {
    _controller?.add(InferenceCompleted(finishReason: reason));
    unawaited(_controller?.close());
  }

  void fail(Object error) {
    _controller?.addError(error);
    unawaited(_controller?.close());
  }

  /// Prepares for a second generation in the same test.
  void reset() => emitted = Completer<void>();

  @override
  Future<void> dispose() async => _controller?.close();
}

/// Asset bundle that always fails, so the ONNX embedder stays unavailable.
class _DeadBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async => throw StateError('no assets');

  @override
  Future<String> loadString(String key, {bool cache = true}) async =>
      throw StateError('no assets');
}
