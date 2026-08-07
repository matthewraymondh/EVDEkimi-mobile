/// Shared presentation widgets.
///
/// These exist so the same state never gets two different treatments across
/// screens: one empty state, one error view, one loading shimmer. Every one takes
/// its colours from `ColorScheme`/`ChatTheme`, so none of them can look wrong in
/// dark mode.
library;

import 'dart:math' as math;

import 'package:evdekimi_ai/core/error/failure.dart';
import 'package:evdekimi_ai/design_system/chat_theme.dart';
import 'package:evdekimi_ai/design_system/tokens.dart';
import 'package:flutter/material.dart';

/// A slim banner shown while the device has no usable connection.
///
/// Deliberately reassuring rather than alarming: the app keeps working offline,
/// so the banner explains what will happen rather than warning about failure.
class OfflineBanner extends StatelessWidget {
  const OfflineBanner({
    required this.isVisible,
    this.pendingCount = 0,
    super.key,
  });

  final bool isVisible;

  /// Messages waiting in the outbox, surfaced so the user knows nothing is lost.
  final int pendingCount;

  @override
  Widget build(BuildContext context) {
    final chat = context.chatTheme;

    // AnimatedSize + AnimatedSwitcher so appearing/disappearing does not make
    // the transcript jump.
    return AnimatedSize(
      duration: AppDuration.medium,
      curve: AppCurve.standard,
      alignment: Alignment.topCenter,
      child: isVisible
          ? Semantics(
              liveRegion: true,
              child: Container(
                width: double.infinity,
                color: chat.offlineBanner,
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.gutter,
                  vertical: AppSpacing.sm,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.cloud_off_rounded,
                      size: AppSizes.iconSm,
                      color: chat.onOfflineBanner,
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(
                        pendingCount > 0
                            ? "Offline · $pendingCount message${pendingCount == 1 ? '' : 's'} will send automatically"
                            : 'Offline · messages are saved and sent automatically',
                        style: context.texts.bodySmall?.copyWith(
                          color: chat.onOfflineBanner,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            )
          : const SizedBox.shrink(),
    );
  }
}

/// Full-screen empty state with an optional call to action.
class EmptyStateView extends StatelessWidget {
  const EmptyStateView({
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
    super.key,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(AppSpacing.lg),
                decoration: BoxDecoration(
                  color: context.colors.surfaceContainerHigh,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  icon,
                  size: AppSizes.iconLg,
                  color: context.colors.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              Text(
                title,
                textAlign: TextAlign.center,
                style: context.texts.titleMedium,
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                message,
                textAlign: TextAlign.center,
                style: context.texts.bodyMedium?.copyWith(
                  color: context.colors.onSurfaceVariant,
                ),
              ),
              if (actionLabel != null && onAction != null) ...[
                const SizedBox(height: AppSpacing.xl),
                FilledButton(onPressed: onAction, child: Text(actionLabel!)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Renders a [Failure] with a retry affordance when the failure allows it.
///
/// Takes the domain failure rather than a string so the retry button appears
/// exactly when `isRetryable` says it should — the decision lives in the domain,
/// not in each screen.
class FailureView extends StatelessWidget {
  const FailureView({required this.failure, this.onRetry, super.key});

  final Failure failure;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final chat = context.chatTheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                switch (failure) {
                  NetworkFailure() => Icons.wifi_off_rounded,
                  AuthFailure() => Icons.lock_outline_rounded,
                  InferenceFailure() => Icons.memory_rounded,
                  _ => Icons.error_outline_rounded,
                },
                size: AppSizes.iconLg,
                color: chat.danger,
              ),
              const SizedBox(height: AppSpacing.lg),
              Text(
                failure.userMessage,
                textAlign: TextAlign.center,
                style: context.texts.bodyMedium,
              ),
              if (failure.isRetryable && onRetry != null) ...[
                const SizedBox(height: AppSpacing.lg),
                OutlinedButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(
                    Icons.refresh_rounded,
                    size: AppSizes.iconSm,
                  ),
                  label: const Text('Try again'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A monogram avatar for the user or the assistant.
class AppAvatar extends StatelessWidget {
  const AppAvatar({
    required this.label,
    this.size = AppSizes.avatarMd,
    this.isAssistant = false,
    this.isOnDevice = false,
    super.key,
  });

  final String label;
  final double size;
  final bool isAssistant;

  /// Tints the assistant avatar when the reply came from the local model, so the
  /// engine is visible at a glance rather than buried in a menu.
  final bool isOnDevice;

  @override
  Widget build(BuildContext context) {
    final chat = context.chatTheme;
    final background = isAssistant
        ? (isOnDevice
              ? chat.onDeviceAccent.withValues(alpha: 0.18)
              : context.colors.primary.withValues(alpha: 0.16))
        : context.colors.surfaceContainerHigh;

    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: background, shape: BoxShape.circle),
      child: isAssistant
          ? Icon(
              isOnDevice ? Icons.memory_rounded : Icons.auto_awesome_rounded,
              size: size * 0.55,
              color: isOnDevice ? chat.onDeviceAccent : context.colors.primary,
            )
          : Text(
              label,
              style: context.texts.labelSmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: context.colors.onSurfaceVariant,
              ),
            ),
    );
  }
}

/// Three-dot indicator shown before the first token arrives.
class TypingIndicator extends StatefulWidget {
  const TypingIndicator({this.label, super.key});

  /// Optional engine status text ("Running on-device model…").
  final String? label;

  @override
  State<TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<TypingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: AppDuration.typingCycle,
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = context.colors.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedBuilder(
          animation: _controller,
          builder: (context, _) => Row(
            mainAxisSize: MainAxisSize.min,
            children: List.generate(3, (index) {
              // Stagger each dot by a third of the cycle.
              final phase = (_controller.value + index / 3) % 1.0;
              final scale = 0.6 + 0.4 * math.sin(phase * math.pi * 2).abs();
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Transform.scale(
                  scale: scale,
                  child: Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.35 + 0.45 * scale),
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
        if (widget.label case final String label) ...[
          const SizedBox(width: AppSpacing.sm),
          Text(label, style: context.texts.bodySmall?.copyWith(color: color)),
        ],
      ],
    );
  }
}

/// A blinking caret appended to text that is still streaming.
class StreamingCaret extends StatefulWidget {
  const StreamingCaret({super.key});

  @override
  State<StreamingCaret> createState() => _StreamingCaretState();
}

class _StreamingCaretState extends State<StreamingCaret>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: AppDuration.caretBlink,
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: _controller,
    child: Container(
      width: 2,
      height: 15,
      margin: const EdgeInsets.only(left: 2),
      color: context.chatTheme.caret,
    ),
  );
}

/// Placeholder rows shown while the first query resolves.
class SkeletonList extends StatelessWidget {
  const SkeletonList({this.itemCount = 5, super.key});

  final int itemCount;

  @override
  Widget build(BuildContext context) {
    final chat = context.chatTheme;
    return ListView.separated(
      padding: const EdgeInsets.all(AppSpacing.gutter),
      itemCount: itemCount,
      separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.lg),
      itemBuilder: (context, index) => Row(
        children: [
          Container(
            width: AppSizes.avatarMd,
            height: AppSizes.avatarMd,
            decoration: BoxDecoration(
              color: chat.skeletonBase,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _SkeletonBar(width: double.infinity, color: chat.skeletonBase),
                const SizedBox(height: AppSpacing.sm),
                _SkeletonBar(width: 180, color: chat.skeletonHighlight),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SkeletonBar extends StatelessWidget {
  const _SkeletonBar({required this.width, required this.color});

  final double width;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: width,
    height: 12,
    decoration: BoxDecoration(color: color, borderRadius: AppRadius.allXs),
  );
}

/// A small labelled pill, used for model and engine badges.
class AppBadge extends StatelessWidget {
  const AppBadge({
    required this.label,
    this.icon,
    this.color,
    this.onTap,
    super.key,
  });

  final String label;
  final IconData? icon;
  final Color? color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final resolved = color ?? context.colors.onSurfaceVariant;
    final content = Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xxs,
      ),
      decoration: BoxDecoration(
        color: resolved.withValues(alpha: 0.12),
        borderRadius: AppRadius.allPill,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: resolved),
            const SizedBox(width: AppSpacing.xs),
          ],
          Text(
            label,
            style: context.texts.labelSmall?.copyWith(
              color: resolved,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );

    if (onTap == null) return content;
    return InkWell(
      onTap: onTap,
      borderRadius: AppRadius.allPill,
      child: content,
    );
  }
}

/// Shows [message] as a snack bar, replacing any current one.
void showAppSnackBar(
  BuildContext context,
  String message, {
  bool isError = false,
}) {
  final messenger = ScaffoldMessenger.of(context)..hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      content: Text(message),
      backgroundColor: isError ? context.chatTheme.danger : null,
    ),
  );
}
