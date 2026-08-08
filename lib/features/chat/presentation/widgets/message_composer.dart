import 'dart:io';

import 'package:evdekimi_ai/design_system/chat_theme.dart';
import 'package:evdekimi_ai/design_system/glass.dart';
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

    // One continuous bar. Every control in it is the same size and sits on the
    // same centre line, and the gaps between them are one constant rather than
    // whatever each widget's default padding happened to be — which is what
    // produced the uneven spacing this replaces.
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          AppSpacing.sm,
          AppSpacing.md,
          AppSpacing.md,
        ),
        child: GlassSurface(
          cornerRadius: AppRadius.xxlValue,
          fallbackColor: chat.composerBackground,
          shadows: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.08),
              blurRadius: 20,
              offset: const Offset(0, 8),
            ),
          ],
          padding: const EdgeInsets.all(AppSpacing.sm),
          child: Column(
            children: [
              if (composer.hasAttachments)
                _AttachmentTray(conversationId: widget.conversationId),

              if (isListening)
                _DictationIndicator(level: speech?.soundLevel ?? 0),

              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  _ComposerAction(
                    icon: Icons.add_rounded,
                    tooltip: 'Attach an image',
                    isBusy: composer.isAttaching,
                    onTap: composer.isAttaching ? null : _showAttachSheet,
                  ),
                  const SizedBox(width: AppSpacing.xs),

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
                        style: context.texts.bodyMedium,
                        decoration: InputDecoration(
                          hintText: 'Message EVDEkimi…',
                          hintStyle: context.texts.bodyMedium?.copyWith(
                            color: context.colors.onSurfaceVariant,
                          ),
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          filled: false,
                          isDense: true,
                          // Centres the first line against the controls either
                          // side. Material's default vertical padding assumes a
                          // 48px field and pushes the text off that centre line.
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.sm,
                            vertical: 11,
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

                  const SizedBox(width: AppSpacing.xs),
                  _ComposerAction(
                    icon: isListening
                        ? Icons.mic_rounded
                        : Icons.mic_none_rounded,
                    tooltip: isListening ? 'Stop dictation' : 'Dictate',
                    color: isListening ? chat.danger : null,
                    onTap: _toggleDictation,
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
    return Tooltip(
      message: isGenerating ? 'Stop generating' : 'Send',
      child: AnimatedContainer(
        duration: AppDuration.fast,
        curve: AppCurve.standard,
        width: composerControlSize,
        height: composerControlSize,
        decoration: BoxDecoration(
          color: isGenerating
              ? chat.danger.withValues(alpha: 0.16)
              : isEnabled
              ? context.colors.primary
              : context.colors.onSurface.withValues(alpha: 0.08),
          // The same 12px corner as the attach and mic controls beside it, so
          // the row is three of one shape rather than two shapes and a circle.
          borderRadius: AppRadius.allMd,
        ),
        clipBehavior: Clip.antiAlias,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: isGenerating
                ? onStop
                : isEnabled
                ? onSend
                : null,
            child: Center(
              child: Icon(
                isGenerating ? Icons.stop_rounded : Icons.arrow_upward_rounded,
                size: AppSizes.iconMd,
                color: isGenerating
                    ? chat.danger
                    : isEnabled
                    ? context.colors.onPrimary
                    : context.colors.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Side of every control in the composer row.
///
/// One constant shared by the attach, dictate and send controls so they cannot
/// drift apart and leave the row looking assembled rather than designed.
const double composerControlSize = 40;

/// A flat icon tap in the composer, sized to match the send button exactly.
///
/// Deliberately not an `IconButton`. That widget reserves a 48px box regardless
/// of its glyph and centres a 24px icon inside it, so a row of them spaces
/// itself by each widget's internal padding rather than by the layout's — which
/// is where the composer's uneven gaps came from. Here the box and the glyph are
/// both explicit, which is the only way adjacent controls end up optically even.
class _ComposerAction extends StatelessWidget {
  const _ComposerAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.color,
    this.isBusy = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final Color? color;
  final bool isBusy;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        label: tooltip,
        child: Material(
          color: Colors.transparent,
          borderRadius: AppRadius.allMd,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: SizedBox(
              width: composerControlSize,
              height: composerControlSize,
              child: Center(
                child: isBusy
                    ? const SizedBox.square(
                        dimension: AppSizes.iconSm,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        icon,
                        size: AppSizes.iconMd,
                        color:
                            color ??
                            (onTap == null
                                ? context.colors.onSurface.withValues(
                                    alpha: 0.3,
                                  )
                                : context.colors.onSurfaceVariant),
                      ),
              ),
            ),
          ),
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
