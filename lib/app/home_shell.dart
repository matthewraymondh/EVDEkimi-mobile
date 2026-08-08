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
          height: 68,
          decoration: BoxDecoration(
            color: context.colors.surfaceContainerLowest,
            borderRadius: AppRadius.allPill,
            border: Border.all(color: context.colors.outlineVariant),
            // Two shadows, not one. A single wide blur reads as fog; a tight
            // contact shadow plus a wide ambient one is how a real object sits
            // above a surface. This is the only elevated element in the app, so
            // it is the one place the cost is justified.
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.04),
                blurRadius: 4,
                offset: const Offset(0, 2),
              ),
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.07),
                blurRadius: 28,
                offset: const Offset(0, 12),
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
    return Semantics(
      button: true,
      selected: isActive,
      label: label,
      child: InkResponse(
        onTap: onTap,
        // Unbounded ripple, sized to the indicator rather than the tap target,
        // so the splash reads as belonging to the disc.
        radius: 28,
        child: SizedBox(
          // Tap target stays a full 48dp even though the visible indicator is
          // 40 — the accessibility floor is about the finger, not the paint.
          width: AppSizes.minTapTarget,
          height: AppSizes.minTapTarget,
          child: Stack(
            alignment: Alignment.center,
            clipBehavior: Clip.none,
            children: [
              // The selected destination gets a filled disc rather than just a
              // tinted glyph. Colour alone is a weak signal — it fails for
              // colour-blind users and washes out in sunlight — whereas a shape
              // change is unambiguous. This is also what the reference does, and
              // it is the one idea there worth taking.
              AnimatedContainer(
                duration: AppDuration.medium,
                curve: AppCurve.standard,
                width: isActive ? 40 : 0,
                height: isActive ? 40 : 0,
                decoration: BoxDecoration(
                  color: context.colors.primary.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
              ),
              AnimatedSwitcher(
                duration: AppDuration.fast,
                child: Icon(
                  isActive ? activeIcon : icon,
                  key: ValueKey(isActive),
                  color: isActive
                      ? context.colors.primary
                      : context.colors.onSurfaceVariant,
                  size: AppSizes.iconMd,
                ),
              ),
              if (badgeCount > 0)
                Positioned(
                  top: 8,
                  right: 6,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    constraints: const BoxConstraints(minWidth: 16),
                    decoration: BoxDecoration(
                      color: context.chatTheme.warning,
                      borderRadius: AppRadius.allPill,
                      // Ring in the bar's own colour so the badge separates from
                      // the icon beneath it without needing a drop shadow.
                      border: Border.all(
                        color: context.colors.surfaceContainerLowest,
                        width: 2,
                      ),
                    ),
                    child: Text(
                      badgeCount > 9 ? '9+' : '$badgeCount',
                      textAlign: TextAlign.center,
                      style: context.texts.labelSmall?.copyWith(
                        fontSize: 9,
                        height: 1.5,
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

/// The primary action.
///
/// Starting a conversation is what every session begins with, so it is filled
/// and slightly larger rather than sharing the flat treatment of the
/// destinations around it.
///
/// Deliberately a **solid brand fill, not a gradient**. The earlier version
/// blended primary into the on-device accent, which was wrong twice over: that
/// amber is a semantic colour meaning "this ran locally", and spending it as
/// decoration erodes a signal the message footers and Settings rely on; and a
/// two-hue gradient with no meaning behind it is the hallmark of a button
/// designed by defaults. One confident colour reads as intent.
class _NewChatButton extends StatefulWidget {
  const _NewChatButton({required this.onTap});

  final VoidCallback onTap;

  @override
  State<_NewChatButton> createState() => _NewChatButtonState();
}

class _NewChatButtonState extends State<_NewChatButton> {
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'New chat',
      child: Tooltip(
        message: 'New chat',
        child: GestureDetector(
          onTapDown: (_) => setState(() => _isPressed = true),
          onTapCancel: () => setState(() => _isPressed = false),
          onTap: () {
            setState(() => _isPressed = false);
            HapticFeedback.selectionClick();
            widget.onTap();
          },
          child: AnimatedScale(
            // A real press response. Material's ink ripple is invisible on a
            // saturated fill, so the button would otherwise feel dead on touch.
            scale: _isPressed ? 0.92 : 1,
            duration: AppDuration.instant,
            curve: AppCurve.standard,
            child: Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: context.colors.primary,
                shape: BoxShape.circle,
                boxShadow: [
                  // Tinted with the button's own colour rather than black:
                  // a coloured object casts a coloured shadow, and a grey one
                  // under a saturated fill reads as dirt.
                  BoxShadow(
                    color: context.colors.primary.withValues(alpha: 0.28),
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
      ),
    );
  }
}
