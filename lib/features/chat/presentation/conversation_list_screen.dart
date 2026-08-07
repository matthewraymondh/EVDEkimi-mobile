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
      appBar: AppBar(
        title: const Text('Conversations'),
        actions: [
          IconButton(
            onPressed: () => context.push(AppRoutes.search),
            tooltip: 'Search your history (on-device)',
            icon: const Icon(Icons.search_rounded),
          ),
          IconButton(
            onPressed: () => context.push(AppRoutes.settings),
            tooltip: 'Settings',
            icon: user == null
                ? const Icon(Icons.settings_outlined)
                : AppAvatar(label: user.initials, size: AppSizes.avatarSm),
          ),
        ],
      ),
      body: Column(
        children: [
          OfflineBanner(isVisible: !isOnline, pendingCount: pendingCount),
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
                          'Start a chat. Everything is saved on this device and '
                          'keeps working offline.',
                      actionLabel: 'New chat',
                      onAction: () => _startConversation(context, ref),
                    )
                  : _ConversationList(conversations: conversations),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _startConversation(context, ref),
        icon: const Icon(Icons.add_rounded),
        label: const Text('New chat'),
      ),
    );
  }

  /// Creates a thread and opens it.
  ///
  /// The model comes from settings, falling back to the on-device model when the
  /// device is offline and the user has allowed that — so a new chat started on a
  /// plane is immediately usable rather than dead.
  static Future<void> _startConversation(
    BuildContext context,
    WidgetRef ref,
  ) async {
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
}

class _ConversationList extends ConsumerWidget {
  const _ConversationList({required this.conversations});

  final List<Conversation> conversations;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListView.separated(
      padding: const EdgeInsets.only(bottom: AppSpacing.xxxl * 2),
      itemCount: conversations.length,
      separatorBuilder: (_, _) => Divider(
        height: 1,
        indent: AppSpacing.gutter,
        endIndent: AppSpacing.gutter,
        color: context.colors.outlineVariant,
      ),
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
      background: ColoredBox(
        color: context.chatTheme.danger.withValues(alpha: 0.15),
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
      child: ListTile(
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
