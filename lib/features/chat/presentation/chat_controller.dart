import 'dart:async';

import 'package:evdekimi_ai/core/error/error_mapper.dart';
import 'package:evdekimi_ai/core/error/failure.dart';
import 'package:evdekimi_ai/di/providers.dart';
import 'package:evdekimi_ai/features/ai/domain/model_descriptor.dart';
import 'package:evdekimi_ai/features/chat/domain/repositories/chat_repository.dart';
import 'package:evdekimi_ai/features/input/attachment_service.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Composer state for one conversation.
class ComposerState {
  const ComposerState({
    this.attachments = const [],
    this.isSending = false,
    this.isAttaching = false,
    this.failure,
  });

  /// Files staged for the next send.
  final List<PendingAttachment> attachments;

  final bool isSending;

  /// True while the picker/OCR pipeline is running, so the UI can show progress
  /// on the attach button rather than appearing frozen.
  final bool isAttaching;

  final Failure? failure;

  bool get hasAttachments => attachments.isNotEmpty;

  ComposerState copyWith({
    List<PendingAttachment>? attachments,
    bool? isSending,
    bool? isAttaching,
    Failure? failure,
    bool clearFailure = false,
  }) => ComposerState(
    attachments: attachments ?? this.attachments,
    isSending: isSending ?? this.isSending,
    isAttaching: isAttaching ?? this.isAttaching,
    failure: clearFailure ? null : (failure ?? this.failure),
  );
}

/// Per-conversation composer actions.
///
/// The controller holds only what the composer needs. Message content itself is
/// never mirrored here — it is read from `messagesProvider`, which streams from
/// the database, so the transcript has exactly one source of truth and cannot
/// disagree with what was persisted.
class ChatController extends Notifier<ComposerState> {
  ChatController(this.conversationId);

  final String conversationId;

  @override
  ComposerState build() => const ComposerState();

  /// Persists the message and starts generation.
  ///
  /// Returns true when it was accepted. Note this resolves as soon as the write
  /// commits, not when the answer completes.
  Future<bool> send(String text) async {
    if (state.isSending) return false;
    final trimmed = text.trim();
    if (trimmed.isEmpty && !state.hasAttachments) return false;

    state = state.copyWith(isSending: true, clearFailure: true);

    final result = await ref
        .read(chatRepositoryProvider)
        .sendMessage(
          conversationId: conversationId,
          content: trimmed,
          attachments: state.attachments,
        );

    return result.fold(
      ok: (outcome) {
        // Clear the tray only on success, so a failure does not lose the images
        // the user picked.
        state = const ComposerState();
        if (ref.read(settingsControllerProvider).hapticsEnabled) {
          unawaited(HapticFeedback.lightImpact());
        }
        return true;
      },
      err: (failure) {
        state = state.copyWith(isSending: false, failure: failure);
        return false;
      },
    );
  }

  Future<void> stop() =>
      ref.read(chatRepositoryProvider).stopGeneration(conversationId);

  Future<void> retry(String messageId) async {
    final result = await ref
        .read(chatRepositoryProvider)
        .retryMessage(conversationId: conversationId, messageId: messageId);
    result.fold(
      ok: (_) {},
      err: (failure) => state = state.copyWith(failure: failure),
    );
  }

  Future<void> regenerate(String assistantMessageId) async {
    final result = await ref
        .read(chatRepositoryProvider)
        .regenerate(
          conversationId: conversationId,
          assistantMessageId: assistantMessageId,
        );
    result.fold(
      ok: (_) {},
      err: (failure) => state = state.copyWith(failure: failure),
    );
  }

  /// Picks an image, runs on-device OCR, and stages it.
  Future<void> attachImage(ImageSourceKind source) async {
    if (state.isAttaching) return;
    state = state.copyWith(isAttaching: true, clearFailure: true);
    try {
      final attachment = await ref
          .read(attachmentServiceProvider)
          .pickImage(source);
      if (attachment == null) {
        // User cancelled; not an error.
        state = state.copyWith(isAttaching: false);
        return;
      }
      state = state.copyWith(
        attachments: [...state.attachments, attachment],
        isAttaching: false,
      );
    } catch (error, stackTrace) {
      // A denied camera/photo permission arrives here as an exception; the shared
      // mapper turns it into the PermissionFailure the UI knows how to render.
      state = state.copyWith(
        isAttaching: false,
        failure: ErrorMapper.map(error, stackTrace: stackTrace),
      );
    }
  }

  void removeAttachment(int index) {
    if (index < 0 || index >= state.attachments.length) return;
    final next = [...state.attachments]..removeAt(index);
    state = state.copyWith(attachments: next);
  }

  void clearFailure() => state = state.copyWith(clearFailure: true);

  /// Switches the model this thread uses for subsequent messages.
  Future<void> setModel(ModelDescriptor model) async {
    await ref
        .read(conversationRepositoryProvider)
        .setModel(conversationId, model);
    await ref.read(settingsControllerProvider.notifier).setModel(model);
  }
}

final chatControllerProvider =
    NotifierProvider.family<ChatController, ComposerState, String>(
      ChatController.new,
    );
