import 'package:evdekimi_ai/app/routes.dart';
import 'package:evdekimi_ai/core/text/markdown_text.dart';
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
            // `push`, not `go`: search is no longer a tab, so it belongs on top
            // of this screen with a back button rather than replacing it.
            _SearchPrompt(onTap: () => context.push(AppRoutes.search)),
            Expanded(
              child: conversationsAsync.when(
                loading: () => const SkeletonList.grouped(),
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

  // Only a standing preference pins a conversation to the local model. Being
  // offline right now does not, and used to: a chat started in airplane mode
  // was written with the on-device model *stored on the row*, so it stayed
  // there after reconnecting. Asking it to book a viewing then refused
  // forever, because every retry routed back to the engine that had just said
  // no, and the refusal reads as a deliberate choice the user never made.
  //
  // A conversation's model is what it is *for*. Which engine actually answers
  // a given message is a question about what is reachable at that moment, and
  // `EngineRouter` already decides it per message — falling back to on-device
  // while offline and leaving the message queued for a cloud engine after.
  final useOnDevice = settings.preferredEngine.isOnDevice;

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

/// Time-aware greeting with the account control.
///
/// Replaces a generic "Conversations" app bar. The screen is the app's home, and
/// a personal header reads as arrival rather than as a list view.
///
/// The greeting outranks the account name, which is the inversion of where this
/// started. The name was set in display type — the most prominent typography on
/// the screen given to a string the user already knows and cannot act on.
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
        AppSpacing.sm,
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
                  style: context.texts.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.4,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (name != null) ...[
                  const SizedBox(height: 1),
                  Text(
                    name!,
                    style: context.texts.bodySmall?.copyWith(
                      color: context.colors.onSurfaceVariant,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          _AvatarButton(initials: initials, onTap: onOpenSettings),
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

/// The account control, which opens Settings.
///
/// Stripped back to a monogram on a flat tint. It previously carried a ring, a
/// fill and a shape of its own, which made a 42px square the most decorated
/// object in the header while being the least important thing in it.
class _AvatarButton extends StatelessWidget {
  const _AvatarButton({required this.initials, required this.onTap});

  final String initials;
  final VoidCallback onTap;

  static const double _size = 38;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Settings',
      child: Material(
        color: context.colors.onSurface.withValues(alpha: 0.06),
        borderRadius: AppRadius.allMd,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            width: _size,
            height: _size,
            child: Center(
              child: Text(
                initials,
                style: context.texts.labelMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: context.colors.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A tappable field that looks like search but opens the search screen.
///
/// Not a real input: search runs on-device embeddings and deserves its own
/// screen, but a plain icon in an app bar hides the app's most distinctive
/// feature. This advertises it.
///
/// Flat rather than glass, and a tint rather than a stroke. Chrome that floats
/// gets glass; a field sitting *in* the page gets a 6% wash of the foreground
/// colour, which is one rule for both themes and needs no border to be legible.
class _SearchPrompt extends StatelessWidget {
  const _SearchPrompt({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.gutter,
        0,
        AppSpacing.gutter,
        AppSpacing.lg,
      ),
      child: Material(
        color: context.colors.onSurface.withValues(alpha: 0.06),
        borderRadius: AppRadius.allMd,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.lg,
              vertical: AppSpacing.md,
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
                // The same chip glyph the rows and message footers use. A
                // lightning bolt was quieter but meant nothing on its own —
                // reusing one mark for "this runs on your device" is what lets
                // it be learned once and recognised everywhere.
                Icon(
                  Icons.memory_rounded,
                  size: AppSizes.iconSm,
                  color: context.chatTheme.onDeviceAccent,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- the list

/// One row of the flattened list: either a date heading or a thread.
///
/// Flattened rather than nested so the whole list stays a single
/// `ListView.builder` and keeps its lazy building. A `Column` of groups inside a
/// scroll view would build every row on every frame.
sealed class _Entry {
  const _Entry();
}

final class _SectionEntry extends _Entry {
  const _SectionEntry(this.label);
  final String label;
}

final class _ThreadEntry extends _Entry {
  const _ThreadEntry({
    required this.conversation,
    required this.isFirst,
    required this.isLast,
  });

  final Conversation conversation;

  /// Position within its group, which decides which corners are rounded.
  final bool isFirst;
  final bool isLast;
}

class _ConversationList extends ConsumerWidget {
  const _ConversationList({required this.conversations});

  final List<Conversation> conversations;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entries = _flatten(conversations, DateTime.now());

    return ListView.builder(
      padding: EdgeInsets.only(bottom: AppSizes.navBarInset(context)),
      itemCount: entries.length,
      itemBuilder: (context, index) => switch (entries[index]) {
        _SectionEntry(:final label) => _SectionHeading(label: label),
        _ThreadEntry(:final conversation, :final isFirst, :final isLast) =>
          _ConversationTile(
            key: ValueKey(conversation.id),
            conversation: conversation,
            isFirst: isFirst,
            isLast: isLast,
          ),
      },
    );
  }

  /// Groups by recency, preserving the incoming order.
  ///
  /// The DAO already returns pinned-first then newest-first, so contiguous runs
  /// of the same bucket fall out of a single pass — no sorting here, which would
  /// only risk disagreeing with the query.
  static List<_Entry> _flatten(List<Conversation> conversations, DateTime now) {
    final entries = <_Entry>[];
    String? section;

    for (var index = 0; index < conversations.length; index++) {
      final conversation = conversations[index];
      final label = _sectionFor(conversation, now);

      if (label != section) {
        entries.add(_SectionEntry(label));
        section = label;
      }

      final next = index + 1 < conversations.length
          ? conversations[index + 1]
          : null;

      entries.add(
        _ThreadEntry(
          conversation: conversation,
          // Safe because a heading was just appended if this starts a group.
          isFirst: entries.last is _SectionEntry,
          isLast: next == null || _sectionFor(next, now) != label,
        ),
      );
    }

    return entries;
  }

  /// Which heading a conversation belongs under.
  ///
  /// Pinned threads get their own group instead of an icon on the row. The
  /// heading says it once for the whole set, which is both quieter and clearer
  /// than repeating a pin glyph next to every title.
  static String _sectionFor(Conversation conversation, DateTime now) {
    if (conversation.isPinned) return 'Pinned';

    final day = DateUtils.dateOnly(conversation.updatedAt.toLocal());
    final days = DateUtils.dateOnly(now).difference(day).inDays;

    return switch (days) {
      <= 0 => 'Today',
      1 => 'Yesterday',
      < 7 => 'Earlier this week',
      < 30 => 'Earlier this month',
      _ => 'Older',
    };
  }
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.gutter + AppSpacing.xs,
        AppSpacing.lg,
        AppSpacing.gutter,
        AppSpacing.sm,
      ),
      child: Text(
        label.toUpperCase(),
        style: context.texts.labelSmall?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: 0.9,
          color: context.colors.onSurfaceVariant.withValues(alpha: 0.75),
        ),
      ),
    );
  }
}

/// One thread, as a row inside a grouped card.
///
/// Two changes from the first version are worth naming, because both were what
/// made the list read as generated rather than designed:
///
/// * **No leading avatar.** Every row carried an identical circle with an
///   identical sparkle in it. Every conversation in this app is with the
///   assistant, so the glyph distinguished nothing — five copies of the same
///   mark down the left edge, costing a third of the row width to say something
///   the screen already says. Engine is the only genuine per-row difference, and
///   it now shows only on the rows where it is true.
/// * **Grouped, not floating.** Separate cards with gaps between them made five
///   threads occupy a whole screen. One card per date group with hairlines
///   between rows is denser, and the grouping carries information the gaps did
///   not.
class _ConversationTile extends ConsumerWidget {
  const _ConversationTile({
    required this.conversation,
    required this.isFirst,
    required this.isLast,
    super.key,
  });

  final Conversation conversation;
  final bool isFirst;
  final bool isLast;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shape = BorderRadius.vertical(
      top: isFirst ? AppRadius.lg : Radius.zero,
      bottom: isLast ? AppRadius.lg : Radius.zero,
    );

    return Padding(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.gutter,
        0,
        AppSpacing.gutter,
        isLast ? AppSpacing.xs : 0,
      ),
      // The stroke, not the fill, is what makes the card an object. White on
      // #F8FAFC is 1.05:1 and #18181B on #09090B is 1.13:1 — neither theme
      // separates a card from its page by tone, so a hairline does it in both.
      //
      // Uniform rather than per-edge, because a `BoxDecoration` cannot carry a
      // rounded shape and a partial border at once. Adjacent rows therefore
      // abut, and that pair of hairlines *is* the internal separator — which is
      // why `_TileBody` no longer draws one of its own.
      child: Material(
        color: context.chatTheme.raisedSurface,
        shape: RoundedRectangleBorder(
          borderRadius: shape,
          side: BorderSide(color: context.chatTheme.raisedBorder),
        ),
        clipBehavior: Clip.antiAlias,
        child: Dismissible(
          key: ValueKey('dismiss-${conversation.id}'),
          direction: DismissDirection.endToStart,
          background: ColoredBox(
            color: context.chatTheme.danger.withValues(alpha: 0.15),
            child: Padding(
              padding: const EdgeInsets.only(right: AppSpacing.lg),
              child: Align(
                alignment: Alignment.centerRight,
                child: Icon(
                  Icons.delete_outline_rounded,
                  color: context.chatTheme.danger,
                ),
              ),
            ),
          ),
          // Confirm before deleting: a swipe is easy to trigger by accident
          // while scrolling, and a conversation is not trivially recoverable.
          confirmDismiss: (_) => _confirmDelete(context),
          onDismissed: (_) => ref
              .read(conversationRepositoryProvider)
              .deleteConversation(conversation.id),
          child: InkWell(
            onTap: () => context.push(AppRoutes.chatPath(conversation.id)),
            onLongPress: () => _showActions(context, ref),
            child: _TileBody(conversation: conversation),
          ),
        ),
      ),
    );
  }

  Future<bool?> _confirmDelete(BuildContext context) => showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Delete conversation?'),
      content: Text('This removes "${conversation.title}" from this device.'),
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
  );

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
}

/// The row's content, split out so the swipe background never rebuilds it.
class _TileBody extends StatelessWidget {
  const _TileBody({required this.conversation});

  final Conversation conversation;

  @override
  Widget build(BuildContext context) {
    final subtitle = _subtitleFor(conversation);
    final isOnDevice = conversation.engine.isOnDevice;

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            // Baseline, not centre: the timestamp sits on the same line as the
            // title instead of floating beside a two-line block.
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Expanded(
                child: Text(
                  conversation.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.texts.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.1,
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              // The engine marker rides up here with the timestamp, not down on
              // the excerpt line. As a labelled pill beside the excerpt it cost
              // about ninety pixels of the row's only line of content — rows
              // that ran on-device truncated at half the length of rows that did
              // not, which made the list look ragged for a reason unrelated to
              // what the rows said. A glyph on the metadata line costs twelve
              // pixels of a line that had room, and the excerpt gets its full
              // width back.
              if (isOnDevice) ...[
                Icon(
                  Icons.memory_rounded,
                  size: 13,
                  color: context.chatTheme.onDeviceAccent,
                ),
                const SizedBox(width: AppSpacing.xs),
              ],
              Text(
                _formatTimestamp(conversation.updatedAt),
                style: context.texts.labelSmall?.copyWith(
                  color: context.colors.onSurfaceVariant,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xxs),
          Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.texts.bodySmall?.copyWith(
              color: context.colors.onSurfaceVariant,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }

  /// The second line: the reply excerpt, or something useful when there is none.
  ///
  /// Falls back rather than blanking, so every row has two lines and the group
  /// keeps an even rhythm.
  static String _subtitleFor(Conversation conversation) {
    final preview = conversation.lastMessagePreview;

    if (preview != null && preview.isNotEmpty) {
      // Stripped again here, not only in the DAO. Rows written by an earlier
      // build are still in the database with their markup intact, and a preview
      // is cheap to clean but expensive to migrate.
      final plain = MarkdownText.toPlain(preview);
      if (plain.isNotEmpty && !_restates(plain, conversation.title)) {
        return plain;
      }
    }

    if (conversation.messageCount > 0) {
      final count = conversation.messageCount;
      return '$count ${count == 1 ? 'message' : 'messages'}';
    }
    return conversation.engine.isOnDevice
        ? 'Ready — runs on this device'
        : 'No messages yet';
  }

  /// Whether the excerpt just repeats the title back.
  ///
  /// The title is the opening question and the excerpt is the latest reply, so
  /// a model that answers by restating the question — which is common — makes
  /// the row print the same sentence twice. Comparing on letters and digits
  /// alone survives the title's own truncation ellipsis and any markup around
  /// the echo. Short titles are exempt because a two-word title legitimately
  /// recurs in a real answer.
  static bool _restates(String preview, String title) {
    final key = _lettersOnly(title);
    if (key.length < 12) return false;
    return _lettersOnly(preview).contains(key);
  }

  static String _lettersOnly(String value) =>
      value.toLowerCase().replaceAll(_nonAlphanumeric, '');

  static final RegExp _nonAlphanumeric = RegExp(r'[^a-z0-9]');

  /// Relative for recent activity, absolute once it stops being "recent".
  static String _formatTimestamp(DateTime timestamp) {
    final local = timestamp.toLocal();
    final difference = DateTime.now().difference(local);

    if (difference.inMinutes < 1) return 'now';
    if (difference.inMinutes < 60) return '${difference.inMinutes}m';
    if (difference.inHours < 24) return '${difference.inHours}h';
    if (difference.inDays < 7) return '${difference.inDays}d';
    return DateFormat('d MMM').format(local);
  }
}
