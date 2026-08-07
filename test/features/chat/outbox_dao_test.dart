import 'dart:math';
import 'dart:typed_data';

import 'package:evdekimi_ai/core/logging/app_logger.dart';
import 'package:evdekimi_ai/core/persistence/app_database.dart';
import 'package:evdekimi_ai/core/persistence/database_schema.dart';
import 'package:evdekimi_ai/features/ai/domain/model_descriptor.dart';
import 'package:evdekimi_ai/features/chat/data/local/conversation_dao.dart';
import 'package:evdekimi_ai/features/chat/data/local/message_dao.dart';
import 'package:evdekimi_ai/features/chat/data/local/outbox_dao.dart';
import 'package:evdekimi_ai/features/chat/domain/entities/conversation.dart';
import 'package:evdekimi_ai/features/chat/domain/entities/message.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Real-SQLite tests for the persistence layer.
///
/// These run against sqflite's FFI implementation on an in-memory database, so
/// they exercise the actual SQL, the real migrations, and the foreign-key
/// cascades — not a mock that would happily accept invalid statements.
void main() {
  setUpAll(sqfliteFfiInit);

  late AppDatabase database;
  late ConversationDao conversationDao;
  late MessageDao messageDao;
  late OutboxDao outboxDao;

  setUp(() async {
    database = AppDatabase(
      logger: AppLogger.silent(),
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    conversationDao = ConversationDao(database);
    messageDao = MessageDao(database);
    outboxDao = OutboxDao(database);
  });

  tearDown(() => database.close());

  Future<Conversation> seedConversation() async {
    final conversation = Conversation.draft(
      id: 'conv-1',
      modelId: 'gpt-4o-mini',
      engine: EngineKind.remote,
      now: DateTime.utc(2026, 8, 7, 10),
    );
    await conversationDao.insert(conversation);
    return conversation;
  }

  Future<Message> seedMessage({
    String id = 'msg-1',
    int sequence = 0,
    MessageStatus status = MessageStatus.queued,
  }) async {
    final message = Message(
      id: id,
      conversationId: 'conv-1',
      role: MessageRole.user,
      content: 'Hello there',
      status: status,
      sequence: sequence,
      createdAt: DateTime.utc(2026, 8, 7, 10),
      updatedAt: DateTime.utc(2026, 8, 7, 10),
    );
    await messageDao.insert(message);
    return message;
  }

  group('schema and migrations', () {
    test('creates every declared table', () async {
      final db = await database.database;
      final rows = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table'",
      );
      final tables = rows.map((row) => row['name']).toSet();

      for (final expected in DatabaseSchema.tableNames) {
        expect(tables, contains(expected));
      }
    });

    test('enables foreign keys so cascades actually fire', () async {
      // Off by default in SQLite; without the pragma, ON DELETE CASCADE is
      // silently ignored and deleting a conversation orphans its messages.
      final db = await database.database;
      final result = await db.rawQuery('PRAGMA foreign_keys');
      expect(result.first.values.first, equals(1));
    });

    test(
      'cascades message deletion when a conversation is hard-deleted',
      () async {
        await seedConversation();
        await seedMessage();

        final db = await database.database;
        await db.delete(
          ConversationColumns.table,
          where: 'id = ?',
          whereArgs: ['conv-1'],
        );

        final remaining = await messageDao.findByConversation('conv-1');
        expect(remaining, isEmpty);
      },
    );
  });

  group('MessageDao.nextSequence', () {
    test('starts at zero for an empty conversation', () async {
      await seedConversation();
      final db = await database.database;
      expect(await messageDao.nextSequence(db, 'conv-1'), equals(0));
    });

    test('increments past the highest existing sequence', () async {
      await seedConversation();
      await seedMessage(id: 'a', sequence: 0);
      await seedMessage(id: 'b', sequence: 1);

      final db = await database.database;
      expect(await messageDao.nextSequence(db, 'conv-1'), equals(2));
    });

    test('keeps sequences unique when two messages claim the same slot', () async {
      // The unique index on (conversation_id, sequence) is what guarantees a
      // total order for messages created in the same millisecond.
      //
      // `insert` uses ConflictAlgorithm.replace, chosen so re-inserting the same
      // message id is idempotent (the outbox and the streaming path both do it).
      // The consequence asserted here is that a *different* id claiming a taken
      // sequence supersedes the earlier row rather than erroring. In practice
      // that collision cannot happen: `nextSequence` is read inside the same
      // transaction as the insert, so the slot is reserved atomically.
      await seedConversation();
      await seedMessage(id: 'a', sequence: 0);
      await seedMessage(id: 'b', sequence: 0);

      final messages = await messageDao.findByConversation('conv-1');
      expect(messages, hasLength(1), reason: 'never two rows at one sequence');
      expect(messages.single.id, equals('b'));
    });

    test('re-inserting the same message id is idempotent', () async {
      await seedConversation();
      await seedMessage(id: 'a', sequence: 0);
      await seedMessage(id: 'a', sequence: 0);

      expect(await messageDao.findByConversation('conv-1'), hasLength(1));
    });
  });

  group('OutboxDao', () {
    test('enqueues an entry that is immediately due', () async {
      await seedConversation();
      await seedMessage();

      await outboxDao.enqueue(
        messageId: 'msg-1',
        conversationId: 'conv-1',
        idempotencyKey: 'msg_msg-1',
        payload: const {
          'content': 'Hello there',
          'model_id': 'gpt-4o-mini',
          'assistant_message_id': 'assistant-1',
        },
      );

      final due = await outboxDao.findDue();
      expect(due, hasLength(1));
      expect(due.single.messageId, equals('msg-1'));
      expect(due.single.assistantMessageId, equals('assistant-1'));
      expect(due.single.content, equals('Hello there'));
      expect(await outboxDao.count(), equals(1));
    });

    test(
      'enqueueing the same message twice does not duplicate the send',
      () async {
        // outbox.id == message.id, so a double enqueue is a primary-key conflict
        // rather than two deliveries.
        await seedConversation();
        await seedMessage();

        for (var i = 0; i < 3; i++) {
          await outboxDao.enqueue(
            messageId: 'msg-1',
            conversationId: 'conv-1',
            idempotencyKey: 'msg_msg-1',
            payload: const {'content': 'Hello there'},
          );
        }

        expect(await outboxDao.count(), equals(1));
      },
    );

    test('backs off after a failure so the entry is no longer due', () async {
      await seedConversation();
      await seedMessage();
      await outboxDao.enqueue(
        messageId: 'msg-1',
        conversationId: 'conv-1',
        idempotencyKey: 'k',
        payload: const {'content': 'x'},
      );

      final abandoned = await outboxDao.recordFailure(
        messageId: 'msg-1',
        error: 'connection refused',
        random: Random(1),
      );

      expect(abandoned, isFalse);
      expect(
        await outboxDao.findDue(),
        isEmpty,
        reason: 'should be backed off',
      );
      // Still queued — just not yet.
      expect(await outboxDao.count(), equals(1));
    });

    test('becomes due again once the backoff window elapses', () async {
      await seedConversation();
      await seedMessage();
      await outboxDao.enqueue(
        messageId: 'msg-1',
        conversationId: 'conv-1',
        idempotencyKey: 'k',
        payload: const {'content': 'x'},
      );
      await outboxDao.recordFailure(
        messageId: 'msg-1',
        error: 'boom',
        random: Random(1),
      );

      final later = DateTime.now().toUtc().add(const Duration(minutes: 1));
      expect(await outboxDao.findDue(now: later), hasLength(1));
    });

    test('abandons an entry after the attempt limit', () async {
      await seedConversation();
      await seedMessage();
      await outboxDao.enqueue(
        messageId: 'msg-1',
        conversationId: 'conv-1',
        idempotencyKey: 'k',
        payload: const {'content': 'x'},
      );

      var abandoned = false;
      for (var i = 0; i < OutboxDao.maxAttempts; i++) {
        abandoned = await outboxDao.recordFailure(
          messageId: 'msg-1',
          error: 'boom',
          random: Random(i),
        );
      }

      expect(abandoned, isTrue, reason: 'must stop retrying eventually');
      expect(await outboxDao.count(), equals(0));
    });

    test('markDueNow resets the backoff for a user-initiated retry', () async {
      await seedConversation();
      await seedMessage();
      await outboxDao.enqueue(
        messageId: 'msg-1',
        conversationId: 'conv-1',
        idempotencyKey: 'k',
        payload: const {'content': 'x'},
      );
      await outboxDao.recordFailure(
        messageId: 'msg-1',
        error: 'boom',
        random: Random(1),
      );
      expect(await outboxDao.findDue(), isEmpty);

      await outboxDao.markDueNow('msg-1');
      expect(await outboxDao.findDue(), hasLength(1));
    });

    test('removes the entry once delivered', () async {
      await seedConversation();
      await seedMessage();
      await outboxDao.enqueue(
        messageId: 'msg-1',
        conversationId: 'conv-1',
        idempotencyKey: 'k',
        payload: const {'content': 'x'},
      );

      await outboxDao.remove('msg-1');
      expect(await outboxDao.count(), equals(0));
    });

    test('recordFailure on a missing entry reports it as abandoned', () async {
      expect(
        await outboxDao.recordFailure(messageId: 'nope', error: 'x'),
        isTrue,
      );
    });
  });

  group('ConversationDao', () {
    test('hides soft-deleted conversations from the list', () async {
      await seedConversation();
      await conversationDao.softDelete('conv-1', DateTime.now().toUtc());

      expect(await conversationDao.findAll(), isEmpty);
      // The row survives so a future sync can propagate the deletion.
      expect(await conversationDao.findById('conv-1'), isNotNull);
    });

    test('orders pinned conversations first, then by recency', () async {
      await conversationDao.insert(
        Conversation.draft(
          id: 'old',
          modelId: 'm',
          engine: EngineKind.remote,
          now: DateTime.utc(2026, 1, 1),
        ),
      );
      await conversationDao.insert(
        Conversation.draft(
          id: 'new',
          modelId: 'm',
          engine: EngineKind.remote,
          now: DateTime.utc(2026, 8, 1),
        ),
      );
      await conversationDao.insert(
        Conversation.draft(
          id: 'pinned',
          modelId: 'm',
          engine: EngineKind.remote,
          now: DateTime.utc(2025, 1, 1),
        ).copyWith(isPinned: true),
      );

      final all = await conversationDao.findAll();
      expect(all.first.id, equals('pinned'));
      expect(all[1].id, equals('new'));
      expect(all[2].id, equals('old'));
    });

    test('refreshSummary denormalises count and preview', () async {
      await seedConversation();
      await seedMessage(id: 'a', sequence: 0);
      await seedMessage(id: 'b', sequence: 1);

      await conversationDao.refreshSummary('conv-1');

      final conversation = await conversationDao.findById('conv-1');
      expect(conversation!.messageCount, equals(2));
      expect(conversation.lastMessagePreview, equals('Hello there'));
    });

    test('excludes archived conversations unless asked for', () async {
      await seedConversation();
      await conversationDao.update('conv-1', {
        ConversationColumns.isArchived: 1,
      });

      expect(await conversationDao.findAll(), isEmpty);
      expect(
        await conversationDao.findAll(includeArchived: true),
        hasLength(1),
      );
    });

    test('replaceModels swaps the cached catalog wholesale', () async {
      await conversationDao.replaceModels(const [
        ModelDescriptor(
          id: 'a',
          name: 'A',
          provider: 'p',
          engine: EngineKind.remote,
        ),
      ]);
      expect(await conversationDao.findModels(), hasLength(1));

      // A model removed upstream must disappear from the picker too.
      await conversationDao.replaceModels(const [
        ModelDescriptor(
          id: 'b',
          name: 'B',
          provider: 'p',
          engine: EngineKind.remote,
        ),
      ]);
      final models = await conversationDao.findModels();
      expect(models, hasLength(1));
      expect(models.single.id, equals('b'));
    });
  });

  group('MessageDao recovery and embeddings', () {
    test('finds messages left mid-flight by a crash', () async {
      await seedConversation();
      await seedMessage(
        id: 'sending',
        sequence: 0,
        status: MessageStatus.sending,
      );
      await seedMessage(
        id: 'streaming',
        sequence: 1,
        status: MessageStatus.streaming,
      );
      await seedMessage(
        id: 'done',
        sequence: 2,
        status: MessageStatus.complete,
      );

      final interrupted = await messageDao.findInterrupted();
      expect(
        interrupted.map((message) => message.id).toSet(),
        equals({'sending', 'streaming'}),
      );
    });

    test('round-trips an embedding through the BLOB column', () async {
      await seedConversation();
      await seedMessage();

      final vector = Float32List.fromList([0.5, -0.25, 1.0, 0.0]);
      await messageDao.saveEmbedding(
        messageId: 'msg-1',
        modelId: KnownModels.onDeviceRouter,
        vector: vector,
      );

      final records = await messageDao.findAllEmbeddings();
      expect(records, hasLength(1));
      expect(records.single.messageId, equals('msg-1'));
      // Little-endian float32 encoding must survive the round trip exactly.
      expect(records.single.vector, equals(vector));
    });

    test('lists completed messages that still need embedding', () async {
      await seedConversation();
      await seedMessage(id: 'a', sequence: 0, status: MessageStatus.complete);
      await seedMessage(id: 'b', sequence: 1, status: MessageStatus.queued);

      final pending = await messageDao.findMessagesMissingEmbeddings();
      // Only complete messages are indexed; a queued one may still change.
      expect(pending, equals(['a']));
    });
  });
}
