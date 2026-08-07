import 'dart:convert';
import 'dart:math';

import 'package:evdekimi_ai/core/persistence/app_database.dart';
import 'package:evdekimi_ai/core/persistence/database_schema.dart';
import 'package:sqflite/sqflite.dart';

/// The durable send queue.
///
/// Why a table and not an in-memory list: the queue has to survive the process.
/// A user types on the train, the OS reclaims the app, and the message must still
/// go out on reconnect. Since `outbox.id` *is* the message id, enqueueing the
/// same message twice is a primary-key conflict rather than a duplicate send, and
/// the `idempotency_key` travels to the server so a retry after a lost response
/// cannot create two messages.
class OutboxDao {
  OutboxDao(this._db);

  final AppDatabase _db;

  /// Backoff schedule for failed deliveries, indexed by attempt count.
  ///
  /// Deliberately coarse and capped: a queued chat message is not urgent enough
  /// to justify aggressive polling, and the outbox is also flushed immediately on
  /// reconnect, which is what actually recovers the common case.
  static const List<Duration> _backoff = [
    Duration(seconds: 5),
    Duration(seconds: 20),
    Duration(minutes: 1),
    Duration(minutes: 5),
    Duration(minutes: 15),
  ];

  /// Attempts after which an entry is abandoned and its message marked failed.
  static const int maxAttempts = 8;

  Future<void> enqueue({
    required String messageId,
    required String conversationId,
    required String idempotencyKey,
    required Map<String, Object?> payload,
    DateTime? now,
    Transaction? txn,
  }) async {
    final timestamp = (now ?? DateTime.now().toUtc()).millisecondsSinceEpoch;
    final values = <String, Object?>{
      OutboxColumns.id: messageId,
      OutboxColumns.conversationId: conversationId,
      OutboxColumns.idempotencyKey: idempotencyKey,
      OutboxColumns.payload: jsonEncode(payload),
      OutboxColumns.attempts: 0,
      // Due immediately; the processor decides whether the network is usable.
      OutboxColumns.nextAttemptAt: timestamp,
      OutboxColumns.createdAt: timestamp,
    };

    if (txn != null) {
      await txn.insert(
        OutboxColumns.table,
        values,
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      return;
    }

    await _db.write(
      (transaction) => transaction.insert(
        OutboxColumns.table,
        values,
        conflictAlgorithm: ConflictAlgorithm.ignore,
      ),
      topics: {DatabaseChangeNotifier.outbox},
    );
  }

  /// Entries whose backoff has elapsed, oldest first.
  Future<List<OutboxEntry>> findDue({int limit = 10, DateTime? now}) async {
    final db = await _db.database;
    final rows = await db.query(
      OutboxColumns.table,
      where: '${OutboxColumns.nextAttemptAt} <= ?',
      whereArgs: [(now ?? DateTime.now().toUtc()).millisecondsSinceEpoch],
      orderBy: '${OutboxColumns.createdAt} ASC',
      limit: limit,
    );
    return rows.map(OutboxEntry.fromRow).toList(growable: false);
  }

  Future<int> count() async {
    final db = await _db.database;
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS total FROM ${OutboxColumns.table}',
    );
    return (rows.first['total'] as num?)?.toInt() ?? 0;
  }

  /// Removes a delivered entry.
  Future<void> remove(String messageId) => _db.write(
    (txn) => txn.delete(
      OutboxColumns.table,
      where: '${OutboxColumns.id} = ?',
      whereArgs: [messageId],
    ),
    topics: {DatabaseChangeNotifier.outbox},
  );

  /// Records a failed attempt and schedules the next one.
  ///
  /// Returns `true` when the entry has been abandoned, so the caller can mark the
  /// message failed and surface it to the user rather than retrying forever.
  Future<bool> recordFailure({
    required String messageId,
    required String error,
    DateTime? now,
    Random? random,
  }) async {
    final db = await _db.database;
    final rows = await db.query(
      OutboxColumns.table,
      columns: [OutboxColumns.attempts],
      where: '${OutboxColumns.id} = ?',
      whereArgs: [messageId],
      limit: 1,
    );
    if (rows.isEmpty) return true;

    final attempts =
        ((rows.first[OutboxColumns.attempts] as num?)?.toInt() ?? 0) + 1;

    if (attempts >= maxAttempts) {
      await remove(messageId);
      return true;
    }

    final base = _backoff[min(attempts - 1, _backoff.length - 1)];
    // ±20% jitter so a batch queued during an outage does not retry in lockstep.
    final jitterRange = base.inMilliseconds ~/ 5;
    final jitter = jitterRange == 0
        ? 0
        : (random ?? Random()).nextInt(jitterRange * 2) - jitterRange;
    final nextAttempt = (now ?? DateTime.now().toUtc()).add(
      Duration(milliseconds: base.inMilliseconds + jitter),
    );

    await _db.write(
      (txn) => txn.update(
        OutboxColumns.table,
        {
          OutboxColumns.attempts: attempts,
          OutboxColumns.lastError: error,
          OutboxColumns.nextAttemptAt: nextAttempt.millisecondsSinceEpoch,
        },
        where: '${OutboxColumns.id} = ?',
        whereArgs: [messageId],
      ),
      topics: {DatabaseChangeNotifier.outbox},
    );
    return false;
  }

  /// Makes an entry due immediately, for an explicit user-initiated retry.
  Future<void> markDueNow(String messageId, {DateTime? now}) => _db.write(
    (txn) => txn.update(
      OutboxColumns.table,
      {
        OutboxColumns.nextAttemptAt:
            (now ?? DateTime.now().toUtc()).millisecondsSinceEpoch,
        OutboxColumns.attempts: 0,
        OutboxColumns.lastError: null,
      },
      where: '${OutboxColumns.id} = ?',
      whereArgs: [messageId],
    ),
    topics: {DatabaseChangeNotifier.outbox},
  );
}

/// One pending send.
class OutboxEntry {
  const OutboxEntry({
    required this.messageId,
    required this.conversationId,
    required this.idempotencyKey,
    required this.payload,
    required this.attempts,
  });

  factory OutboxEntry.fromRow(Map<String, Object?> row) {
    final rawPayload = row[OutboxColumns.payload];
    Map<String, Object?> payload = const {};
    if (rawPayload is String && rawPayload.isNotEmpty) {
      final decoded = jsonDecode(rawPayload);
      if (decoded is Map<String, Object?>) payload = decoded;
    }
    return OutboxEntry(
      messageId: row[OutboxColumns.id]! as String,
      conversationId: row[OutboxColumns.conversationId]! as String,
      idempotencyKey: (row[OutboxColumns.idempotencyKey] as String?) ?? '',
      payload: payload,
      attempts: (row[OutboxColumns.attempts] as num?)?.toInt() ?? 0,
    );
  }

  final String messageId;
  final String conversationId;
  final String idempotencyKey;
  final Map<String, Object?> payload;
  final int attempts;

  /// The assistant message id this send should stream into.
  String? get assistantMessageId => payload['assistant_message_id'] as String?;

  String get content => (payload['content'] as String?) ?? '';

  String get modelId => (payload['model_id'] as String?) ?? '';
}
