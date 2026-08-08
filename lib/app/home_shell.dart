import 'package:evdekimi_ai/design_system/chat_theme.dart';
import 'package:evdekimi_ai/design_system/tokens.dart';
import 'package:evdekimi_ai/di/providers.dart';
import 'package:evdekimi_ai/features/chat/presentation/conversation_list_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// Scaffold shared by the three top-level tabs.
///
/// Backed by `StatefulShellRoute.indexedStack`, so each tab keeps its own
/// navigation stack and scroll position — returning to Chats lands where you
/// left it rather than rebuilt at the top.
class HomeShell extends ConsumerWidget {
  const HomeShell({required this.navigationShell, super.key});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      // The bar floats over the content rather than displacing it, so a list can
      // scroll beneath it. Screens add bottom padding for the overlap.
      extendBody: true,
      body: navigationShell,
      bottomNavigationBar: _FloatingNavBar(
        currentIndex: navigationShell.currentIndex,
        onSelect: (index) => navigationShell.goBranch(
          index,
          // Tapping the tab you are already on pops that tab back to its root,
          // which is the behaviour users expect from every other app.
          initialLocation: index == navigationShell.currentIndex,
        ),
        onNewChat: () => startNewConversation(context, ref),
      ),
    );
  }
}

/// A floating pill navigation bar with a raised primary action in the middle.
class _FloatingNavBar extends ConsumerWidget {
  const _FloatingNavBar({
    required this.currentIndex,
    required this.onSelect,
    required this.onNewChat,
  });

  final int currentIndex;
  final ValueChanged<int> onSelect;
  final VoidCallback onNewChat;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pending = ref.watch(pendingMessageCountProvider).value ?? 0;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.xl,
          0,
          AppSpacing.xl,
          AppSpacing.md,
        ),
        child: Container(
          height: 64,
          decoration: BoxDecoration(
            color: context.colors.surfaceContainerLowest,
            borderRadius: AppRadius.allPill,
            border: Border.all(color: context.colors.outlineVariant),
            boxShadow: [
              // The one place a shadow earns its keep: the bar overlaps
              // scrolling content, so it needs to read as physically above it.
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.08),
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _NavItem(
                icon: Icons.forum_outlined,
                activeIcon: Icons.forum_rounded,
                label: 'Chats',
                isActive: currentIndex == 0,
                badgeCount: pending,
                onTap: () => onSelect(0),
              ),
              _NavItem(
                icon: Icons.search_rounded,
                activeIcon: Icons.search_rounded,
                label: 'Search',
                isActive: currentIndex == 1,
                onTap: () => onSelect(1),
              ),
              _NewChatButton(onTap: onNewChat),
              _NavItem(
                icon: Icons.settings_outlined,
                activeIcon: Icons.settings_rounded,
                label: 'Settings',
                isActive: currentIndex == 2,
                onTap: () => onSelect(2),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.isActive,
    required this.onTap,
    this.badgeCount = 0,
  });

  final IconData icon;
  final IconData activeIcon;
  final String label;
  final bool isActive;
  final VoidCallback onTap;

  /// Queued messages, surfaced on the Chats tab so nothing waiting is invisible.
  final int badgeCount;

  @override
  Widget build(BuildContext context) {
    final color = isActive
        ? context.colors.primary
        : context.colors.onSurfaceVariant;

    return Semantics(
      button: true,
      selected: isActive,
      label: label,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: AppSizes.minTapTarget,
          height: AppSizes.minTapTarget,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Only the icon changes weight between states. A label that
              // appears and disappears would shift the row on every tap.
              AnimatedSwitcher(
                duration: AppDuration.fast,
                child: Icon(
                  isActive ? activeIcon : icon,
                  key: ValueKey(isActive),
                  color: color,
                  size: AppSizes.iconMd,
                ),
              ),
              if (badgeCount > 0)
                Positioned(
                  top: 10,
                  right: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    constraints: const BoxConstraints(minWidth: 14),
                    decoration: BoxDecoration(
                      color: context.chatTheme.warning,
                      borderRadius: AppRadius.allPill,
                    ),
                    child: Text(
                      badgeCount > 9 ? '9+' : '$badgeCount',
                      textAlign: TextAlign.center,
                      style: context.texts.labelSmall?.copyWith(
                        fontSize: 9,
                        height: 1.4,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The raised primary action.
///
/// Starting a conversation is the one thing every session begins with, so it
/// gets a filled, slightly larger target rather than sharing the flat treatment
/// of the destinations around it.
class _NewChatButton extends StatelessWidget {
  const _NewChatButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'New chat',
      child: Tooltip(
        message: 'New chat',
        child: InkWell(
          onTap: () {
            HapticFeedback.selectionClick();
            onTap();
          },
          customBorder: const CircleBorder(),
          child: Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  context.colors.primary,
                  context.chatTheme.onDeviceAccent,
                ],
              ),
              boxShadow: [
                BoxShadow(
                  color: context.colors.primary.withValues(alpha: 0.35),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Icon(
              Icons.add_rounded,
              color: context.colors.onPrimary,
              size: AppSizes.iconLg,
            ),
          ),
        ),
      ),
    );
  }
}
