import 'package:equatable/equatable.dart';
import 'package:evdekimi_ai/features/ai/domain/inference_engine.dart';
import 'package:evdekimi_ai/features/ai/domain/model_descriptor.dart';

/// Who produced a message.
enum MessageRole {
  user,
  assistant,
  system;

  static MessageRole fromName(String name) => MessageRole.values.firstWhere(
    (role) => role.name == name,
    orElse: () => MessageRole.assistant,
  );
}

/// Delivery/generation state of a message.
///
/// This enum is the heart of the offline story. A message is a local row the
/// moment the user hits send, and its status — not a separate "pending" list —
/// is what the UI renders and what the outbox scans. Because the state lives in
/// the same table as the content, a process death mid-send cannot lose it.
enum MessageStatus {
  /// Composed but not yet submitted (used for restoring composer drafts).
  draft,

  /// Persisted and waiting for connectivity. The outbox owns it.
  queued,

  /// Handed to the transport; no tokens received yet.
  sending,

  /// Tokens are arriving. Content grows as deltas append.
  streaming,

  /// Finished normally.
  complete,

  /// Terminal failure. Retryable by the user.
  failed,

  /// The user stopped generation. Partial content is kept.
  cancelled;

  static MessageStatus fromName(String name) => MessageStatus.values.firstWhere(
    (status) => status.name == name,
    orElse: () => MessageStatus.complete,
  );

  /// Whether the message is still expected to change.
  bool get isInFlight =>
      this == MessageStatus.queued ||
      this == MessageStatus.sending ||
      this == MessageStatus.streaming;

  bool get isTerminal => !isInFlight && this != MessageStatus.draft;

  /// Whether a retry affordance should be offered.
  bool get canRetry => this == MessageStatus.failed;
}

enum AttachmentKind {
  image,
  document;

  static AttachmentKind fromName(String name) =>
      AttachmentKind.values.firstWhere(
        (kind) => kind.name == name,
        orElse: () => AttachmentKind.document,
      );
}

/// Upload lifecycle of an attachment, tracked separately from its message so a
/// failed upload can be retried without resending the text.
enum UploadState {
  pending,
  uploading,
  uploaded,
  failed;

  static UploadState fromName(String name) => UploadState.values.firstWhere(
    (state) => state.name == name,
    orElse: () => UploadState.pending,
  );
}

/// A file attached to a message.
class Attachment extends Equatable {
  const Attachment({
    required this.id,
    required this.messageId,
    required this.kind,
    required this.createdAt,
    this.localPath,
    this.remoteUrl,
    this.mimeType,
    this.sizeBytes,
    this.width,
    this.height,
    this.extractedText,
    this.uploadState = UploadState.pending,
  });

  final String id;
  final String messageId;
  final AttachmentKind kind;

  /// Path on this device. Present until the local cache is pruned.
  final String? localPath;

  /// Server URL once uploaded. Required before a vision model can see it.
  final String? remoteUrl;

  final String? mimeType;
  final int? sizeBytes;
  final int? width;
  final int? height;

  /// Text recognised on-device by ML Kit. Lets an image contribute to the
  /// prompt (and to offline search) even when the model has no vision support.
  final String? extractedText;

  final UploadState uploadState;
  final DateTime createdAt;

  bool get hasExtractedText =>
      extractedText != null && extractedText!.trim().isNotEmpty;

  /// The best available source for rendering a preview.
  String? get displaySource => localPath ?? remoteUrl;

  Attachment copyWith({
    String? remoteUrl,
    String? extractedText,
    UploadState? uploadState,
    int? width,
    int? height,
  }) => Attachment(
    id: id,
    messageId: messageId,
    kind: kind,
    createdAt: createdAt,
    localPath: localPath,
    remoteUrl: remoteUrl ?? this.remoteUrl,
    mimeType: mimeType,
    sizeBytes: sizeBytes,
    width: width ?? this.width,
    height: height ?? this.height,
    extractedText: extractedText ?? this.extractedText,
    uploadState: uploadState ?? this.uploadState,
  );

  @override
  List<Object?> get props => [
    id,
    messageId,
    kind,
    localPath,
    remoteUrl,
    uploadState,
    extractedText,
  ];
}

/// A single chat message.
class Message extends Equatable {
  const Message({
    required this.id,
    required this.conversationId,
    required this.role,
    required this.content,
    required this.status,
    required this.sequence,
    required this.createdAt,
    required this.updatedAt,
    this.remoteId,
    this.modelId,
    this.engine,
    this.tokenCount,
    this.latency,
    this.errorCode,
    this.errorMessage,
    this.replyToId,
    this.attachments = const [],
  });

  /// A user message ready to persist and enqueue.
  factory Message.userDraft({
    required String id,
    required String conversationId,
    required String content,
    required int sequence,
    required DateTime now,
    List<Attachment> attachments = const [],
  }) => Message(
    id: id,
    conversationId: conversationId,
    role: MessageRole.user,
    content: content,
    // Queued, not sending: the outbox decides when it goes out, so an offline
    // send and an online send take the identical path.
    status: MessageStatus.queued,
    sequence: sequence,
    createdAt: now,
    updatedAt: now,
    attachments: attachments,
  );

  /// The empty assistant message that a streaming reply fills in.
  ///
  /// Created up front so the bubble can appear immediately with a typing
  /// indicator, and so partial content survives if the app is killed mid-stream.
  factory Message.assistantPlaceholder({
    required String id,
    required String conversationId,
    required int sequence,
    required DateTime now,
    required String modelId,
    required EngineKind engine,
    String? replyToId,
  }) => Message(
    id: id,
    conversationId: conversationId,
    role: MessageRole.assistant,
    content: '',
    status: MessageStatus.sending,
    sequence: sequence,
    createdAt: now,
    updatedAt: now,
    modelId: modelId,
    engine: engine,
    replyToId: replyToId,
  );

  final String id;
  final String conversationId;

  /// Server-assigned id, once the message has been synced.
  final String? remoteId;

  final MessageRole role;
  final String content;
  final MessageStatus status;

  /// Monotonic position within the conversation. The sort key.
  final int sequence;

  final String? modelId;

  /// Which engine produced this message. Surfaced in the UI so the user can
  /// tell a local answer from a cloud one.
  final EngineKind? engine;

  final int? tokenCount;
  final Duration? latency;

  final String? errorCode;
  final String? errorMessage;

  /// The user message this assistant reply answers.
  final String? replyToId;

  final List<Attachment> attachments;

  final DateTime createdAt;
  final DateTime updatedAt;

  bool get isFromUser => role == MessageRole.user;

  bool get isFromAssistant => role == MessageRole.assistant;

  bool get hasContent => content.trim().isNotEmpty;

  bool get hasAttachments => attachments.isNotEmpty;

  /// True while an assistant bubble should show the typing indicator rather
  /// than text: committed to run, but nothing generated yet.
  bool get isAwaitingFirstToken =>
      isFromAssistant && status == MessageStatus.sending && !hasContent;

  /// Text used for embedding and search: the message plus any OCR'd image text,
  /// so a photo of a receipt is findable offline.
  String get searchableText {
    final extracted = attachments
        .map((attachment) => attachment.extractedText)
        .whereType<String>()
        .where((text) => text.trim().isNotEmpty);
    return [content, ...extracted].join('\n').trim();
  }

  /// Text recognised in this message's images, on the device.
  List<String> get recognisedText => attachments
      .map((attachment) => attachment.extractedText)
      .whereType<String>()
      .map((text) => text.trim())
      .where((text) => text.isNotEmpty)
      .toList(growable: false);

  /// Converts to the AI layer's prompt type.
  ///
  /// Carries what the user typed and nothing else. OCR text used to be folded in
  /// here, which read as harmless — the cloud model does need it inline — but it
  /// meant the local classifier saw the image's words as part of the question.
  /// It now travels as `InferenceRequest.recognisedText`, and each engine folds
  /// it in or keeps it apart according to what it can actually do with it.
  PromptTurn toPromptTurn() => PromptTurn(
    role: switch (role) {
      MessageRole.user => PromptRole.user,
      MessageRole.assistant => PromptRole.assistant,
      MessageRole.system => PromptRole.system,
    },
    content: content,
  );

  Message copyWith({
    String? remoteId,
    String? content,
    MessageStatus? status,
    String? modelId,
    EngineKind? engine,
    int? tokenCount,
    Duration? latency,
    String? errorCode,
    String? errorMessage,
    List<Attachment>? attachments,
    DateTime? updatedAt,
    bool clearError = false,
  }) => Message(
    id: id,
    conversationId: conversationId,
    remoteId: remoteId ?? this.remoteId,
    role: role,
    content: content ?? this.content,
    status: status ?? this.status,
    sequence: sequence,
    modelId: modelId ?? this.modelId,
    engine: engine ?? this.engine,
    tokenCount: tokenCount ?? this.tokenCount,
    latency: latency ?? this.latency,
    errorCode: clearError ? null : (errorCode ?? this.errorCode),
    errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    replyToId: replyToId,
    attachments: attachments ?? this.attachments,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  /// Appends a streamed delta.
  ///
  /// String concatenation is fine here: deltas are small and a message is
  /// rewritten to SQLite on a throttle, not per token. See `ChatRepository`.
  Message appendDelta(String delta, {required DateTime now}) => copyWith(
    content: content + delta,
    status: MessageStatus.streaming,
    updatedAt: now,
  );

  @override
  List<Object?> get props => [
    id,
    conversationId,
    remoteId,
    role,
    content,
    status,
    sequence,
    modelId,
    engine,
    tokenCount,
    errorCode,
    attachments,
    updatedAt,
  ];
}
