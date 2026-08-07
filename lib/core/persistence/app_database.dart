import 'dart:async';

import 'package:evdekimi_ai/core/error/exceptions.dart';
import 'package:evdekimi_ai/core/logging/app_logger.dart';
import 'package:evdekimi_ai/core/persistence/database_schema.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// Owns the sqflite connection, its migrations, and change notification.
///
/// **Why sqflite and not Drift/Isar.** Drift would generate the DAO layer and
/// give `watch()` for free. The tradeoff taken here is explicit SQL plus a
/// hand-rolled change notifier, chosen because it keeps the project free of
/// `build_runner` — no generated files in review, no codegen step in CI, and a
/// reviewer can read the exact query that runs. The cost is this class: ~120
/// lines that Drift would have written. See `docs/ARCHITECTURE.md`.
class AppDatabase {
  AppDatabase({
    required AppLogger logger,
    DatabaseFactory? factory,
    String? path,
  }) : _logger = logger.scoped('db'),
       _factory = factory,
       _path = path;

  final AppLogger _logger;
  final DatabaseFactory? _factory;
  final String? _path;

  final DatabaseChangeNotifier changes = DatabaseChangeNotifier();

  Database? _database;
  Future<Database>? _opening;

  /// Opens the database, running migrations. Concurrent callers share one open.
  Future<Database> get database {
    final existing = _database;
    if (existing != null && existing.isOpen) return Future.value(existing);
    return _opening ??= _open().whenComplete(() => _opening = null);
  }

  Future<Database> _open() async {
    try {
      final factory = _factory ?? databaseFactory;
      final path =
          _path ??
          p.join(await factory.getDatabasesPath(), DatabaseSchema.databaseName);

      _logger.i(
        'Opening database',
        fields: {'version': DatabaseSchema.version},
      );

      final database = await factory.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: DatabaseSchema.version,
          onConfigure: (db) async {
            // Off by default in SQLite; without this, ON DELETE CASCADE is
            // silently ignored and deleting a conversation orphans its messages.
            await db.execute('PRAGMA foreign_keys = ON');
          },
          onCreate: (db, version) async {
            // A fresh install replays the same migrations as an upgrade, so the
            // two code paths cannot drift apart.
            await _migrate(db, from: 0, to: version);
          },
          onUpgrade: (db, oldVersion, newVersion) async {
            await _migrate(db, from: oldVersion, to: newVersion);
          },
          onDowngrade: onDatabaseDowngradeDelete,
          onOpen: (db) async {
            // WAL keeps reads from blocking on the write that a streaming
            // response performs on every token.
            await db.rawQuery('PRAGMA journal_mode = WAL');
          },
        ),
      );

      _database = database;
      return database;
    } catch (error, stackTrace) {
      _logger.e(
        'Failed to open database',
        error: error,
        stackTrace: stackTrace,
      );
      throw LocalStoreException(
        'Could not open the local database',
        cause: error,
      );
    }
  }

  Future<void> _migrate(
    Database db, {
    required int from,
    required int to,
  }) async {
    for (var version = from + 1; version <= to; version++) {
      final statements = DatabaseSchema.migrations[version];
      if (statements == null) {
        throw LocalStoreException('Missing migration for version $version');
      }
      _logger.i('Applying migration', fields: {'version': version});
      final batch = db.batch();
      for (final statement in statements) {
        batch.execute(statement);
      }
      await batch.commit(noResult: true);
    }
  }

  /// Runs [action] inside a transaction and publishes [topics] once it commits.
  ///
  /// Notifying after commit — never inside the transaction — is what stops a
  /// listener from re-querying and reading rows that are about to be rolled
  /// back.
  Future<T> write<T>(
    Future<T> Function(Transaction txn) action, {
    Set<String> topics = const {},
  }) async {
    final db = await database;
    try {
      final result = await db.transaction<T>(action);
      if (topics.isNotEmpty) changes.publish(topics);
      return result;
    } on LocalStoreException {
      rethrow;
    } catch (error, stackTrace) {
      _logger.e('Write failed', error: error, stackTrace: stackTrace);
      throw LocalStoreException('Local write failed', cause: error);
    }
  }

  /// Deletes every row while keeping the schema. Used on sign-out.
  Future<void> wipe() async {
    final db = await database;
    final batch = db.batch();
    for (final table in DatabaseSchema.tableNames) {
      batch.delete(table);
    }
    await batch.commit(noResult: true);
    changes.publish(DatabaseSchema.tableNames.toSet());
    _logger.i('Local database wiped');
  }

  Future<void> close() async {
    await _database?.close();
    _database = null;
    changes.dispose();
  }
}

/// Broadcasts coarse "something under this topic changed" signals.
///
/// This is the piece Drift would have generated. Repositories publish a topic
/// after writing and build reactive queries as
/// `initial query + re-query on each matching signal`.
///
/// Topics are intentionally coarse (`messages:<conversationId>` rather than
/// per-row): a streaming reply writes on every token, and fine-grained
/// invalidation would cost more than the re-query it saves.
class DatabaseChangeNotifier {
  final StreamController<Set<String>> _controller =
      StreamController<Set<String>>.broadcast();

  /// Topic name for the conversation list.
  static const String conversations = 'conversations';

  /// Topic name for the pending-send queue.
  static const String outbox = 'outbox';

  static const String modelCatalog = 'model_catalog';

  /// Topic name for the messages of one conversation.
  static String messagesOf(String conversationId) => 'messages:$conversationId';

  void publish(Set<String> topics) {
    if (_controller.isClosed || topics.isEmpty) return;
    _controller.add(topics);
  }

  /// Fires whenever any of [topics] is published.
  Stream<void> watch(Set<String> topics) =>
      _controller.stream.where((published) => published.any(topics.contains));

  void dispose() => unawaited(_controller.close());
}

/// Reruns [query] on every relevant change signal.
///
/// Emits once immediately, then again after each matching write. Consecutive
/// signals are collapsed with a microtask-scale debounce so a batch insert
/// produces one re-query rather than one per row.
Stream<T> watchQuery<T>({
  required DatabaseChangeNotifier notifier,
  required Set<String> topics,
  required Future<T> Function() query,
  Duration debounce = const Duration(milliseconds: 16),
}) {
  late StreamController<T> controller;
  StreamSubscription<void>? subscription;
  Timer? debounceTimer;
  var isClosed = false;
  var inFlight = false;
  var queuedAgain = false;

  Future<void> run() async {
    if (isClosed) return;
    if (inFlight) {
      // Coalesce: remember that another run is needed rather than queueing
      // an unbounded number of overlapping queries.
      queuedAgain = true;
      return;
    }
    inFlight = true;
    try {
      final value = await query();
      if (!isClosed) controller.add(value);
    } catch (error, stackTrace) {
      if (!isClosed) controller.addError(error, stackTrace);
    } finally {
      inFlight = false;
      if (queuedAgain && !isClosed) {
        queuedAgain = false;
        await run();
      }
    }
  }

  controller = StreamController<T>(
    onListen: () {
      subscription = notifier.watch(topics).listen((_) {
        debounceTimer?.cancel();
        debounceTimer = Timer(debounce, () => unawaited(run()));
      });
      unawaited(run());
    },
    onCancel: () async {
      isClosed = true;
      debounceTimer?.cancel();
      await subscription?.cancel();
      await controller.close();
    },
  );

  return controller.stream;
}
