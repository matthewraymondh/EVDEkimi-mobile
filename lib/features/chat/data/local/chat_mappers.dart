import 'dart:convert';

import 'package:evdekimi_ai/core/persistence/database_schema.dart';
import 'package:evdekimi_ai/features/ai/domain/model_descriptor.dart';
import 'package:evdekimi_ai/features/chat/domain/entities/conversation.dart';
import 'package:evdekimi_ai/features/chat/domain/entities/message.dart';

/// Row ↔ entity translation.
///
/// Kept in one file so the storage representation is auditable in a single
/// place. Conventions, applied without exception:
///
/// * Timestamps are UTC milliseconds since epoch (`INTEGER`). Storing local time
///   would silently reorder a conversation when the user changes timezone.
/// * Enums persist as `name`, not index. Reordering an enum then cannot corrupt
///   existing rows, and the table stays readable in a SQL console.
/// * Booleans persist as 0/1, since SQLite has no boolean type.
abstract final class ChatMappers {
  // --- Conversation ------------------------------------------------------

  static Map<String, Object?> conversationToRow(Conversation conversation) => {
    ConversationColumns.id: conversation.id,
    ConversationColumns.remoteId: conversation.remoteId,
    ConversationColumns.title: conversation.title,
    ConversationColumns.modelId: conversation.modelId,
    ConversationColumns.engine: conversation.engine.name,
    ConversationColumns.lastMessagePreview: conversation.lastMessagePreview,
    ConversationColumns.messageCount: conversation.messageCount,
    ConversationColumns.isPinned: _boolToInt(conversation.isPinned),
    ConversationColumns.isArchived: _boolToInt(conversation.isArchived),
    ConversationColumns.syncState: conversation.syncState.name,
    ConversationColumns.createdAt: _toMillis(conversation.createdAt),
    ConversationColumns.updatedAt: _toMillis(conversation.updatedAt),
    ConversationColumns.deletedAt: conversation.deletedAt == null
        ? null
        : _toMillis(conversation.deletedAt!),
  };

  static Conversation conversationFromRow(Map<String, Object?> row) =>
      Conversation(
        id: row[ConversationColumns.id]! as String,
        remoteId: row[ConversationColumns.remoteId] as String?,
        title: (row[ConversationColumns.title] as String?) ?? '',
        modelId: (row[ConversationColumns.modelId] as String?) ?? '',
        engine: EngineKind.fromName(row[ConversationColumns.engine] as String?),
        lastMessagePreview:
            row[ConversationColumns.lastMessagePreview] as String?,
        messageCount: _asInt(row[ConversationColumns.messageCount]) ?? 0,
        isPinned: _intToBool(row[ConversationColumns.isPinned]),
        isArchived: _intToBool(row[ConversationColumns.isArchived]),
        syncState: SyncState.fromName(
          (row[ConversationColumns.syncState] as String?) ?? '',
        ),
        createdAt: _fromMillis(row[ConversationColumns.createdAt]),
        updatedAt: _fromMillis(row[ConversationColumns.updatedAt]),
        deletedAt: _fromMillisOrNull(row[ConversationColumns.deletedAt]),
      );

  // --- Message ----------------------------------------------------------

  static Map<String, Object?> messageToRow(Message message) => {
    MessageColumns.id: message.id,
    MessageColumns.conversationId: message.conversationId,
    MessageColumns.remoteId: message.remoteId,
    MessageColumns.role: message.role.name,
    MessageColumns.content: message.content,
    MessageColumns.status: message.status.name,
    MessageColumns.sequence: message.sequence,
    MessageColumns.modelId: message.modelId,
    MessageColumns.engine: message.engine?.name,
    MessageColumns.tokenCount: message.tokenCount,
    MessageColumns.latencyMs: message.latency?.inMilliseconds,
    MessageColumns.errorCode: message.errorCode,
    MessageColumns.errorMessage: message.errorMessage,
    MessageColumns.replyToId: message.replyToId,
    MessageColumns.metadata: null,
    MessageColumns.createdAt: _toMillis(message.createdAt),
    MessageColumns.updatedAt: _toMillis(message.updatedAt),
  };

  /// Builds a message, optionally with attachments already loaded.
  static Message messageFromRow(
    Map<String, Object?> row, {
    List<Attachment> attachments = const [],
  }) {
    final latencyMs = _asInt(row[MessageColumns.latencyMs]);
    return Message(
      id: row[MessageColumns.id]! as String,
      conversationId: row[MessageColumns.conversationId]! as String,
      remoteId: row[MessageColumns.remoteId] as String?,
      role: MessageRole.fromName((row[MessageColumns.role] as String?) ?? ''),
      content: (row[MessageColumns.content] as String?) ?? '',
      status: MessageStatus.fromName(
        (row[MessageColumns.status] as String?) ?? '',
      ),
      sequence: _asInt(row[MessageColumns.sequence]) ?? 0,
      modelId: row[MessageColumns.modelId] as String?,
      engine: row[MessageColumns.engine] == null
          ? null
          : EngineKind.fromName(row[MessageColumns.engine] as String?),
      tokenCount: _asInt(row[MessageColumns.tokenCount]),
      latency: latencyMs == null ? null : Duration(milliseconds: latencyMs),
      errorCode: row[MessageColumns.errorCode] as String?,
      errorMessage: row[MessageColumns.errorMessage] as String?,
      replyToId: row[MessageColumns.replyToId] as String?,
      attachments: attachments,
      createdAt: _fromMillis(row[MessageColumns.createdAt]),
      updatedAt: _fromMillis(row[MessageColumns.updatedAt]),
    );
  }

  // --- Attachment -------------------------------------------------------

  static Map<String, Object?> attachmentToRow(Attachment attachment) => {
    AttachmentColumns.id: attachment.id,
    AttachmentColumns.messageId: attachment.messageId,
    AttachmentColumns.kind: attachment.kind.name,
    AttachmentColumns.localPath: attachment.localPath,
    AttachmentColumns.remoteUrl: attachment.remoteUrl,
    AttachmentColumns.mimeType: attachment.mimeType,
    AttachmentColumns.sizeBytes: attachment.sizeBytes,
    AttachmentColumns.width: attachment.width,
    AttachmentColumns.height: attachment.height,
    AttachmentColumns.extractedText: attachment.extractedText,
    AttachmentColumns.uploadState: attachment.uploadState.name,
    AttachmentColumns.createdAt: _toMillis(attachment.createdAt),
  };

  static Attachment attachmentFromRow(Map<String, Object?> row) => Attachment(
    id: row[AttachmentColumns.id]! as String,
    messageId: row[AttachmentColumns.messageId]! as String,
    kind: AttachmentKind.fromName(
      (row[AttachmentColumns.kind] as String?) ?? '',
    ),
    localPath: row[AttachmentColumns.localPath] as String?,
    remoteUrl: row[AttachmentColumns.remoteUrl] as String?,
    mimeType: row[AttachmentColumns.mimeType] as String?,
    sizeBytes: _asInt(row[AttachmentColumns.sizeBytes]),
    width: _asInt(row[AttachmentColumns.width]),
    height: _asInt(row[AttachmentColumns.height]),
    extractedText: row[AttachmentColumns.extractedText] as String?,
    uploadState: UploadState.fromName(
      (row[AttachmentColumns.uploadState] as String?) ?? '',
    ),
    createdAt: _fromMillis(row[AttachmentColumns.createdAt]),
  );

  // --- Model catalog ----------------------------------------------------

  static Map<String, Object?> modelToRow(
    ModelDescriptor model,
    DateTime now,
  ) => {
    ModelCatalogColumns.id: model.id,
    ModelCatalogColumns.name: model.name,
    ModelCatalogColumns.provider: model.provider,
    ModelCatalogColumns.engine: model.engine.name,
    ModelCatalogColumns.contextWindow: model.contextWindow,
    ModelCatalogColumns.supportsStreaming: _boolToInt(model.supportsStreaming),
    ModelCatalogColumns.supportsVision: _boolToInt(model.supportsVision),
    ModelCatalogColumns.isDefault: _boolToInt(model.isDefault),
    ModelCatalogColumns.description: model.description,
    ModelCatalogColumns.updatedAt: _toMillis(now),
  };

  static ModelDescriptor modelFromRow(Map<String, Object?> row) =>
      ModelDescriptor(
        id: row[ModelCatalogColumns.id]! as String,
        name: (row[ModelCatalogColumns.name] as String?) ?? '',
        provider: (row[ModelCatalogColumns.provider] as String?) ?? 'unknown',
        engine: EngineKind.fromName(row[ModelCatalogColumns.engine] as String?),
        contextWindow: _asInt(row[ModelCatalogColumns.contextWindow]) ?? 8192,
        supportsStreaming: _intToBool(
          row[ModelCatalogColumns.supportsStreaming],
        ),
        supportsVision: _intToBool(row[ModelCatalogColumns.supportsVision]),
        isDefault: _intToBool(row[ModelCatalogColumns.isDefault]),
        description: row[ModelCatalogColumns.description] as String?,
      );

  // --- Primitives -------------------------------------------------------

  static int _boolToInt(bool value) => value ? 1 : 0;

  static bool _intToBool(Object? value) => _asInt(value) == 1;

  static int _toMillis(DateTime value) => value.toUtc().millisecondsSinceEpoch;

  static DateTime _fromMillis(Object? value) =>
      DateTime.fromMillisecondsSinceEpoch(_asInt(value) ?? 0, isUtc: true);

  static DateTime? _fromMillisOrNull(Object? value) {
    final millis = _asInt(value);
    if (millis == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true);
  }

  /// sqflite can hand back `int` or `num` depending on platform and column
  /// affinity, so every numeric read goes through this.
  static int? _asInt(Object? value) => switch (value) {
    final int value => value,
    final num value => value.toInt(),
    final String value => int.tryParse(value),
    _ => null,
  };

  /// Encodes an arbitrary map for the `metadata` forward-compatibility column.
  static String? encodeMetadata(Map<String, Object?>? metadata) =>
      metadata == null || metadata.isEmpty ? null : jsonEncode(metadata);

  static Map<String, Object?> decodeMetadata(Object? raw) {
    if (raw is! String || raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, Object?> ? decoded : const {};
    } on FormatException {
      return const {};
    }
  }
}
