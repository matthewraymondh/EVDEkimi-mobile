import 'dart:io';

import 'package:evdekimi_ai/design_system/chat_theme.dart';
import 'package:evdekimi_ai/design_system/tokens.dart';
import 'package:evdekimi_ai/design_system/widgets/app_widgets.dart';
import 'package:evdekimi_ai/di/providers.dart';
import 'package:evdekimi_ai/features/chat/presentation/chat_controller.dart';
import 'package:evdekimi_ai/features/input/attachment_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The input row: text, attachments, dictation, send/stop.
///
/// It owns the `TextEditingController` locally rather than mirroring the draft
/// into Riverpod. Routing every keystroke through a provider would rebuild the
/// whole transcript on each character; the controller only needs to publish text
/// at the moment of sending.
class MessageComposer extends ConsumerStatefulWidget {
  const MessageComposer({
    required this.conversationId,
    required this.isGenerating,
    super.key,
  });

  final String conversationId;

  /// When true the send button becomes a stop button.
  final bool isGenerating;

  @override
  ConsumerState<MessageComposer> createState() => _MessageComposerState();
}

class _MessageComposerState extends ConsumerState<MessageComposer> {
  final _textController = TextEditingController();
  final _focusNode = FocusNode();

  /// Text captured before dictation started, so a transcript is appended to what
  /// the user had already typed instead of replacing it.
  String _textBeforeDictation = '';

  @override
  void initState() {
    super.initState();
    _textController.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _textController
      ..removeListener(_onTextChanged)
      ..dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onTextChanged() => setState(() {});

  bool get _canSend =>
      _textController.text.trim().isNotEmpty ||
      ref.read(chatControllerProvider(widget.conversationId)).hasAttachments;

  Future<void> _send() async {
    final controller = ref.read(
      chatControllerProvider(widget.conversationId).notifier,
    );
    final text = _textController.text;
    // Clear optimistically: the repository commits to the database before it
    // returns, and a stale draft left in the field after a successful send looks
    // like the message did not go.
    _textController.clear();

    final accepted = await controller.send(text);
    if (!accepted && mounted) {
      // Put the text back so nothing is lost.
      _textController.text = text;
      final failure = ref
          .read(chatControllerProvider(widget.conversationId))
          .failure;
      if (failure != null) {
        showAppSnackBar(context, failure.userMessage, isError: true);
        controller.clearFailure();
      }
    }
  }

  Future<void> _toggleDictation() async {
    final speech = ref.read(speechInputServiceProvider);
    final state = ref.read(speechStateProvider).value;

    if (state?.isListening ?? false) {
      final transcript = await speech.stop();
      _applyTranscript(transcript, isFinal: true);
      return;
    }

    _textBeforeDictation = _textController.text;
    try {
      await speech.start();
    } catch (error) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        error.toString().contains('Microphone')
            ? 'Microphone access is required for dictation.'
            : 'Dictation is unavailable on this device.',
        isError: true,
      );
    }
  }

  void _applyTranscript(String transcript, {required bool isFinal}) {
    if (transcript.isEmpty) return;
    final separator =
        _textBeforeDictation.isEmpty || _textBeforeDictation.endsWith(' ')
        ? ''
        : ' ';
    final combined = '$_textBeforeDictation$separator$transcript';
    _textController
      ..text = combined
      ..selection = TextSelection.collapsed(offset: combined.length);
    if (isFinal) _focusNode.requestFocus();
  }

  Future<void> _showAttachSheet() async {
    final controller = ref.read(
      chatControllerProvider(widget.conversationId).notifier,
    );

    final source = await showModalBottomSheet<ImageSourceKind>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take a photo'),
              subtitle: const Text('Text is read on-device with ML Kit'),
              onTap: () => Navigator.of(context).pop(ImageSourceKind.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose from gallery'),
              onTap: () => Navigator.of(context).pop(ImageSourceKind.gallery),
            ),
            const SizedBox(height: AppSpacing.sm),
          ],
        ),
      ),
    );

    if (source == null) return;
    await controller.attachImage(source);

    if (!mounted) return;
    final failure = ref
        .read(chatControllerProvider(widget.conversationId))
        .failure;
    if (failure != null) {
      showAppSnackBar(context, failure.userMessage, isError: true);
      controller.clearFailure();
    }
  }

  @override
  Widget build(BuildContext context) {
    final chat = context.chatTheme;
    final composer = ref.watch(chatControllerProvider(widget.conversationId));
    final settings = ref.watch(settingsControllerProvider);
    final speech = ref.watch(speechStateProvider).value;
    final isListening = speech?.isListening ?? false;

    // Live-update the field as interim transcripts arrive.
    ref.listen(speechStateProvider, (previous, next) {
      final transcript = next.value?.transcript;
      if (transcript == null || transcript.isEmpty) return;
      if (next.value?.isListening ?? false) {
        _applyTranscript(transcript, isFinal: false);
      }
    });

    // A floating pill rather than a docked bar: it reads as something you reach
    // for, and letting the canvas show beneath keeps the transcript feeling
    // continuous instead of cut off by a hard edge.
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          AppSpacing.sm,
          AppSpacing.md,
          AppSpacing.md,
        ),
        child: Container(
          decoration: BoxDecoration(
            color: chat.composerBackground,
            borderRadius: AppRadius.allXl,
            border: Border.all(color: chat.composerBorder),
          ),
          padding: const EdgeInsets.all(AppSpacing.xs),
          child: Column(
            children: [
              if (composer.hasAttachments)
                _AttachmentTray(conversationId: widget.conversationId),

              if (isListening)
                _DictationIndicator(level: speech?.soundLevel ?? 0),

              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  IconButton(
                    onPressed: composer.isAttaching ? null : _showAttachSheet,
                    tooltip: 'Attach an image',
                    icon: composer.isAttaching
                        ? const SizedBox.square(
                            dimension: AppSizes.iconSm,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.add_photo_alternate_outlined),
                  ),

                  Expanded(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        maxHeight: AppSizes.composerMaxHeight,
                      ),
                      child: TextField(
                        controller: _textController,
                        focusNode: _focusNode,
                        maxLines: null,
                        minLines: 1,
                        textInputAction: settings.sendOnEnter
                            ? TextInputAction.send
                            : TextInputAction.newline,
                        keyboardType: TextInputType.multiline,
                        textCapitalization: TextCapitalization.sentences,
                        decoration: const InputDecoration(
                          hintText: 'Message EVDEkimi…',
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          filled: false,
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: AppSpacing.sm,
                            vertical: AppSpacing.md,
                          ),
                        ),
                        onSubmitted: settings.sendOnEnter
                            ? (_) {
                                if (_canSend) _send();
                              }
                            : null,
                      ),
                    ),
                  ),

                  IconButton(
                    onPressed: _toggleDictation,
                    tooltip: isListening ? 'Stop dictation' : 'Dictate',
                    isSelected: isListening,
                    icon: Icon(
                      isListening ? Icons.mic : Icons.mic_none_rounded,
                      color: isListening ? chat.danger : null,
                    ),
                  ),

                  const SizedBox(width: AppSpacing.xs),
                  _SendButton(
                    isGenerating: widget.isGenerating,
                    isEnabled: _canSend || widget.isGenerating,
                    onSend: _send,
                    onStop: () => ref
                        .read(
                          chatControllerProvider(
                            widget.conversationId,
                          ).notifier,
                        )
                        .stop(),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Morphs between send and stop.
class _SendButton extends StatelessWidget {
  const _SendButton({
    required this.isGenerating,
    required this.isEnabled,
    required this.onSend,
    required this.onStop,
  });

  final bool isGenerating;
  final bool isEnabled;
  final VoidCallback onSend;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final chat = context.chatTheme;
    return AnimatedContainer(
      duration: AppDuration.fast,
      curve: AppCurve.standard,
      width: AppSizes.minTapTarget,
      height: AppSizes.minTapTarget,
      decoration: BoxDecoration(
        color: isGenerating
            ? chat.danger.withValues(alpha: 0.14)
            : isEnabled
            ? context.colors.primary
            : context.colors.surfaceContainerHigh,
        shape: BoxShape.circle,
      ),
      child: IconButton(
        onPressed: isGenerating
            ? onStop
            : isEnabled
            ? onSend
            : null,
        tooltip: isGenerating ? 'Stop generating' : 'Send',
        icon: Icon(
          isGenerating ? Icons.stop_rounded : Icons.arrow_upward_rounded,
          color: isGenerating
              ? chat.danger
              : isEnabled
              ? context.colors.onPrimary
              : context.colors.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// Live microphone level while dictating.
class _DictationIndicator extends StatelessWidget {
  const _DictationIndicator({required this.level});

  final double level;

  @override
  Widget build(BuildContext context) {
    final chat = context.chatTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Row(
        children: [
          Icon(
            Icons.graphic_eq_rounded,
            size: AppSizes.iconSm,
            color: chat.danger,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: ClipRRect(
              borderRadius: AppRadius.allPill,
              child: LinearProgressIndicator(
                value: level.clamp(0.05, 1.0),
                backgroundColor: context.colors.surfaceContainerHigh,
                color: chat.danger,
                minHeight: 4,
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Text(
            'Listening…',
            style: context.texts.labelSmall?.copyWith(color: chat.danger),
          ),
        ],
      ),
    );
  }
}

/// Thumbnails of staged attachments, each removable.
class _AttachmentTray extends ConsumerWidget {
  const _AttachmentTray({required this.conversationId});

  final String conversationId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final composer = ref.watch(chatControllerProvider(conversationId));
    final controller = ref.read(
      chatControllerProvider(conversationId).notifier,
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: SizedBox(
        height: 76,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: composer.attachments.length,
          separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.sm),
          itemBuilder: (context, index) {
            final attachment = composer.attachments[index];
            return Stack(
              children: [
                ClipRRect(
                  borderRadius: AppRadius.allSm,
                  child: Image.file(
                    File(attachment.localPath),
                    width: 76,
                    height: 76,
                    fit: BoxFit.cover,
                  ),
                ),
                if (attachment.extractedText != null)
                  Positioned(
                    left: 2,
                    bottom: 2,
                    child: AppBadge(
                      label: 'OCR',
                      icon: Icons.document_scanner_outlined,
                      color: context.chatTheme.onDeviceAccent,
                    ),
                  ),
                Positioned(
                  right: 0,
                  top: 0,
                  child: GestureDetector(
                    onTap: () {
                      controller.removeAttachment(index);
                      unawaitedHaptic(ref);
                    },
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      decoration: const BoxDecoration(
                        color: Colors.black54,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.close_rounded,
                        size: 14,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Fires a selection tick when haptics are enabled in settings.
void unawaitedHaptic(WidgetRef ref) {
  if (ref.read(settingsControllerProvider).hapticsEnabled) {
    HapticFeedback.selectionClick();
  }
}
