import 'package:equatable/equatable.dart';
import 'package:evdekimi_ai/features/ai/domain/model_descriptor.dart';

/// How far a locally-created row has got towards the server.
///
/// Conversations are created offline-first: a row exists locally before the
/// server has ever heard of it. This enum is what lets a later sync distinguish
/// "never uploaded" from "uploaded and since edited".
enum SyncState {
  /// Exists only on this device.
  localOnly,

  /// Matches the server.
  synced,

  /// Uploaded once, then changed locally.
  dirty;

  static SyncState fromName(String name) => SyncState.values.firstWhere(
    (state) => state.name == name,
    orElse: () => SyncState.localOnly,
  );
}

/// A chat thread.
class Conversation extends Equatable {
  const Conversation({
    required this.id,
    required this.title,
    required this.modelId,
    required this.engine,
    required this.createdAt,
    required this.updatedAt,
    this.remoteId,
    this.lastMessagePreview,
    this.messageCount = 0,
    this.isPinned = false,
    this.isArchived = false,
    this.syncState = SyncState.localOnly,
    this.deletedAt,
  });

  /// A brand-new local conversation.
  factory Conversation.draft({
    required String id,
    required String modelId,
    required EngineKind engine,
    required DateTime now,
    String? title,
  }) => Conversation(
    id: id,
    title: title ?? untitledTitle,
    modelId: modelId,
    engine: engine,
    createdAt: now,
    updatedAt: now,
  );

  /// Placeholder shown until the first exchange produces a real title.
  static const String untitledTitle = 'New chat';

  final String id;
  final String? remoteId;
  final String title;

  /// The model this thread is bound to. New messages default to it.
  final String modelId;

  final EngineKind engine;

  /// Snippet for the list row, denormalised so the list needs one query.
  final String? lastMessagePreview;

  final int messageCount;
  final bool isPinned;
  final bool isArchived;
  final SyncState syncState;

  /// Soft-delete marker. Rows are tombstoned rather than removed so a future
  /// sync can propagate the deletion instead of resurrecting the row.
  final DateTime? deletedAt;

  final DateTime createdAt;
  final DateTime updatedAt;

  bool get isDeleted => deletedAt != null;

  bool get hasTitle => title.isNotEmpty && title != untitledTitle;

  bool get isEmpty => messageCount == 0;

  Conversation copyWith({
    String? remoteId,
    String? title,
    String? modelId,
    EngineKind? engine,
    String? lastMessagePreview,
    int? messageCount,
    bool? isPinned,
    bool? isArchived,
    SyncState? syncState,
    DateTime? updatedAt,
    DateTime? deletedAt,
  }) => Conversation(
    id: id,
    remoteId: remoteId ?? this.remoteId,
    title: title ?? this.title,
    modelId: modelId ?? this.modelId,
    engine: engine ?? this.engine,
    lastMessagePreview: lastMessagePreview ?? this.lastMessagePreview,
    messageCount: messageCount ?? this.messageCount,
    isPinned: isPinned ?? this.isPinned,
    isArchived: isArchived ?? this.isArchived,
    syncState: syncState ?? this.syncState,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    deletedAt: deletedAt ?? this.deletedAt,
  );

  @override
  List<Object?> get props => [
    id,
    remoteId,
    title,
    modelId,
    engine,
    lastMessagePreview,
    messageCount,
    isPinned,
    isArchived,
    syncState,
    updatedAt,
    deletedAt,
  ];
}

/// Derives a human title from the first user message.
///
/// Runs entirely locally so a conversation is never called "New chat" just
/// because the device was offline. The remote backend may later supply a better
/// title, which overwrites this one.
abstract final class ConversationTitle {
  static const int maxLength = 48;

  static String fromFirstMessage(String message) {
    final normalised = message
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        // Strip common leading politeness so titles start with the subject.
        .replaceFirst(
          RegExp(
            r'^(please|hi|hello|hey|can you|could you|help me|i need)\b[\s,:]*',
            caseSensitive: false,
          ),
          '',
        )
        .trim();

    if (normalised.isEmpty) return Conversation.untitledTitle;

    final firstSentence = normalised.split(RegExp(r'[.!?\n]')).first.trim();
    final candidate = firstSentence.isEmpty ? normalised : firstSentence;

    if (candidate.length <= maxLength) {
      return _capitalise(candidate);
    }

    // Cut on a word boundary rather than mid-word.
    final truncated = candidate.substring(0, maxLength);
    final lastSpace = truncated.lastIndexOf(' ');
    final clipped = lastSpace > maxLength * 0.6
        ? truncated.substring(0, lastSpace)
        : truncated;
    return '${_capitalise(clipped.trimRight())}…';
  }

  static String _capitalise(String value) =>
      value.isEmpty ? value : value[0].toUpperCase() + value.substring(1);
}
