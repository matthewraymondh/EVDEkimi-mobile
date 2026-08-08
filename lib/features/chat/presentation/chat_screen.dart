import 'package:evdekimi_ai/design_system/chat_theme.dart';
import 'package:evdekimi_ai/design_system/glass.dart';
import 'package:evdekimi_ai/design_system/tokens.dart';
import 'package:evdekimi_ai/design_system/widgets/app_widgets.dart';
import 'package:evdekimi_ai/di/providers.dart';
import 'package:evdekimi_ai/features/ai/domain/model_descriptor.dart';
import 'package:evdekimi_ai/features/chat/domain/entities/message.dart';
import 'package:evdekimi_ai/features/chat/presentation/chat_controller.dart';
import 'package:evdekimi_ai/features/chat/presentation/widgets/message_bubble.dart';
import 'package:evdekimi_ai/features/chat/presentation/widgets/message_composer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The transcript for one conversation.
class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({required this.conversationId, super.key});

  final String conversationId;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _scrollController = ScrollController();

  /// Set when the user scrolls up, which suppresses auto-scroll so reading back
  /// through history is not yanked to the bottom by every incoming token.
  bool _userScrolledAway = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    // The list is reversed, so "at the bottom" means near offset 0.
    final isAtBottom = position.pixels <= 80;
    if (isAtBottom == _userScrolledAway) {
      setState(() => _userScrolledAway = !isAtBottom);
    }
  }

  void _scrollToBottom() {
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      0,
      duration: AppDuration.medium,
      curve: AppCurve.standard,
    );
  }

  @override
  Widget build(BuildContext context) {
    final messagesAsync = ref.watch(messagesProvider(widget.conversationId));
    final conversation = ref
        .watch(conversationProvider(widget.conversationId))
        .value;
    final isOnline = ref.watch(isOnlineProvider);
    final pendingCount = ref.watch(pendingMessageCountProvider).value ?? 0;

    final messages = messagesAsync.value ?? const <Message>[];
    final isGenerating = messages.any(
      (message) => message.isFromAssistant && message.status.isInFlight,
    );

    return Scaffold(
      // Required for the glass bar to mean anything: the transcript has to pass
      // underneath it rather than starting below it.
      extendBodyBehindAppBar: true,
      appBar: GlassAppBar(
        // The offline banner rides under the bar instead of sitting in the body.
        // With the body extending behind the bar it would otherwise be hidden,
        // and attached to the chrome is where it belongs anyway.
        bottom: isOnline
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(36),
                child: OfflineBanner(
                  isVisible: !isOnline,
                  pendingCount: pendingCount,
                ),
              ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              conversation?.title ?? 'Chat',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            if (conversation != null)
              Text(
                conversation.engine.isOnDevice
                    ? 'On-device model'
                    : conversation.modelId,
                style: context.texts.labelSmall?.copyWith(
                  color: context.colors.onSurfaceVariant,
                ),
              ),
          ],
        ),
        actions: [
          IconButton(
            onPressed: () => _showModelPicker(context),
            tooltip: 'Change model',
            icon: const Icon(Icons.tune_rounded),
          ),
        ],
      ),
      body: AppBackdrop(
        child: Column(
          children: [
            Expanded(
              child: messagesAsync.when(
                loading: () => messages.isEmpty
                    ? const SkeletonList(itemCount: 4)
                    : _buildList(messages, isGenerating: isGenerating),
                error: (error, _) => EmptyStateView(
                  icon: Icons.error_outline_rounded,
                  title: "Couldn't load this conversation",
                  message: '$error',
                  actionLabel: 'Retry',
                  onAction: () =>
                      ref.invalidate(messagesProvider(widget.conversationId)),
                ),
                data: (data) => data.isEmpty
                    ? _EmptyConversation(conversationId: widget.conversationId)
                    : _buildList(data, isGenerating: isGenerating),
              ),
            ),
            MessageComposer(
              conversationId: widget.conversationId,
              isGenerating: isGenerating,
            ),
          ],
        ),
      ),
      floatingActionButton: _userScrolledAway && messages.isNotEmpty
          ? FloatingActionButton.small(
              onPressed: _scrollToBottom,
              tooltip: 'Jump to latest',
              child: const Icon(Icons.arrow_downward_rounded),
            )
          : null,
    );
  }

  Widget _buildList(List<Message> messages, {required bool isGenerating}) {
    final controller = ref.read(
      chatControllerProvider(widget.conversationId).notifier,
    );

    // `reverse: true` is what keeps the newest message pinned to the bottom while
    // tokens stream in, without any scroll maths: the viewport grows downward from
    // offset 0. It also means the list does not jump when older history loads.
    // Top padding clears the glass bar. The list is reversed, so this is the
    // padding messages scroll *into* as they move up — which is the whole point:
    // seeing the transcript refract through the bar is what makes it read as
    // glass rather than a tinted strip.
    final barHeight =
        MediaQuery.paddingOf(context).top +
        kToolbarHeight +
        (ref.read(isOnlineProvider) ? 0 : 36);

    return ListView.builder(
      controller: _scrollController,
      reverse: true,
      padding: EdgeInsets.only(
        top: barHeight + AppSpacing.md,
        bottom: AppSpacing.md,
      ),
      itemCount: messages.length,
      itemBuilder: (context, index) {
        final message = messages[messages.length - 1 - index];
        return MessageBubble(
          key: ValueKey(message.id),
          message: message,
          statusLabel: message.isAwaitingFirstToken
              ? (message.engine?.isOnDevice ?? false
                    ? 'Running on-device model…'
                    : null)
              : null,
          onRetry: message.status.canRetry
              ? () => controller.retry(message.id)
              : null,
          onRegenerate: message.isFromAssistant && !isGenerating
              ? () => controller.regenerate(message.id)
              : null,
        );
      },
    );
  }

  Future<void> _showModelPicker(BuildContext context) async {
    final models = await ref.read(availableModelsProvider.future);
    if (!context.mounted) return;

    final current = ref.read(conversationProvider(widget.conversationId)).value;
    final isOnline = ref.read(isOnlineProvider);

    final selected = await showModalBottomSheet<ModelDescriptor>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Text('Model', style: context.texts.titleMedium),
            ),
            for (final model in models)
              ListTile(
                leading: Icon(
                  model.engine.isOnDevice
                      ? Icons.memory_rounded
                      : Icons.cloud_outlined,
                  color: model.engine.isOnDevice
                      ? context.chatTheme.onDeviceAccent
                      : null,
                ),
                title: Text(model.name),
                subtitle: model.description == null
                    ? Text(model.provider)
                    : Text(
                        model.description!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                trailing: current?.modelId == model.id
                    ? const Icon(Icons.check_rounded)
                    : null,
                // A cloud model with no network is shown but disabled, so the user
                // can see it exists and understand why it is unavailable.
                enabled: model.isUsable(isOnline: isOnline),
                onTap: () => Navigator.of(context).pop(model),
              ),
          ],
        ),
      ),
    );

    if (selected == null) return;
    await ref
        .read(chatControllerProvider(widget.conversationId).notifier)
        .setModel(selected);
  }
}

class _EmptyConversation extends ConsumerWidget {
  const _EmptyConversation({required this.conversationId});

  final String conversationId;

  /// Short labels with the full prompt behind them.
  ///
  /// Chips have to stay readable at chip size, but a three-word prompt produces
  /// a worse answer than a specific one — so the label is short and what is
  /// actually sent is not.
  static const List<(String, String, IconData)> _prompts = [
    (
      'Explain a concept',
      'Explain server-sent events like I am new to it',
      Icons.school_outlined,
    ),
    (
      'Write some code',
      'Write a Dart function that debounces a callback',
      Icons.code_rounded,
    ),
    (
      'Compare options',
      'Summarise the tradeoffs of on-device inference versus cloud inference',
      Icons.balance_rounded,
    ),
    (
      'Summarise something',
      'Summarise the key points of the article I am about to paste',
      Icons.notes_rounded,
    ),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const AppAvatar(label: 'AI', isAssistant: true, size: 56),
            const SizedBox(height: AppSpacing.lg),
            Text(
              'Need anything?',
              style: context.texts.headlineSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Conversations are stored on this device and keep working offline.',
              textAlign: TextAlign.center,
              style: context.texts.bodyMedium?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppSpacing.xl),
            // Chips rather than stacked buttons: they read as suggestions to
            // sample, not as the only four things the app can do.
            Wrap(
              alignment: WrapAlignment.center,
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [
                for (final (label, prompt, icon) in _prompts)
                  ActionChip(
                    avatar: Icon(icon, size: AppSizes.iconSm),
                    label: Text(label),
                    onPressed: () => ref
                        .read(chatControllerProvider(conversationId).notifier)
                        .send(prompt),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
