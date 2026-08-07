import 'dart:async';

import 'package:evdekimi_ai/core/logging/app_logger.dart';
import 'package:evdekimi_ai/core/persistence/app_database.dart';
import 'package:evdekimi_ai/core/persistence/database_schema.dart';
import 'package:evdekimi_ai/core/result/result.dart';
import 'package:evdekimi_ai/features/ai/domain/model_descriptor.dart';
import 'package:evdekimi_ai/features/chat/data/local/conversation_dao.dart';
import 'package:evdekimi_ai/features/chat/domain/entities/conversation.dart';
import 'package:evdekimi_ai/features/chat/domain/repositories/chat_repository.dart';
import 'package:uuid/uuid.dart';

/// Local-first conversation management.
class ConversationRepositoryImpl implements ConversationRepository {
  ConversationRepositoryImpl({
    required AppDatabase database,
    required ConversationDao dao,
    required AppLogger logger,
    Uuid? uuid,
  }) : _database = database,
       _dao = dao,
       _logger = logger.scoped('chat.conversations'),
       _uuid = uuid ?? const Uuid();

  final AppDatabase _database;
  final ConversationDao _dao;
  final AppLogger _logger;
  final Uuid _uuid;

  @override
  Stream<List<Conversation>> watchConversations({
    bool includeArchived = false,
  }) => watchQuery(
    notifier: _database.changes,
    topics: {DatabaseChangeNotifier.conversations},
    query: () => _dao.findAll(includeArchived: includeArchived),
  );

  @override
  Stream<Conversation?> watchConversation(String conversationId) => watchQuery(
    notifier: _database.changes,
    topics: {
      DatabaseChangeNotifier.conversations,
      DatabaseChangeNotifier.messagesOf(conversationId),
    },
    query: () => _dao.findById(conversationId),
  );

  @override
  Future<Result<Conversation>> createConversation({
    required String modelId,
    required EngineKind engine,
    String? title,
  }) => Result.guardAsync(() async {
    final conversation = Conversation.draft(
      id: _uuid.v4(),
      modelId: modelId,
      engine: engine,
      now: DateTime.now().toUtc(),
      title: title,
    );
    await _dao.insert(conversation);
    _logger.i(
      'Conversation created',
      fields: {'id': conversation.id, 'model': modelId},
    );
    return conversation;
  });

  @override
  Future<Result<void>> renameConversation(
    String conversationId,
    String title,
  ) => Result.guardAsync(() async {
    final trimmed = title.trim();
    await _dao.update(conversationId, {
      ConversationColumns.title: trimmed.isEmpty
          ? Conversation.untitledTitle
          : trimmed,
      // A local edit to a synced row makes it dirty, so a later sync knows to
      // push rather than assume the server copy is current.
      ConversationColumns.syncState: SyncState.dirty.name,
    });
  });

  @override
  Future<Result<void>> setPinned(
    String conversationId, {
    required bool isPinned,
  }) => Result.guardAsync(
    () => _dao.update(conversationId, {
      ConversationColumns.isPinned: isPinned ? 1 : 0,
    }),
  );

  @override
  Future<Result<void>> setArchived(
    String conversationId, {
    required bool isArchived,
  }) => Result.guardAsync(
    () => _dao.update(conversationId, {
      ConversationColumns.isArchived: isArchived ? 1 : 0,
    }),
  );

  @override
  Future<Result<void>> deleteConversation(String conversationId) =>
      Result.guardAsync(() async {
        await _dao.softDelete(conversationId, DateTime.now().toUtc());
        _logger.i('Conversation deleted', fields: {'id': conversationId});
      });

  @override
  Future<Result<void>> setModel(String conversationId, ModelDescriptor model) =>
      Result.guardAsync(
        () => _dao.update(conversationId, {
          ConversationColumns.modelId: model.id,
          ConversationColumns.engine: model.engine.name,
        }),
      );
}
