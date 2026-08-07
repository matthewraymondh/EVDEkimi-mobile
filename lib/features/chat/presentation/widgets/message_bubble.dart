import 'dart:io';

import 'package:evdekimi_ai/design_system/app_theme.dart';
import 'package:evdekimi_ai/design_system/chat_theme.dart';
import 'package:evdekimi_ai/design_system/tokens.dart';
import 'package:evdekimi_ai/design_system/widgets/app_widgets.dart';
import 'package:evdekimi_ai/features/chat/domain/entities/message.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

/// One message in the transcript.
///
/// The assistant side renders Markdown (LLMs emit it constantly, and showing raw
/// `**bold**` and un-highlighted code blocks is the single most obvious tell of a
/// rushed chat UI). The user side stays plain text: echoing a user's own
/// characters back to them as formatting would be surprising and, with code
/// snippets, actively wrong.
class MessageBubble extends StatelessWidget {
  const MessageBubble({
    required this.message,
    this.onRetry,
    this.onRegenerate,
    this.statusLabel,
    super.key,
  });

  final Message message;
  final VoidCallback? onRetry;
  final VoidCallback? onRegenerate;

  /// Engine progress note shown before the first token ("Running on-device…").
  final String? statusLabel;

  @override
  Widget build(BuildContext context) {
    final isUser = message.isFromUser;

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.gutter,
        vertical: AppSpacing.sm,
      ),
      child: Row(
        mainAxisAlignment: isUser
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isUser) ...[
            AppAvatar(
              label: 'AI',
              isAssistant: true,
              isOnDevice: message.engine?.isOnDevice ?? false,
            ),
            const SizedBox(width: AppSpacing.sm),
          ],
          Flexible(
            child: Column(
              crossAxisAlignment: isUser
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              children: [
                _Bubble(message: message, statusLabel: statusLabel),
                _Footer(
                  message: message,
                  onRetry: onRetry,
                  onRegenerate: onRegenerate,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, this.statusLabel});

  final Message message;
  final String? statusLabel;

  @override
  Widget build(BuildContext context) {
    final chat = context.chatTheme;
    final isUser = message.isFromUser;

    final background = isUser ? chat.outgoingBubble : chat.incomingBubble;
    final foreground = isUser ? chat.onOutgoingBubble : chat.onIncomingBubble;

    return ConstrainedBox(
      // Cap the width so long answers form a readable column instead of running
      // edge to edge on a tablet.
      constraints: const BoxConstraints(
        maxWidth: AppSpacing.readableMaxWidth * 0.78,
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.md,
        ),
        decoration: BoxDecoration(
          color: background,
          borderRadius: isUser
              ? AppRadius.bubbleOutgoing
              : AppRadius.bubbleIncoming,
          border: isUser ? null : Border.all(color: chat.bubbleBorder),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (message.hasAttachments)
              _AttachmentStrip(attachments: message.attachments),

            if (message.isAwaitingFirstToken)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.xxs),
                child: TypingIndicator(label: statusLabel),
              )
            else if (message.hasContent)
              _MessageText(message: message, foreground: foreground),

            if (message.status == MessageStatus.failed &&
                message.errorMessage != null)
              _ErrorNote(message: message.errorMessage!),
          ],
        ),
      ),
    );
  }
}

class _MessageText extends StatelessWidget {
  const _MessageText({required this.message, required this.foreground});

  final Message message;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    final baseStyle = context.texts.bodyLarge?.copyWith(color: foreground);
    final isStreaming = message.status == MessageStatus.streaming;

    if (message.isFromUser) {
      return SelectableText(message.content, style: baseStyle);
    }

    // Wrap in a Column so the caret can sit under the last line without being
    // injected into the Markdown source (which would corrupt code fences).
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GptMarkdown(
          message.content,
          style: baseStyle,
          codeBuilder: (context, name, code, closed) =>
              _CodeBlock(language: name, code: code),
          onLinkTap: (url, title) => _openLink(context, url),
        ),
        if (isStreaming)
          const Align(alignment: Alignment.centerLeft, child: StreamingCaret()),
      ],
    );
  }

  static void _openLink(BuildContext context, String url) {
    // Deliberately not launching a browser: url_launcher is not a dependency and
    // silently opening an LLM-supplied URL is a phishing vector. Copying puts the
    // user in control of what happens next.
    Clipboard.setData(ClipboardData(text: url));
    showAppSnackBar(context, 'Link copied: $url');
  }
}

/// A syntax-chrome code block with a copy button.
class _CodeBlock extends StatelessWidget {
  const _CodeBlock({required this.language, required this.code});

  final String language;
  final String code;

  @override
  Widget build(BuildContext context) {
    final chat = context.chatTheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      decoration: BoxDecoration(
        color: chat.codeBackground,
        borderRadius: AppRadius.allSm,
        border: Border.all(color: chat.codeBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(
              left: AppSpacing.md,
              top: AppSpacing.xs,
              right: AppSpacing.xs,
            ),
            child: Row(
              children: [
                Text(
                  language.isEmpty ? 'code' : language,
                  style: context.texts.labelSmall?.copyWith(
                    color: AppPaletteRef.codeLabel,
                    letterSpacing: 0.6,
                  ),
                ),
                const Spacer(),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  iconSize: AppSizes.iconSm,
                  tooltip: 'Copy code',
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: code));
                    showAppSnackBar(context, 'Code copied');
                  },
                  icon: const Icon(
                    Icons.content_copy_rounded,
                    color: AppPaletteRef.codeLabel,
                  ),
                ),
              ],
            ),
          ),
          // Code must scroll rather than wrap: a wrapped line changes the meaning
          // of indentation-sensitive languages.
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              0,
              AppSpacing.md,
              AppSpacing.md,
            ),
            child: SelectableText(
              code,
              style: context.texts.bodySmall?.copyWith(
                fontFamily: AppTheme.monospaceFallback.first,
                fontFamilyFallback: AppTheme.monospaceFallback,
                color: AppPaletteRef.codeText,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Code chrome is always dark in both themes, so these two are fixed.
abstract final class AppPaletteRef {
  static const Color codeLabel = Color(0xFF8FA5A0);
  static const Color codeText = Color(0xFFE4EDEA);
}

class _AttachmentStrip extends StatelessWidget {
  const _AttachmentStrip({required this.attachments});

  final List<Attachment> attachments;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: attachments
                .map((attachment) => _AttachmentThumb(attachment: attachment))
                .toList(growable: false),
          ),
          // Surfacing the OCR result is what makes the feature legible: the user
          // can see that the text was read on-device and is part of the prompt.
          for (final attachment in attachments)
            if (attachment.hasExtractedText)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.sm),
                child: AppBadge(
                  label:
                      'Text recognised on-device · '
                      '${attachment.extractedText!.length} chars',
                  icon: Icons.document_scanner_outlined,
                  color: context.chatTheme.onDeviceAccent,
                ),
              ),
        ],
      ),
    );
  }
}

class _AttachmentThumb extends StatelessWidget {
  const _AttachmentThumb({required this.attachment});

  final Attachment attachment;

  @override
  Widget build(BuildContext context) {
    final source = attachment.displaySource;
    return ClipRRect(
      borderRadius: AppRadius.allSm,
      child: SizedBox(
        width: 132,
        height: 132,
        child: source == null
            ? ColoredBox(color: context.colors.surfaceContainerHigh)
            : _buildImage(context, source),
      ),
    );
  }

  Widget _buildImage(BuildContext context, String source) {
    // Prefer the local file: it is already on disk, needs no network, and stays
    // visible while the upload is still pending.
    if (attachment.localPath != null &&
        File(attachment.localPath!).existsSync()) {
      return Image.file(File(attachment.localPath!), fit: BoxFit.cover);
    }
    return Image.network(
      source,
      fit: BoxFit.cover,
      errorBuilder: (context, _, _) => ColoredBox(
        color: context.colors.surfaceContainerHigh,
        child: const Center(child: Icon(Icons.broken_image_outlined)),
      ),
    );
  }
}

class _ErrorNote extends StatelessWidget {
  const _ErrorNote({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.error_outline_rounded,
            size: 14,
            color: context.chatTheme.danger,
          ),
          const SizedBox(width: AppSpacing.xs),
          Expanded(
            child: Text(
              message,
              style: context.texts.bodySmall?.copyWith(
                color: context.chatTheme.danger,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Metadata row: status, engine, latency, and the actions for this message.
class _Footer extends StatelessWidget {
  const _Footer({required this.message, this.onRetry, this.onRegenerate});

  final Message message;
  final VoidCallback? onRetry;
  final VoidCallback? onRegenerate;

  @override
  Widget build(BuildContext context) {
    final chat = context.chatTheme;
    final items = <Widget>[];

    if (message.status == MessageStatus.queued) {
      items.add(
        AppBadge(
          label: 'Queued',
          icon: Icons.schedule_rounded,
          color: chat.warning,
        ),
      );
    }

    if (message.status == MessageStatus.cancelled) {
      items.add(
        const AppBadge(label: 'Stopped', icon: Icons.stop_circle_outlined),
      );
    }

    if (message.isFromAssistant &&
        message.engine != null &&
        message.status == MessageStatus.complete) {
      items.add(
        AppBadge(
          label: message.engine!.isOnDevice ? 'On-device' : 'Cloud',
          icon: message.engine!.isOnDevice
              ? Icons.memory_rounded
              : Icons.cloud_outlined,
          color: message.engine!.isOnDevice ? chat.onDeviceAccent : null,
        ),
      );
      if (message.latency case final Duration latency) {
        items.add(
          Text(
            '${(latency.inMilliseconds / 1000).toStringAsFixed(1)}s',
            style: context.texts.labelSmall?.copyWith(
              color: context.colors.onSurfaceVariant,
            ),
          ),
        );
      }
    }

    if (message.status.canRetry && onRetry != null) {
      items.add(
        _FooterAction(
          icon: Icons.refresh_rounded,
          label: 'Retry',
          onPressed: onRetry!,
        ),
      );
    }

    if (message.isFromAssistant &&
        message.status.isTerminal &&
        onRegenerate != null) {
      items.add(
        _FooterAction(
          icon: Icons.autorenew_rounded,
          label: 'Regenerate',
          onPressed: onRegenerate!,
        ),
      );
      if (message.hasContent) {
        items.add(
          _FooterAction(
            icon: Icons.content_copy_rounded,
            label: 'Copy',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: message.content));
              showAppSnackBar(context, 'Copied');
            },
          ),
        );
      }
    }

    if (items.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.xs),
      child: Wrap(
        spacing: AppSpacing.sm,
        runSpacing: AppSpacing.xs,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: items,
      ),
    );
  }
}

class _FooterAction extends StatelessWidget {
  const _FooterAction({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onPressed,
      borderRadius: AppRadius.allXs,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.xs,
          vertical: 2,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: context.colors.onSurfaceVariant),
            const SizedBox(width: AppSpacing.xs),
            Text(
              label,
              style: context.texts.labelSmall?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
