import 'dart:typed_data';

import 'package:evdekimi_ai/core/persistence/app_database.dart';
import 'package:evdekimi_ai/core/persistence/database_schema.dart';
import 'package:evdekimi_ai/features/chat/data/local/chat_mappers.dart';
import 'package:evdekimi_ai/features/chat/domain/entities/message.dart';
import 'package:sqflite/sqflite.dart';

/// SQL for `messages`, `attachments` and `message_embeddings`.
class MessageDao {
  MessageDao(this._db);

  final AppDatabase _db;

  /// Loads a conversation's messages with their attachments.
  ///
  /// Attachments are fetched in one extra query and grouped in memory, rather
  /// than per message (N+1) or via a JOIN that would duplicate message rows and
  /// need de-duplicating anyway.
  Future<List<Message>> findByConversation(
    String conversationId, {
    int? limit,
  }) async {
    final db = await _db.database;

    final messageRows = await db.query(
      MessageColumns.table,
      where: '${MessageColumns.conversationId} = ?',
      whereArgs: [conversationId],
      orderBy: '${MessageColumns.sequence} ASC',
      limit: limit,
    );
    if (messageRows.isEmpty) return const [];

    final ids = messageRows
        .map((row) => row[MessageColumns.id]! as String)
        .toList(growable: false);
    final attachmentsByMessage = await _findAttachments(db, ids);

    return messageRows
        .map(
          (row) => ChatMappers.messageFromRow(
            row,
            attachments:
                attachmentsByMessage[row[MessageColumns.id]] ?? const [],
          ),
        )
        .toList(growable: false);
  }

  Future<Message?> findById(String id) async {
    final db = await _db.database;
    final rows = await db.query(
      MessageColumns.table,
      where: '${MessageColumns.id} = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final attachments = await _findAttachments(db, [id]);
    return ChatMappers.messageFromRow(
      rows.first,
      attachments: attachments[id] ?? const [],
    );
  }

  Future<Map<String, List<Attachment>>> _findAttachments(
    DatabaseExecutor db,
    List<String> messageIds,
  ) async {
    if (messageIds.isEmpty) return const {};
    // Parameterised IN list: never string-interpolate ids into SQL.
    final placeholders = List.filled(messageIds.length, '?').join(',');
    final rows = await db.query(
      AttachmentColumns.table,
      where: '${AttachmentColumns.messageId} IN ($placeholders)',
      whereArgs: messageIds,
      orderBy: '${AttachmentColumns.createdAt} ASC',
    );

    final grouped = <String, List<Attachment>>{};
    for (final row in rows) {
      final attachment = ChatMappers.attachmentFromRow(row);
      grouped.putIfAbsent(attachment.messageId, () => []).add(attachment);
    }
    return grouped;
  }

  /// The next `sequence` value for a conversation.
  ///
  /// Read inside the caller's transaction so two concurrent sends cannot both
  /// claim the same slot — the unique index on `(conversation_id, sequence)`
  /// would otherwise reject one of them.
  Future<int> nextSequence(
    DatabaseExecutor executor,
    String conversationId,
  ) async {
    final rows = await executor.rawQuery(
      'SELECT COALESCE(MAX(${MessageColumns.sequence}), -1) + 1 AS next '
      'FROM ${MessageColumns.table} '
      'WHERE ${MessageColumns.conversationId} = ?',
      [conversationId],
    );
    return (rows.first['next'] as num?)?.toInt() ?? 0;
  }

  Future<void> insert(Message message) => _db.write(
    (txn) => insertWithin(txn, message),
    topics: {DatabaseChangeNotifier.messagesOf(message.conversationId)},
  );

  /// Inserts a message plus its attachments inside an existing transaction.
  Future<void> insertWithin(DatabaseExecutor executor, Message message) async {
    await executor.insert(
      MessageColumns.table,
      ChatMappers.messageToRow(message),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    for (final attachment in message.attachments) {
      await executor.insert(
        AttachmentColumns.table,
        ChatMappers.attachmentToRow(attachment),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
  }

  Future<void> update(
    String conversationId,
    String messageId,
    Map<String, Object?> values, {
    DateTime? now,
  }) => _db.write(
    (txn) => updateWithin(txn, messageId, values, now: now),
    topics: {DatabaseChangeNotifier.messagesOf(conversationId)},
  );

  Future<void> updateWithin(
    DatabaseExecutor executor,
    String messageId,
    Map<String, Object?> values, {
    DateTime? now,
  }) => executor.update(
    MessageColumns.table,
    {
      ...values,
      MessageColumns.updatedAt:
          (now ?? DateTime.now().toUtc()).millisecondsSinceEpoch,
    },
    where: '${MessageColumns.id} = ?',
    whereArgs: [messageId],
  );

  /// Overwrites content and status in one statement.
  ///
  /// Used on the streaming hot path, which is why it is a single narrow UPDATE
  /// rather than a read-modify-write of the whole entity.
  Future<void> writeStreamedContent({
    required String conversationId,
    required String messageId,
    required String content,
    required MessageStatus status,
    int? tokenCount,
    Duration? latency,
  }) => update(conversationId, messageId, {
    MessageColumns.content: content,
    MessageColumns.status: status.name,
    MessageColumns.tokenCount: ?tokenCount,
    MessageColumns.latencyMs: ?latency?.inMilliseconds,
  });

  Future<void> markFailed({
    required String conversationId,
    required String messageId,
    required String errorMessage,
    String? errorCode,
  }) => update(conversationId, messageId, {
    MessageColumns.status: MessageStatus.failed.name,
    MessageColumns.errorMessage: errorMessage,
    MessageColumns.errorCode: errorCode,
  });

  Future<void> delete(String conversationId, String messageId) => _db.write(
    (txn) => txn.delete(
      MessageColumns.table,
      where: '${MessageColumns.id} = ?',
      whereArgs: [messageId],
    ),
    topics: {
      DatabaseChangeNotifier.messagesOf(conversationId),
      DatabaseChangeNotifier.conversations,
    },
  );

  /// Messages left mid-flight by a crash or a force-quit.
  ///
  /// Called once at startup: a `sending`/`streaming` row can never resume, so it
  /// is demoted to `failed` (retryable) instead of spinning forever.
  Future<List<Message>> findInterrupted() async {
    final db = await _db.database;
    final rows = await db.query(
      MessageColumns.table,
      where: '${MessageColumns.status} IN (?, ?)',
      whereArgs: [MessageStatus.sending.name, MessageStatus.streaming.name],
    );
    return rows.map(ChatMappers.messageFromRow).toList(growable: false);
  }

  // --- Attachments ------------------------------------------------------

  Future<void> updateAttachment(
    String conversationId,
    String attachmentId,
    Map<String, Object?> values,
  ) => _db.write(
    (txn) => txn.update(
      AttachmentColumns.table,
      values,
      where: '${AttachmentColumns.id} = ?',
      whereArgs: [attachmentId],
    ),
    topics: {DatabaseChangeNotifier.messagesOf(conversationId)},
  );

  // --- Embeddings -------------------------------------------------------

  /// Stores an on-device embedding as raw little-endian float32 bytes.
  ///
  /// Endianness is pinned explicitly: the default would follow the host, and a
  /// database file restored onto a different architecture would then read
  /// garbage vectors.
  Future<void> saveEmbedding({
    required String messageId,
    required String modelId,
    required Float32List vector,
  }) async {
    final bytes = Uint8List(vector.length * 4);
    final view = ByteData.view(bytes.buffer);
    for (var i = 0; i < vector.length; i++) {
      view.setFloat32(i * 4, vector[i], Endian.little);
    }

    await _db.write(
      (txn) => txn.insert(EmbeddingColumns.table, {
        EmbeddingColumns.messageId: messageId,
        EmbeddingColumns.modelId: modelId,
        EmbeddingColumns.dimensions: vector.length,
        EmbeddingColumns.vector: bytes,
        EmbeddingColumns.createdAt: DateTime.now()
            .toUtc()
            .millisecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.replace),
    );
  }

  /// Every stored embedding, joined to its message and conversation title.
  ///
  /// Loaded wholesale because semantic search scores in Dart: a personal chat
  /// history is thousands of rows, where a linear scan is well under a frame and
  /// far simpler than maintaining a vector index.
  Future<List<EmbeddingRecord>> findAllEmbeddings({int? limit}) async {
    final db = await _db.database;
    final rows = await db.rawQuery('''
      SELECT e.${EmbeddingColumns.messageId}  AS message_id,
             e.${EmbeddingColumns.dimensions} AS dimensions,
             e.${EmbeddingColumns.vector}     AS vector,
             c.${ConversationColumns.title}   AS conversation_title
        FROM ${EmbeddingColumns.table} e
        JOIN ${MessageColumns.table} m
          ON m.${MessageColumns.id} = e.${EmbeddingColumns.messageId}
        JOIN ${ConversationColumns.table} c
          ON c.${ConversationColumns.id} = m.${MessageColumns.conversationId}
       WHERE c.${ConversationColumns.deletedAt} IS NULL
       ORDER BY e.${EmbeddingColumns.createdAt} DESC
       ${limit == null ? '' : 'LIMIT $limit'}
    ''');

    return rows
        .map((row) {
          final blob = row['vector'];
          if (blob is! Uint8List) return null;
          final dimensions = (row['dimensions'] as num?)?.toInt() ?? 0;
          if (dimensions <= 0 || blob.lengthInBytes < dimensions * 4) {
            return null;
          }
          final vector = Float32List(dimensions);
          final view = ByteData.view(
            blob.buffer,
            blob.offsetInBytes,
            blob.lengthInBytes,
          );
          for (var i = 0; i < dimensions; i++) {
            vector[i] = view.getFloat32(i * 4, Endian.little);
          }
          return EmbeddingRecord(
            messageId: row['message_id']! as String,
            conversationTitle: (row['conversation_title'] as String?) ?? '',
            vector: vector,
          );
        })
        .whereType<EmbeddingRecord>()
        .toList(growable: false);
  }

  /// Ids of messages that have text but no embedding yet.
  Future<List<String>> findMessagesMissingEmbeddings({int limit = 200}) async {
    final db = await _db.database;
    final rows = await db.rawQuery(
      '''
      SELECT m.${MessageColumns.id} AS id
        FROM ${MessageColumns.table} m
        LEFT JOIN ${EmbeddingColumns.table} e
          ON e.${EmbeddingColumns.messageId} = m.${MessageColumns.id}
       WHERE e.${EmbeddingColumns.messageId} IS NULL
         AND m.${MessageColumns.content} <> ''
         AND m.${MessageColumns.status} = ?
       ORDER BY m.${MessageColumns.createdAt} DESC
       LIMIT ?
      ''',
      [MessageStatus.complete.name, limit],
    );
    return rows.map((row) => row['id']! as String).toList(growable: false);
  }
}

/// An embedding plus the context needed to render a search hit.
class EmbeddingRecord {
  const EmbeddingRecord({
    required this.messageId,
    required this.conversationTitle,
    required this.vector,
  });

  final String messageId;
  final String conversationTitle;
  final Float32List vector;
}
