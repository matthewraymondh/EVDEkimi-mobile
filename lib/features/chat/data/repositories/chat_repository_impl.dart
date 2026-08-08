import 'dart:async';
import 'dart:io';

import 'package:evdekimi_ai/core/config/app_config.dart';
import 'package:evdekimi_ai/core/connectivity/connectivity_service.dart';
import 'package:evdekimi_ai/core/error/error_mapper.dart';
import 'package:evdekimi_ai/core/error/exceptions.dart';
import 'package:evdekimi_ai/core/logging/app_logger.dart';
import 'package:evdekimi_ai/core/network/api_client.dart';
import 'package:evdekimi_ai/core/persistence/app_database.dart';
import 'package:evdekimi_ai/core/persistence/database_schema.dart';
import 'package:evdekimi_ai/core/result/result.dart';
import 'package:evdekimi_ai/features/ai/data/engines/engine_router.dart';
import 'package:evdekimi_ai/features/ai/data/onnx/onnx_router_model.dart';
import 'package:evdekimi_ai/features/ai/domain/inference_engine.dart';
import 'package:evdekimi_ai/features/ai/domain/model_descriptor.dart';
import 'package:evdekimi_ai/features/chat/data/local/conversation_dao.dart';
import 'package:evdekimi_ai/features/chat/data/local/message_dao.dart';
import 'package:evdekimi_ai/features/chat/data/local/outbox_dao.dart';
import 'package:evdekimi_ai/features/chat/data/semantic_search_service.dart';
import 'package:evdekimi_ai/features/chat/domain/entities/conversation.dart';
import 'package:evdekimi_ai/features/chat/domain/entities/message.dart';
import 'package:evdekimi_ai/features/chat/domain/repositories/chat_repository.dart';
import 'package:evdekimi_ai/features/settings/domain/app_settings.dart';
import 'package:uuid/uuid.dart';

/// Offline-first chat, streaming, and the outbox.
///
/// The whole design follows one rule: **write locally, then try the network.**
/// `sendMessage` commits a user row, an assistant placeholder and an outbox entry
/// in a single transaction, then returns. Delivery happens afterwards and is
/// allowed to fail. That is why there is no "offline mode" branch anywhere — the
/// online path is the offline path plus a successful request.
class ChatRepositoryImpl implements ChatRepository {
  ChatRepositoryImpl({
    required AppDatabase database,
    required ConversationDao conversationDao,
    required MessageDao messageDao,
    required OutboxDao outboxDao,
    required EngineRouter engineRouter,
    required OnnxRouterModel embedder,
    required SemanticSearchService search,
    required ConnectivityService connectivity,
    required ApiClient apiClient,
    required AppConfig config,
    required AppLogger logger,
    required AppSettings Function() readSettings,
    Uuid? uuid,
  }) : _readSettings = readSettings,
       _database = database,
       _conversationDao = conversationDao,
       _messageDao = messageDao,
       _outboxDao = outboxDao,
       _engineRouter = engineRouter,
       _embedder = embedder,
       _search = search,
       _connectivity = connectivity,
       _apiClient = apiClient,
       _config = config,
       _logger = logger.scoped('chat.repo'),
       _uuid = uuid ?? const Uuid();

  /// How often streamed content is flushed to SQLite.
  ///
  /// The UI does **not** wait for this. Live tokens reach the widget tree from
  /// an in-memory buffer, so rendering is per-token; the database write is purely
  /// for durability, and throttling it keeps a 200-token answer to ~8 UPDATEs
  /// instead of 200.
  static const Duration _persistInterval = Duration(milliseconds: 250);

  final AppDatabase _database;
  final ConversationDao _conversationDao;
  final MessageDao _messageDao;
  final OutboxDao _outboxDao;
  final EngineRouter _engineRouter;
  final OnnxRouterModel _embedder;
  final SemanticSearchService _search;
  final ConnectivityService _connectivity;
  final ApiClient _apiClient;
  final AppConfig _config;
  final AppLogger _logger;
  final Uuid _uuid;

  /// Read lazily rather than injected as a value: settings change while the
  /// repository lives, and rebuilding the repository to pick them up would tear
  /// down any in-flight generation.
  final AppSettings Function() _readSettings;

  AppSettings get _settings => _readSettings();

  /// Generations currently in flight, keyed by conversation id.
  final Map<String, _ActiveGeneration> _active = {};

  /// Fires the conversation id whenever a live buffer changes.
  final StreamController<String> _liveTicks =
      StreamController<String>.broadcast();

  Future<void>? _flushInFlight;

  // ---------------------------------------------------------------- reads

  @override
  Stream<List<Message>> watchMessages(String conversationId) {
    late StreamController<List<Message>> controller;
    StreamSubscription<List<Message>>? dbSubscription;
    StreamSubscription<String>? tickSubscription;
    var persisted = const <Message>[];

    void emit() {
      if (controller.isClosed) return;
      controller.add(_overlayLiveBuffers(persisted));
    }

    controller = StreamController<List<Message>>(
      onListen: () {
        dbSubscription =
            watchQuery(
              notifier: _database.changes,
              topics: {DatabaseChangeNotifier.messagesOf(conversationId)},
              query: () => _messageDao.findByConversation(conversationId),
            ).listen((rows) {
              persisted = rows;
              emit();
            }, onError: controller.addError);

        tickSubscription = _liveTicks.stream
            .where((id) => id == conversationId)
            .listen((_) => emit());
      },
      onCancel: () async {
        await dbSubscription?.cancel();
        await tickSubscription?.cancel();
        await controller.close();
      },
    );

    return controller.stream;
  }

  /// Replaces persisted content with the live buffer for streaming messages.
  ///
  /// The database row lags by up to [_persistInterval]; this is what makes the
  /// text appear token-by-token without paying for a write per token.
  List<Message> _overlayLiveBuffers(List<Message> messages) {
    if (_active.isEmpty) return messages;

    final buffers = <String, _ActiveGeneration>{
      for (final generation in _active.values)
        generation.assistantMessageId: generation,
    };
    if (buffers.isEmpty) return messages;

    return messages
        .map((message) {
          final generation = buffers[message.id];
          if (generation == null) return message;
          return message.copyWith(
            content: generation.buffer.toString(),
            status: generation.hasContent
                ? MessageStatus.streaming
                : MessageStatus.sending,
          );
        })
        .toList(growable: false);
  }

  @override
  Stream<int> watchPendingCount() => watchQuery(
    notifier: _database.changes,
    topics: {DatabaseChangeNotifier.outbox},
    query: _outboxDao.count,
  );

  // ---------------------------------------------------------------- sending

  @override
  Future<Result<SendMessageOutcome>> sendMessage({
    required String conversationId,
    required String content,
    List<PendingAttachment> attachments = const [],
  }) => Result.guardAsync(() async {
    final trimmed = content.trim();
    if (trimmed.isEmpty && attachments.isEmpty) {
      throw const ApiException(
        message: 'Cannot send an empty message',
        statusCode: 400,
      );
    }

    final now = DateTime.now().toUtc();
    final userMessageId = _uuid.v4();
    final assistantMessageId = _uuid.v4();

    final conversation = await _conversationDao.findById(conversationId);
    if (conversation == null) {
      throw LocalStoreException('Conversation $conversationId not found');
    }
    final model = await _resolveModel(conversation.modelId);

    final attachmentEntities = attachments
        .map(
          (pending) => Attachment(
            id: _uuid.v4(),
            messageId: userMessageId,
            kind: pending.kind,
            localPath: pending.localPath,
            mimeType: pending.mimeType,
            sizeBytes: pending.sizeBytes,
            width: pending.width,
            height: pending.height,
            extractedText: pending.extractedText,
            createdAt: now,
          ),
        )
        .toList(growable: false);

    // One transaction so a crash can never leave a user message without its
    // pending assistant reply, or an outbox entry pointing at nothing.
    await _database.write(
      (txn) async {
        final sequence = await _messageDao.nextSequence(txn, conversationId);

        final userMessage = Message.userDraft(
          id: userMessageId,
          conversationId: conversationId,
          content: trimmed,
          sequence: sequence,
          now: now,
          attachments: attachmentEntities,
        );
        await _messageDao.insertWithin(txn, userMessage);

        final placeholder = Message.assistantPlaceholder(
          id: assistantMessageId,
          conversationId: conversationId,
          sequence: sequence + 1,
          now: now,
          modelId: model.id,
          engine: model.engine,
          replyToId: userMessageId,
        );
        await _messageDao.insertWithin(txn, placeholder);

        await _outboxDao.enqueue(
          messageId: userMessageId,
          conversationId: conversationId,
          // The idempotency key is derived from the message id, so a retry after
          // a lost response is recognised by the server as the same send.
          idempotencyKey: 'msg_$userMessageId',
          payload: {
            'content': trimmed,
            'model_id': model.id,
            'assistant_message_id': assistantMessageId,
          },
          now: now,
          txn: txn,
        );

        // Title the thread from its first message, locally, so a conversation is
        // never stuck on "New chat" just because the device was offline.
        if (!conversation.hasTitle && trimmed.isNotEmpty) {
          await txn.update(
            ConversationColumns.table,
            {
              ConversationColumns.title: ConversationTitle.fromFirstMessage(
                trimmed,
              ),
            },
            where: '${ConversationColumns.id} = ?',
            whereArgs: [conversationId],
          );
        }

        await _conversationDao.refreshSummary(
          conversationId,
          txn: txn,
          now: now,
        );
      },
      topics: {
        DatabaseChangeNotifier.messagesOf(conversationId),
        DatabaseChangeNotifier.conversations,
        DatabaseChangeNotifier.outbox,
      },
    );

    // Fire and forget: the caller gets control back immediately and observes
    // progress through watchMessages.
    final decision = await _engineRouter.resolve(
      model: model,
      allowOnDeviceFallback: _settings.useOnDeviceWhenOffline,
    );
    if (decision.canGenerateNow) {
      // Swallowed on purpose: `_runGeneration` now rethrows so `flushOutbox` can
      // apply backoff, but on this path the failure is already recorded on the
      // assistant message and surfaced in the UI.
      unawaited(
        _runGeneration(
          conversationId: conversationId,
          userMessageId: userMessageId,
          assistantMessageId: assistantMessageId,
          decision: decision,
        ).catchError((Object _) {}),
      );
    } else {
      await _markQueued(conversationId, userMessageId, assistantMessageId);
    }

    return SendMessageOutcome(
      userMessageId: userMessageId,
      assistantMessageId: assistantMessageId,
      wasQueuedOffline: !decision.canGenerateNow,
    );
  });

  @override
  Future<Result<SendMessageOutcome>> regenerate({
    required String conversationId,
    required String assistantMessageId,
  }) => Result.guardAsync(() async {
    final existing = await _messageDao.findById(assistantMessageId);
    if (existing == null) {
      throw LocalStoreException('Message $assistantMessageId not found');
    }

    final conversation = await _conversationDao.findById(conversationId);
    final model = await _resolveModel(
      conversation?.modelId ?? existing.modelId ?? '',
    );

    // Clear the old answer before regenerating so the user sees it restart
    // rather than watching new text append to the previous attempt.
    await _messageDao.update(conversationId, assistantMessageId, {
      MessageColumns.content: '',
      MessageColumns.status: MessageStatus.sending.name,
      MessageColumns.errorMessage: null,
      MessageColumns.errorCode: null,
      MessageColumns.modelId: model.id,
      MessageColumns.engine: model.engine.name,
    });

    final decision = await _engineRouter.resolve(
      model: model,
      allowOnDeviceFallback: _settings.useOnDeviceWhenOffline,
    );
    if (!decision.canGenerateNow) {
      // Must enqueue, not just mark queued. Without an outbox row the flush has
      // nothing to find, and the message sits at "queued" forever with no path
      // back to delivery.
      final userMessageId = existing.replyToId;
      if (userMessageId != null && userMessageId.isNotEmpty) {
        final userMessage = await _messageDao.findById(userMessageId);
        await _outboxDao.enqueue(
          messageId: userMessageId,
          conversationId: conversationId,
          idempotencyKey: 'msg_$userMessageId',
          payload: {
            'content': userMessage?.content ?? '',
            'model_id': model.id,
            'assistant_message_id': assistantMessageId,
          },
        );
      }
      await _markQueued(
        conversationId,
        userMessageId ?? assistantMessageId,
        assistantMessageId,
      );
      return SendMessageOutcome(
        userMessageId: userMessageId ?? '',
        assistantMessageId: assistantMessageId,
        wasQueuedOffline: true,
      );
    }

    unawaited(
      _runGeneration(
        conversationId: conversationId,
        userMessageId: existing.replyToId ?? '',
        assistantMessageId: assistantMessageId,
        decision: decision,
      ).catchError((Object _) {}),
    );

    return SendMessageOutcome(
      userMessageId: existing.replyToId ?? '',
      assistantMessageId: assistantMessageId,
      wasQueuedOffline: false,
    );
  });

  @override
  Future<Result<SendMessageOutcome>> retryMessage({
    required String conversationId,
    required String messageId,
  }) => Result.guardAsync(() async {
    // Clear the previous error so the bubble does not keep showing a stale one
    // while the retry is in flight.
    final message = await _messageDao.findById(messageId);
    final assistantMessageId = message?.role == MessageRole.assistant
        ? messageId
        : await _findAssistantReplyTo(conversationId, messageId) ?? messageId;

    await _messageDao.update(conversationId, assistantMessageId, {
      MessageColumns.status: MessageStatus.queued.name,
      MessageColumns.errorMessage: null,
      MessageColumns.errorCode: null,
    });

    await _outboxDao.markDueNow(messageId);
    final delivered = await flushOutbox();

    return SendMessageOutcome(
      userMessageId: messageId,
      assistantMessageId: assistantMessageId,
      // `flushOutbox` short-circuits to Ok(0) when another flush is already
      // running, so a zero count does not by itself mean "still queued" —
      // check whether the entry actually survived instead.
      wasQueuedOffline:
          delivered.valueOrNull == 0 && await _isStillQueued(messageId),
    );
  });

  /// The assistant message that answers [userMessageId], if there is one.
  Future<String?> _findAssistantReplyTo(
    String conversationId,
    String userMessageId,
  ) async {
    final messages = await _messageDao.findByConversation(conversationId);
    for (final message in messages) {
      if (message.replyToId == userMessageId && message.isFromAssistant) {
        return message.id;
      }
    }
    return null;
  }

  Future<bool> _isStillQueued(String messageId) async {
    final due = await _outboxDao.findDue(limit: 100);
    return due.any((entry) => entry.messageId == messageId);
  }

  @override
  Future<Result<void>> stopGeneration(String conversationId) =>
      Result.guardAsync(() async {
        final generation = _active[conversationId];
        if (generation == null) return;

        _logger.i(
          'Generation stopped by user',
          fields: {'conversation': conversationId},
        );

        // Cancelling the subscription is what actually tears down the socket or
        // the ONNX loop; see the cancellation contract on InferenceEngine.
        await generation.subscription?.cancel();
        _active.remove(conversationId);

        // Stop the throttled writer *before* the final write. It reads the live
        // buffer, which `dispose()` clears, so a timer that survived this point
        // would overwrite the saved partial answer with an empty one.
        generation.persistTimer?.cancel();

        await _messageDao.writeStreamedContent(
          conversationId: conversationId,
          messageId: generation.assistantMessageId,
          content: generation.buffer.toString(),
          status: MessageStatus.cancelled,
        );

        // Cancellation fires neither onDone nor onError, so without this the
        // awaited completion never resolves and `flushOutbox` deadlocks with
        // `_flushInFlight` permanently set.
        generation.dispose();
        _liveTicks.add(conversationId);
      });

  /// Streams one response into an assistant message.
  Future<void> _runGeneration({
    required String conversationId,
    required String userMessageId,
    required String assistantMessageId,
    required RoutingDecision decision,
  }) async {
    final engine = decision.engine;
    if (engine == null) return;

    // A second send while one is running supersedes it; two streams writing to
    // the same conversation would interleave tokens.
    await stopGeneration(conversationId);

    final generation = _ActiveGeneration(
      assistantMessageId: assistantMessageId,
      startedAt: DateTime.now(),
    )..routingReason = decision.reason;
    _active[conversationId] = generation;

    final history = await _buildPromptHistory(
      conversationId,
      excludeMessageId: assistantMessageId,
      contextWindow: engine.capabilities.maxContextTokens,
    );

    final imageUrls = await _uploadPendingAttachments(
      conversationId: conversationId,
      messageId: userMessageId,
      supportsVision: engine.capabilities.supportsVision,
    );

    // Only the message being answered. Older images' text is already in the
    // history as prose, and re-sending every receipt the user ever photographed
    // would eat the context window for no benefit.
    final userMessage = await _messageDao.findById(userMessageId);
    final recognisedText = userMessage?.recognisedText ?? const <String>[];

    final request = InferenceRequest(
      modelId: decision.modelId,
      turns: history,
      systemPrompt: _systemPrompt,
      imageUrls: imageUrls,
      recognisedText: recognisedText,
      conversationId: conversationId,
    );

    Future<void> persist({required MessageStatus status}) async {
      // A timer callback can already be in flight when the generation ends;
      // writing after the terminal write would resurrect a finished message as
      // `streaming` with truncated content.
      if (generation.isFinalised) return;
      generation.persistedLength = generation.buffer.length;
      await _messageDao.writeStreamedContent(
        conversationId: conversationId,
        messageId: assistantMessageId,
        content: generation.buffer.toString(),
        status: status,
      );
    }

    generation.persistTimer = Timer.periodic(_persistInterval, (_) {
      if (generation.buffer.length == generation.persistedLength) return;
      unawaited(persist(status: MessageStatus.streaming));
    });

    generation.subscription = engine
        .generate(request)
        .listen(
          (event) {
            switch (event) {
              case InferenceStarted():
                break;
              case InferenceStatus(:final message):
                generation.statusMessage = message;
                _liveTicks.add(conversationId);
              case InferenceDelta(:final text):
                generation.buffer.write(text);
                // Per-token UI update, no database round-trip.
                _liveTicks.add(conversationId);
              case InferenceCompleted(
                :final outputTokens,
                :final latency,
                :final finishReason,
              ):
                generation.outputTokens = outputTokens;
                generation.latency = latency;
                generation.finishReason = finishReason;
            }
          },
          onError: (Object error, StackTrace stackTrace) {
            // Stop the timer before the terminal write, never after.
            generation.persistTimer?.cancel();
            unawaited(
              _finishWithError(
                conversationId: conversationId,
                assistantMessageId: assistantMessageId,
                generation: generation,
                error: error,
                stackTrace: stackTrace,
              ).whenComplete(
                () => generation.finish(error: error, stackTrace: stackTrace),
              ),
            );
          },
          onDone: () {
            generation.persistTimer?.cancel();
            unawaited(
              _finishSuccessfully(
                conversationId: conversationId,
                userMessageId: userMessageId,
                assistantMessageId: assistantMessageId,
                generation: generation,
              ).whenComplete(generation.finish),
            );
          },
          cancelOnError: true,
        );

    await generation.completion;

    // The engine reports failure through a stream callback, not by throwing, so
    // it is re-thrown here. `flushOutbox` depends on this to apply backoff and
    // eventually abandon an entry; without it every failed send looked delivered
    // and retried forever. Fire-and-forget callers swallow it deliberately —
    // `_finishWithError` has already recorded the failure on the message.
    final failure = generation.failure;
    if (failure != null) {
      Error.throwWithStackTrace(
        failure,
        generation.failureStackTrace ?? StackTrace.current,
      );
    }
  }

  Future<void> _finishSuccessfully({
    required String conversationId,
    required String userMessageId,
    required String assistantMessageId,
    required _ActiveGeneration generation,
  }) async {
    // Cancelled generations are finalised by stopGeneration; do not overwrite.
    if (_active[conversationId] != generation) return;
    _active.remove(conversationId);

    final content = generation.buffer.toString();

    // A deferral is text, not an answer: the on-device engine reports it for
    // questions needing live inventory, a price or a calendar. Whether that
    // leaves the message *owed* depends on why this engine ran at all.
    //
    // Fell back here because the network was down — a cloud engine will take it
    // on reconnect, so the row stays and the refusal's promise is kept.
    //
    // Chosen deliberately — the user picked the local model — and no amount of
    // reconnecting changes the routing. Keeping the row would queue a message
    // that every retry answers the same way: the flush fires, the same refusal
    // streams in again, and the badge never clears. That is a loop, not
    // durability, so the refusal is the final answer for this model.
    final isDeferred =
        generation.finishReason == FinishReason.deferred &&
        generation.routingReason == RoutingReason.offlineFallback;

    await _messageDao.writeStreamedContent(
      conversationId: conversationId,
      messageId: assistantMessageId,
      content: content,
      status: content.trim().isEmpty
          ? MessageStatus.failed
          : isDeferred
          // Still owed. The row keeps its "Queued" badge beside the
          // explanation, and a capable engine overwrites this text later.
          ? MessageStatus.queued
          : MessageStatus.complete,
      tokenCount: generation.outputTokens,
      latency: generation.latency,
    );

    // The reply arrived, so the user message is definitively delivered — unless
    // what arrived was a refusal, in which case the outbox keeps it.
    if (userMessageId.isNotEmpty && !isDeferred) {
      await _messageDao.update(conversationId, userMessageId, {
        MessageColumns.status: MessageStatus.complete.name,
      });
      await _outboxDao.remove(userMessageId);
    }

    await _conversationDao.refreshSummary(conversationId);
    generation.dispose();
    _liveTicks.add(conversationId);

    // Index for offline semantic search. Best-effort: a failure here must not
    // affect the message the user just received.
    unawaited(_search.index(assistantMessageId, content));
  }

  Future<void> _finishWithError({
    required String conversationId,
    required String assistantMessageId,
    required _ActiveGeneration generation,
    required Object error,
    required StackTrace stackTrace,
  }) async {
    if (_active[conversationId] != generation) return;
    _active.remove(conversationId);

    final failure = ErrorMapper.map(error, stackTrace: stackTrace);
    _logger.w(
      'Generation failed',
      fields: {'conversation': conversationId, 'failure': failure.runtimeType},
      error: error,
      stackTrace: stackTrace,
    );

    final partial = generation.buffer.toString();
    await _messageDao.update(conversationId, assistantMessageId, {
      // Partial output is kept: it is usually still useful, and deleting text
      // the user already read is worse than leaving it with an error marker.
      MessageColumns.content: partial,
      MessageColumns.status: MessageStatus.failed.name,
      MessageColumns.errorMessage: failure.userMessage,
      MessageColumns.errorCode: failure.code ?? failure.runtimeType.toString(),
    });

    generation.dispose();
    _liveTicks.add(conversationId);
  }

  Future<void> _markQueued(
    String conversationId,
    String userMessageId,
    String assistantMessageId,
  ) async {
    await _messageDao.update(conversationId, assistantMessageId, {
      MessageColumns.status: MessageStatus.queued.name,
    });
    _logger.i(
      'Send queued for later',
      fields: {'conversation': conversationId, 'message': userMessageId},
    );
  }

  // ---------------------------------------------------------------- outbox

  @override
  Future<Result<int>> flushOutbox() async {
    // Collapse concurrent flushes: reconnect, timer and app-resume can all fire
    // within the same second, and three passes would send duplicates.
    final inFlight = _flushInFlight;
    if (inFlight != null) {
      await inFlight;
      return const Ok(0);
    }

    final completer = Completer<void>();
    _flushInFlight = completer.future;

    try {
      return await Result.guardAsync(() async {
        if (_connectivity.status.isOffline) return 0;

        final due = await _outboxDao.findDue();
        if (due.isEmpty) return 0;

        var delivered = 0;
        for (final entry in due) {
          final assistantMessageId = entry.assistantMessageId;
          if (assistantMessageId == null) {
            await _outboxDao.remove(entry.messageId);
            continue;
          }

          // An entry stays in the outbox for the whole time its reply is
          // streaming — it is only removed once the answer lands. So a flush
          // that happens to fire during a generation finds the row still due,
          // and `_runGeneration` opens by cancelling whatever is in flight:
          // the answer the user is watching gets marked cancelled, blanked, and
          // typed out again from the start.
          //
          // The flush is not the trigger to fix. Any of them — reconnect, the
          // periodic sweep, app resume, the Settings button — lands in that
          // window sooner or later, and the row genuinely is still due. What
          // was missing is that "due" and "not already being delivered" are
          // different questions.
          if (_active.containsKey(entry.conversationId)) {
            _logger.d(
              'Skipping outbox entry; already generating',
              fields: {'conversation': entry.conversationId},
            );
            continue;
          }

          final model = await _resolveModel(entry.modelId);
          final decision = await _engineRouter.resolve(model: model);
          if (!decision.canGenerateNow) break;

          try {
            await _runGeneration(
              conversationId: entry.conversationId,
              userMessageId: entry.messageId,
              assistantMessageId: assistantMessageId,
              decision: decision,
            );
            delivered++;
          } catch (error) {
            final abandoned = await _outboxDao.recordFailure(
              messageId: entry.messageId,
              error: error.toString(),
            );
            if (abandoned) {
              await _messageDao.markFailed(
                conversationId: entry.conversationId,
                messageId: assistantMessageId,
                errorMessage:
                    'This message could not be delivered after several '
                    'attempts.',
              );
            }
            // Stop the pass on the first failure: if one send failed the network
            // is probably still bad, and hammering it wastes battery.
            break;
          }
        }

        if (delivered > 0) {
          _logger.i('Outbox flushed', fields: {'delivered': delivered});
        }
        return delivered;
      });
    } finally {
      completer.complete();
      _flushInFlight = null;
    }
  }

  // ---------------------------------------------------------------- search

  @override
  Future<Result<List<MessageSearchHit>>> search(
    String query, {
    int limit = 20,
  }) => Result.guardAsync(() => _search.search(query, limit: limit));

  /// Embeds completed messages that predate the index.
  Future<int> backfillEmbeddings({int limit = 100}) =>
      _search.backfill(limit: limit);

  // ---------------------------------------------------------------- helpers

  static const String _systemPrompt =
      'You are EVDEkimi Assistant, a concise and practical helper. Use Markdown '
      'for structure and fenced code blocks with a language tag for code.';

  /// Recent turns, trimmed to fit the context window.
  ///
  /// Uses a 4-characters-per-token approximation rather than a real tokeniser:
  /// bundling one would add megabytes for a heuristic whose only job is deciding
  /// where to cut history, and the cut is conservative.
  Future<List<PromptTurn>> _buildPromptHistory(
    String conversationId, {
    required String excludeMessageId,
    required int contextWindow,
  }) async {
    final messages = await _messageDao.findByConversation(conversationId);
    final usable = messages
        .where(
          (message) =>
              message.id != excludeMessageId &&
              message.hasContent &&
              message.status != MessageStatus.failed,
        )
        .toList(growable: false);

    // Reserve roughly a third of the window for the answer.
    final characterBudget = (contextWindow * 4 * 2) ~/ 3;
    final turns = <PromptTurn>[];
    var used = 0;

    for (final message in usable.reversed) {
      final turn = message.toPromptTurn();
      final cost = turn.content.length;
      if (used + cost > characterBudget && turns.isNotEmpty) break;
      turns.add(turn);
      used += cost;
    }

    return turns.reversed.toList(growable: false);
  }

  /// Uploads attachments that have not reached the server yet.
  ///
  /// Failures are swallowed on purpose: OCR text has already been extracted
  /// on-device, so a message with an unreachable image still carries its
  /// content. The upload is retried the next time the message is touched.
  Future<List<String>> _uploadPendingAttachments({
    required String conversationId,
    required String messageId,
    required bool supportsVision,
  }) async {
    if (messageId.isEmpty || !supportsVision) return const [];
    if (_connectivity.status.isOffline) return const [];

    final message = await _messageDao.findById(messageId);
    if (message == null || !message.hasAttachments) return const [];

    final urls = <String>[];
    for (final attachment in message.attachments) {
      if (attachment.remoteUrl != null) {
        urls.add(attachment.remoteUrl!);
        continue;
      }
      final path = attachment.localPath;
      if (path == null || attachment.kind != AttachmentKind.image) continue;

      try {
        final file = File(path);
        if (!file.existsSync()) continue;

        await _messageDao.updateAttachment(conversationId, attachment.id, {
          AttachmentColumns.uploadState: UploadState.uploading.name,
        });

        final response = await _apiClient.uploadBytes(
          ApiRoutes.uploads,
          bytes: await file.readAsBytes(),
          filename: path.split(Platform.pathSeparator).last,
          field: 'file',
          contentType: attachment.mimeType,
        );

        final url = (response['url'] ?? response['remote_url']) as String?;
        if (url != null) {
          urls.add(url);
          await _messageDao.updateAttachment(conversationId, attachment.id, {
            AttachmentColumns.remoteUrl: url,
            AttachmentColumns.uploadState: UploadState.uploaded.name,
          });
        }
      } catch (error) {
        _logger.w('Attachment upload failed', fields: {'error': '$error'});
        await _messageDao.updateAttachment(conversationId, attachment.id, {
          AttachmentColumns.uploadState: UploadState.failed.name,
        });
      }
    }
    return urls;
  }

  /// Resolves a model id against the cached catalog.
  ///
  /// Falls back to a synthetic remote descriptor rather than failing: a model id
  /// the catalog has not heard of (server added one, cache is stale) should still
  /// be usable.
  Future<ModelDescriptor> _resolveModel(String modelId) async {
    if (modelId == KnownModels.onDeviceRouter) {
      return KnownModels.onDevice.copyWith(
        isInstalled: await _embedder.isAvailable(),
      );
    }
    final catalog = await _conversationDao.findModels();
    for (final model in catalog) {
      if (model.id == modelId) return model;
    }
    return ModelDescriptor(
      id: modelId.isEmpty ? 'gpt-4o-mini' : modelId,
      name: modelId.isEmpty ? 'Default model' : modelId,
      provider: 'remote',
      engine: EngineKind.remote,
      contextWindow: _config.messagePageSize * 100,
    );
  }

  /// Demotes messages left mid-flight by a crash so they can be retried.
  Future<void> recoverInterruptedMessages() async {
    final interrupted = await _messageDao.findInterrupted();
    for (final message in interrupted) {
      await _messageDao.update(message.conversationId, message.id, {
        MessageColumns.status: message.hasContent
            ? MessageStatus.cancelled.name
            : MessageStatus.failed.name,
        MessageColumns.errorMessage: message.hasContent
            ? null
            : 'Interrupted when the app closed. Tap to retry.',
      });
    }
    if (interrupted.isNotEmpty) {
      _logger.i(
        'Recovered interrupted messages',
        fields: {'count': interrupted.length},
      );
    }
  }

  Future<void> dispose() async {
    for (final generation in _active.values) {
      await generation.subscription?.cancel();
      generation.dispose();
    }
    _active.clear();
    await _liveTicks.close();
  }
}

/// Mutable state for one in-flight generation.
///
/// This owns the *whole* lifecycle — subscription, persistence timer and
/// completion signal — because a generation has three exits, not two: it can
/// finish, it can fail, or it can be cancelled. Cancellation fires neither
/// `onDone` nor `onError`, so anything wired only to those two silently never
/// runs. Keeping all three in [finish] makes it impossible to add an exit path
/// that forgets one of them.
class _ActiveGeneration {
  _ActiveGeneration({
    required this.assistantMessageId,
    required this.startedAt,
  });

  final String assistantMessageId;
  final DateTime startedAt;

  /// Live token buffer. The UI reads this; SQLite lags behind it.
  final StringBuffer buffer = StringBuffer();

  /// The live generation subscription.
  ///
  /// Held as a field rather than scoped to the function that created it, because
  /// the stop button needs to reach it. Cancelled by `stopGeneration` and by
  /// `ChatRepositoryImpl.dispose`.
  // ignore: cancel_subscriptions
  StreamSubscription<InferenceEvent>? subscription;

  /// Throttled writer of streamed content to SQLite.
  Timer? persistTimer;

  final Completer<void> _completed = Completer<void>();

  /// Resolves once the generation has reached a terminal state by any route.
  Future<void> get completion => _completed.future;

  /// Set when the stream errored, so the caller can rethrow after awaiting.
  ///
  /// `flushOutbox` needs the failure to apply backoff, but the error arrives on
  /// a stream callback rather than as a thrown exception, so it is parked here.
  Object? failure;
  StackTrace? failureStackTrace;

  String? statusMessage;
  int? outputTokens;
  Duration? latency;

  /// How the engine says the run ended. `deferred` means it produced text but
  /// not an answer, which is the difference between delivered and still owed.
  FinishReason finishReason = FinishReason.stop;

  /// Why this engine was chosen. A deferral is only recoverable if a *different*
  /// engine might take the message later, which is exactly what this says.
  RoutingReason routingReason = RoutingReason.explicitChoice;
  int persistedLength = 0;

  /// True once a terminal write has happened. The throttled persist checks this
  /// so a timer callback already in flight cannot land *after* the final write
  /// and resurrect a completed message as `streaming`.
  bool isFinalised = false;

  bool get hasContent => buffer.isNotEmpty;

  /// The single exit point. Idempotent, so racing callers are harmless.
  void finish({Object? error, StackTrace? stackTrace}) {
    persistTimer?.cancel();
    persistTimer = null;
    isFinalised = true;
    if (error != null && failure == null) {
      failure = error;
      failureStackTrace = stackTrace;
    }
    if (!_completed.isCompleted) _completed.complete();
  }

  void dispose() {
    finish();
    subscription = null;
    buffer.clear();
  }
}
