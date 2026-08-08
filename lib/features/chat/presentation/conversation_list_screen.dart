import 'package:evdekimi_ai/app/routes.dart';
import 'package:evdekimi_ai/design_system/chat_theme.dart';
import 'package:evdekimi_ai/design_system/tokens.dart';
import 'package:evdekimi_ai/design_system/widgets/app_widgets.dart';
import 'package:evdekimi_ai/di/providers.dart';
import 'package:evdekimi_ai/features/ai/domain/model_descriptor.dart';
import 'package:evdekimi_ai/features/chat/domain/entities/conversation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

/// Home: every conversation stored on this device.
class ConversationListScreen extends ConsumerWidget {
  const ConversationListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conversationsAsync = ref.watch(conversationsProvider);
    final isOnline = ref.watch(isOnlineProvider);
    final pendingCount = ref.watch(pendingMessageCountProvider).value ?? 0;
    final user = ref.watch(currentUserProvider);

    return Scaffold(
      // This screen has no AppBar, and the app runs edge-to-edge, so nothing
      // else consumes the status-bar inset — without this the greeting renders
      // underneath the clock and battery icons.
      //
      // `bottom: false` on purpose: the floating navigation bar applies its own
      // bottom inset, and applying it twice would leave a visible gap.
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            OfflineBanner(isVisible: !isOnline, pendingCount: pendingCount),
            _GreetingHeader(
              name: user?.friendlyName,
              initials: user?.initials ?? '?',
              // `go`, not `push`: these are tabs in the shell, so switching
              // branches is correct — pushing would stack a second copy on top
              // of the tab that already exists.
              onOpenSettings: () => context.go(AppRoutes.settings),
            ),
            _SearchPrompt(onTap: () => context.go(AppRoutes.search)),
            Expanded(
              child: conversationsAsync.when(
                loading: () => const SkeletonList(),
                error: (error, _) => EmptyStateView(
                  icon: Icons.error_outline_rounded,
                  title: "Couldn't load conversations",
                  message: '$error',
                  actionLabel: 'Retry',
                  onAction: () => ref.invalidate(conversationsProvider),
                ),
                data: (conversations) => conversations.isEmpty
                    ? EmptyStateView(
                        icon: Icons.forum_outlined,
                        title: 'No conversations yet',
                        message:
                            'Start a chat. Everything is saved on this device '
                            'and keeps working offline.',
                        actionLabel: 'New chat',
                        onAction: () => startNewConversation(context, ref),
                      )
                    : _ConversationList(conversations: conversations),
              ),
            ),
          ],
        ),
      ),
      // No FloatingActionButton: the shell's navigation bar owns the primary
      // action, and two "new chat" affordances on one screen is one too many.
    );
  }
}

/// Creates a thread and opens it.
///
/// Top-level rather than private to the screen because the shell's navigation
/// bar is the primary entry point for it, and the empty state is a secondary one.
///
/// The model comes from settings, falling back to the on-device model when the
/// device is offline and the user has allowed that — so a new chat started on a
/// plane is immediately usable rather than dead.
Future<void> startNewConversation(BuildContext context, WidgetRef ref) async {
  final settings = ref.read(settingsControllerProvider);
  final isOnline = ref.read(isOnlineProvider);
  final onDeviceReady = await ref.read(onDeviceAvailableProvider.future);

  final useOnDevice =
      settings.preferredEngine.isOnDevice ||
      (!isOnline && settings.useOnDeviceWhenOffline && onDeviceReady);

  final result = await ref
      .read(conversationRepositoryProvider)
      .createConversation(
        modelId: useOnDevice
            ? KnownModels.onDeviceRouter
            : settings.selectedModelId,
        engine: useOnDevice ? EngineKind.onDevice : EngineKind.remote,
      );

  if (!context.mounted) return;
  result.fold(
    ok: (conversation) => context.push(AppRoutes.chatPath(conversation.id)),
    err: (failure) =>
        showAppSnackBar(context, failure.userMessage, isError: true),
  );
}

/// Time-aware greeting with the user's avatar.
///
/// Replaces a generic "Conversations" app bar. The screen is the app's home, and
/// a personal header reads as arrival rather than as a list view — the same move
/// the reference designs make.
class _GreetingHeader extends StatelessWidget {
  const _GreetingHeader({
    required this.name,
    required this.initials,
    required this.onOpenSettings,
  });

  final String? name;
  final String initials;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.gutter,
        AppSpacing.md,
        AppSpacing.gutter,
        AppSpacing.lg,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _greeting(),
                  style: context.texts.bodySmall?.copyWith(
                    color: context.colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: AppSpacing.xxs),
                Text(
                  name ?? 'Welcome back',
                  style: context.texts.headlineSmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          GestureDetector(
            onTap: onOpenSettings,
            child: Semantics(
              button: true,
              label: 'Settings',
              child: AppAvatar(label: initials, size: 44),
            ),
          ),
        ],
      ),
    );
  }

  static String _greeting() {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Good morning';
    if (hour < 17) return 'Good afternoon';
    return 'Good evening';
  }
}

/// A tappable field that looks like search but opens the search screen.
///
/// Not a real input: search runs on-device embeddings and deserves its own
/// screen, but a plain icon in an app bar hides the app's most distinctive
/// feature. This advertises it.
class _SearchPrompt extends StatelessWidget {
  const _SearchPrompt({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final chat = context.chatTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.gutter,
        0,
        AppSpacing.gutter,
        AppSpacing.lg,
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: AppRadius.allPill,
        child: Container(
          height: AppSizes.minTapTarget,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
          decoration: BoxDecoration(
            color: context.colors.surfaceContainerLowest,
            borderRadius: AppRadius.allPill,
            border: Border.all(color: context.colors.outlineVariant),
          ),
          child: Row(
            children: [
              Icon(
                Icons.search_rounded,
                size: AppSizes.iconMd,
                color: context.colors.onSurfaceVariant,
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Text(
                  'Search your history',
                  style: context.texts.bodyMedium?.copyWith(
                    color: context.colors.onSurfaceVariant,
                  ),
                ),
              ),
              AppBadge(
                label: 'On-device',
                icon: Icons.memory_rounded,
                color: chat.onDeviceAccent,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ConversationList extends ConsumerWidget {
  const _ConversationList({required this.conversations});

  final List<Conversation> conversations;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Cards on the canvas rather than tiles separated by rules: each thread is a
    // discrete object, and the tonal step does the separating so no divider is
    // needed.
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.gutter,
        0,
        AppSpacing.gutter,
        AppSpacing.xxxl * 2,
      ),
      itemCount: conversations.length,
      separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.md),
      itemBuilder: (context, index) {
        final conversation = conversations[index];
        return _ConversationTile(conversation: conversation);
      },
    );
  }
}

class _ConversationTile extends ConsumerWidget {
  const _ConversationTile({required this.conversation});

  final Conversation conversation;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Dismissible(
      key: ValueKey('dismiss-${conversation.id}'),
      direction: DismissDirection.endToStart,
      background: DecoratedBox(
        decoration: BoxDecoration(
          color: context.chatTheme.danger.withValues(alpha: 0.15),
          borderRadius: AppRadius.allLg,
        ),
        child: Padding(
          padding: const EdgeInsets.only(right: AppSpacing.gutter),
          child: Align(
            alignment: Alignment.centerRight,
            child: Icon(
              Icons.delete_outline_rounded,
              color: context.chatTheme.danger,
            ),
          ),
        ),
      ),
      // Confirm before deleting: a swipe is easy to trigger by accident while
      // scrolling, and a conversation is not trivially recoverable from the UI.
      confirmDismiss: (_) => showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Delete conversation?'),
          content: Text(
            'This removes "${conversation.title}" from this device.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(
                'Delete',
                style: TextStyle(color: context.chatTheme.danger),
              ),
            ),
          ],
        ),
      ),
      onDismissed: (_) => ref
          .read(conversationRepositoryProvider)
          .deleteConversation(conversation.id),
      child: Material(
        color: context.colors.surfaceContainerLowest,
        borderRadius: AppRadius.allLg,
        clipBehavior: Clip.antiAlias,
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.sm,
          ),
          shape: const RoundedRectangleBorder(borderRadius: AppRadius.allLg),
          onTap: () => context.push(AppRoutes.chatPath(conversation.id)),
          leading: AppAvatar(
            label: 'AI',
            isAssistant: true,
            isOnDevice: conversation.engine.isOnDevice,
          ),
          title: Row(
            children: [
              if (conversation.isPinned)
                const Padding(
                  padding: EdgeInsets.only(right: AppSpacing.xs),
                  child: Icon(Icons.push_pin_rounded, size: 13),
                ),
              Expanded(
                child: Text(
                  conversation.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.texts.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          subtitle: conversation.lastMessagePreview == null
              ? Text(
                  conversation.engine.isOnDevice
                      ? 'On-device'
                      : 'No messages yet',
                )
              : Text(
                  conversation.lastMessagePreview!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
          trailing: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                _formatTimestamp(conversation.updatedAt),
                style: context.texts.labelSmall?.copyWith(
                  color: context.colors.onSurfaceVariant,
                ),
              ),
              if (conversation.engine.isOnDevice)
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.xs),
                  child: Icon(
                    Icons.memory_rounded,
                    size: 13,
                    color: context.chatTheme.onDeviceAccent,
                  ),
                ),
            ],
          ),
          onLongPress: () => _showActions(context, ref),
        ),
      ),
    );
  }

  Future<void> _showActions(BuildContext context, WidgetRef ref) async {
    final repository = ref.read(conversationRepositoryProvider);
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(
                conversation.isPinned
                    ? Icons.push_pin_outlined
                    : Icons.push_pin_rounded,
              ),
              title: Text(conversation.isPinned ? 'Unpin' : 'Pin to top'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                repository.setPinned(
                  conversation.id,
                  isPinned: !conversation.isPinned,
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.archive_outlined),
              title: Text(conversation.isArchived ? 'Unarchive' : 'Archive'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                repository.setArchived(
                  conversation.id,
                  isArchived: !conversation.isArchived,
                );
              },
            ),
            const SizedBox(height: AppSpacing.sm),
          ],
        ),
      ),
    );
  }

  /// Relative for recent activity, absolute once it stops being "recent".
  static String _formatTimestamp(DateTime timestamp) {
    final local = timestamp.toLocal();
    final now = DateTime.now();
    final difference = now.difference(local);

    if (difference.inMinutes < 1) return 'now';
    if (difference.inMinutes < 60) return '${difference.inMinutes}m';
    if (difference.inHours < 24) return '${difference.inHours}h';
    if (difference.inDays < 7) return '${difference.inDays}d';
    return DateFormat('d MMM').format(local);
  }
}
