import 'package:evdekimi_ai/core/result/result.dart';
import 'package:evdekimi_ai/features/ai/domain/model_descriptor.dart';
import 'package:evdekimi_ai/features/chat/domain/entities/conversation.dart';
import 'package:evdekimi_ai/features/chat/domain/entities/message.dart';

/// Reactive access to locally-stored conversations and messages.
///
/// **The local database is the source of truth.** Every read is a query against
/// SQLite and every write goes there first; the network only ever *feeds* the
/// local store. That inversion is what makes the app work offline by default
/// rather than as a special case — there is no "offline mode" branch, because
/// the online path already reads from disk.
abstract interface class ConversationRepository {
  /// The conversation list, newest activity first, excluding tombstoned rows.
  Stream<List<Conversation>> watchConversations({bool includeArchived = false});

  Stream<Conversation?> watchConversation(String conversationId);

  Future<Result<Conversation>> createConversation({
    required String modelId,
    required EngineKind engine,
    String? title,
  });

  Future<Result<void>> renameConversation(String conversationId, String title);

  Future<Result<void>> setPinned(
    String conversationId, {
    required bool isPinned,
  });

  Future<Result<void>> setArchived(
    String conversationId, {
    required bool isArchived,
  });

  /// Soft-deletes so the deletion can be synced later.
  Future<Result<void>> deleteConversation(String conversationId);

  /// Switches the model a thread uses for subsequent messages.
  Future<Result<void>> setModel(String conversationId, ModelDescriptor model);
}

/// Sending messages and consuming streamed replies.
abstract interface class ChatRepository {
  /// Messages of a conversation in `sequence` order.
  Stream<List<Message>> watchMessages(String conversationId);

  /// Persists a user message, enqueues it, and starts generating a reply.
  ///
  /// Returns as soon as both rows are committed — it does **not** wait for the
  /// reply. Progress is observed through [watchMessages], which is what keeps
  /// the UI identical whether the answer takes 50 ms or never arrives because
  /// the device is offline.
  Future<Result<SendMessageOutcome>> sendMessage({
    required String conversationId,
    required String content,
    List<PendingAttachment> attachments = const [],
  });

  /// Re-runs generation for an assistant message, replacing its content.
  Future<Result<SendMessageOutcome>> regenerate({
    required String conversationId,
    required String assistantMessageId,
  });

  /// Retries a message that ended in `failed`.
  Future<Result<SendMessageOutcome>> retryMessage({
    required String conversationId,
    required String messageId,
  });

  /// Stops an in-flight generation, keeping whatever was produced.
  Future<Result<void>> stopGeneration(String conversationId);

  /// Attempts delivery of everything queued. Safe to call repeatedly.
  ///
  /// Invoked on reconnect, on a timer, and on app resume; concurrent calls
  /// collapse into one pass.
  Future<Result<int>> flushOutbox();

  /// Number of messages waiting to be sent.
  Stream<int> watchPendingCount();

  /// Offline semantic search over stored messages, using on-device embeddings.
  Future<Result<List<MessageSearchHit>>> search(String query, {int limit = 20});
}

/// A file chosen in the composer but not yet attached to a persisted message.
class PendingAttachment {
  const PendingAttachment({
    required this.localPath,
    required this.kind,
    this.mimeType,
    this.sizeBytes,
    this.width,
    this.height,
    this.extractedText,
  });

  final String localPath;
  final AttachmentKind kind;
  final String? mimeType;
  final int? sizeBytes;
  final int? width;
  final int? height;

  /// Text already recognised on-device, so the prompt can include it even if
  /// the upload has not finished.
  final String? extractedText;
}

/// What `sendMessage` committed, for callers that need the ids immediately
/// (scroll-to-bottom, analytics correlation).
class SendMessageOutcome {
  const SendMessageOutcome({
    required this.userMessageId,
    required this.assistantMessageId,
    required this.wasQueuedOffline,
  });

  final String userMessageId;
  final String assistantMessageId;

  /// True when the message was stored for later instead of sent immediately.
  final bool wasQueuedOffline;
}

/// A search result with its relevance score.
class MessageSearchHit {
  const MessageSearchHit({
    required this.message,
    required this.conversationTitle,
    required this.score,
  });

  final Message message;
  final String conversationTitle;

  /// Cosine similarity in `[-1, 1]`; higher is more relevant.
  final double score;
}
