import 'package:evdekimi_ai/core/persistence/app_database.dart';
import 'package:evdekimi_ai/core/persistence/database_schema.dart';
import 'package:evdekimi_ai/features/ai/domain/model_descriptor.dart';
import 'package:evdekimi_ai/features/chat/data/local/chat_mappers.dart';
import 'package:evdekimi_ai/features/chat/domain/entities/conversation.dart';
import 'package:sqflite/sqflite.dart';

/// SQL for the `conversations` and `model_catalog` tables.
class ConversationDao {
  ConversationDao(this._db);

  final AppDatabase _db;

  /// Conversation list ordered pinned-first, then by recency.
  ///
  /// `deleted_at IS NULL` filters tombstones. The ORDER BY matches
  /// `idx_conversations_activity` so this stays an index scan as history grows.
  Future<List<Conversation>> findAll({bool includeArchived = false}) async {
    final db = await _db.database;
    final rows = await db.query(
      ConversationColumns.table,
      where: [
        '${ConversationColumns.deletedAt} IS NULL',
        if (!includeArchived) '${ConversationColumns.isArchived} = 0',
      ].join(' AND '),
      orderBy:
          '${ConversationColumns.isPinned} DESC, '
          '${ConversationColumns.updatedAt} DESC',
    );
    return rows.map(ChatMappers.conversationFromRow).toList(growable: false);
  }

  Future<Conversation?> findById(String id) async {
    final db = await _db.database;
    final rows = await db.query(
      ConversationColumns.table,
      where: '${ConversationColumns.id} = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return ChatMappers.conversationFromRow(rows.first);
  }

  Future<void> insert(Conversation conversation) => _db.write(
    (txn) => txn.insert(
      ConversationColumns.table,
      ChatMappers.conversationToRow(conversation),
      conflictAlgorithm: ConflictAlgorithm.replace,
    ),
    topics: {DatabaseChangeNotifier.conversations},
  );

  /// Applies a partial update and always bumps `updated_at`.
  ///
  /// Centralised so no caller can change a conversation without moving it up
  /// the list — a stale ordering is the kind of bug that is invisible in tests
  /// and obvious to a user.
  Future<void> update(
    String id,
    Map<String, Object?> values, {
    DateTime? now,
  }) => _db.write((txn) async {
    await txn.update(
      ConversationColumns.table,
      {
        ...values,
        ConversationColumns.updatedAt:
            (now ?? DateTime.now().toUtc()).millisecondsSinceEpoch,
      },
      where: '${ConversationColumns.id} = ?',
      whereArgs: [id],
    );
  }, topics: {DatabaseChangeNotifier.conversations});

  /// Refreshes the denormalised preview and count from the messages table.
  ///
  /// Denormalising costs this extra write but turns the conversation list into a
  /// single indexed query instead of a correlated subquery per row.
  Future<void> refreshSummary(
    String conversationId, {
    Transaction? txn,
    DateTime? now,
  }) async {
    Future<void> run(DatabaseExecutor executor) async {
      final rows = await executor.rawQuery(
        '''
        SELECT COUNT(*) AS total,
               (SELECT ${MessageColumns.content}
                  FROM ${MessageColumns.table}
                 WHERE ${MessageColumns.conversationId} = ?
                   AND ${MessageColumns.content} <> ''
                 ORDER BY ${MessageColumns.sequence} DESC
                 LIMIT 1) AS preview
          FROM ${MessageColumns.table}
         WHERE ${MessageColumns.conversationId} = ?
        ''',
        [conversationId, conversationId],
      );

      final row = rows.isEmpty ? const <String, Object?>{} : rows.first;
      final total = (row['total'] as num?)?.toInt() ?? 0;
      final preview = row['preview'] as String?;

      await executor.update(
        ConversationColumns.table,
        {
          ConversationColumns.messageCount: total,
          ConversationColumns.lastMessagePreview: _clipPreview(preview),
          ConversationColumns.updatedAt:
              (now ?? DateTime.now().toUtc()).millisecondsSinceEpoch,
        },
        where: '${ConversationColumns.id} = ?',
        whereArgs: [conversationId],
      );
    }

    // When called inside an existing transaction, join it rather than opening a
    // nested one — sqflite deadlocks on nested transactions.
    if (txn != null) {
      await run(txn);
      return;
    }
    await _db.write(run, topics: {DatabaseChangeNotifier.conversations});
  }

  /// Tombstones a conversation. Messages cascade only on a hard delete, so the
  /// transcript stays readable if the deletion is later undone.
  Future<void> softDelete(String id, DateTime now) => _db.write(
    (txn) => txn.update(
      ConversationColumns.table,
      {
        ConversationColumns.deletedAt: now.toUtc().millisecondsSinceEpoch,
        ConversationColumns.updatedAt: now.toUtc().millisecondsSinceEpoch,
        ConversationColumns.syncState: SyncState.dirty.name,
      },
      where: '${ConversationColumns.id} = ?',
      whereArgs: [id],
    ),
    topics: {DatabaseChangeNotifier.conversations},
  );

  /// Permanently removes tombstoned rows older than [olderThan].
  Future<int> purgeTombstones(Duration olderThan) async {
    final cutoff = DateTime.now()
        .toUtc()
        .subtract(olderThan)
        .millisecondsSinceEpoch;
    return _db.write(
      (txn) => txn.delete(
        ConversationColumns.table,
        where:
            '${ConversationColumns.deletedAt} IS NOT NULL '
            'AND ${ConversationColumns.deletedAt} < ?',
        whereArgs: [cutoff],
      ),
      topics: {DatabaseChangeNotifier.conversations},
    );
  }

  // --- Model catalog ----------------------------------------------------

  Future<List<ModelDescriptor>> findModels() async {
    final db = await _db.database;
    final rows = await db.query(
      ModelCatalogColumns.table,
      orderBy:
          '${ModelCatalogColumns.isDefault} DESC, ${ModelCatalogColumns.name} ASC',
    );
    return rows.map(ChatMappers.modelFromRow).toList(growable: false);
  }

  /// Replaces the cached catalog in one transaction.
  ///
  /// Replace-all rather than upsert: the server list is authoritative, and a
  /// model that disappears upstream must disappear from the picker too.
  Future<void> replaceModels(List<ModelDescriptor> models) =>
      _db.write((txn) async {
        final now = DateTime.now().toUtc();
        await txn.delete(ModelCatalogColumns.table);
        for (final model in models) {
          await txn.insert(
            ModelCatalogColumns.table,
            ChatMappers.modelToRow(model, now),
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
      }, topics: {DatabaseChangeNotifier.modelCatalog});

  static const int _previewLength = 140;

  static String? _clipPreview(String? preview) {
    if (preview == null) return null;
    final normalised = preview.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalised.length <= _previewLength) return normalised;
    return '${normalised.substring(0, _previewLength)}…';
  }
}
