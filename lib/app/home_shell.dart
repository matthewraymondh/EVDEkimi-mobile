import 'package:evdekimi_ai/design_system/chat_theme.dart';
import 'package:evdekimi_ai/design_system/glass.dart';
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
      // The wash that gives the glass chrome something to refract. Without it a
      // refractive bar over a flat fill bends nothing and just looks murky.
      body: AppBackdrop(child: navigationShell),
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

/// Height of the bar itself, shared by the panel and by every control in it.
///
/// One constant rather than three, because the previous version had the primary
/// action lifted *above* the panel: the bar's silhouette was a capsule with a
/// disc breaking its top edge, its layout slot had to be padded to contain the
/// overhang, and the whole assembly measured taller than the surface it looked
/// like. Nothing in the bar can now be a different height from anything else.
const double _barHeight = 64;

/// Side of the primary action and of each destination's tap target.
const double _slotSize = 48;

/// A floating glass navigation bar.
///
/// Three inline slots, evenly spaced, all the same height. The compose action is
/// a filled control *in* the row rather than a raised circle above it — which is
/// both the native iOS reading of a bottom bar and the reason the panel now has
/// a single unbroken edge for its hairline to follow.
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
          AppSpacing.gutter,
          0,
          AppSpacing.gutter,
          AppSpacing.lg,
        ),
        child: SizedBox(
          height: _barHeight,
          child: GlassSurface(
            cornerRadius: AppRadius.xxlValue,
            // Two shadows, not one. A single wide blur reads as fog; a tight
            // contact shadow plus a wide ambient one is how a real object sits
            // above a surface. This is the only elevated element in the app, so
            // it is the one place the cost is justified.
            shadows: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.06),
                blurRadius: 4,
                offset: const Offset(0, 2),
              ),
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.10),
                blurRadius: 24,
                offset: const Offset(0, 10),
              ),
            ],
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
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
                _NewChatButton(onTap: onNewChat),
                _NavItem(
                  icon: Icons.settings_outlined,
                  activeIcon: Icons.settings_rounded,
                  label: 'Settings',
                  isActive: currentIndex == 1,
                  onTap: () => onSelect(1),
                ),
              ],
            ),
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
          width: _slotSize,
          height: _slotSize,
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
                  // Neutral, not accent. The compose control beside it is a
                  // solid accent block, and tinting the selected destination
                  // the same colour made two adjacent things compete for the
                  // role of "the important one". A plain lift says "you are
                  // here" without claiming to be an action.
                  color: context.colors.onSurface.withValues(alpha: 0.08),
                  // A squircle, not a disc, so the selected destination and the
                  // compose control read as the same family of object.
                  borderRadius: AppRadius.allMd,
                ),
              ),
              AnimatedSwitcher(
                duration: AppDuration.fast,
                child: Icon(
                  isActive ? activeIcon : icon,
                  key: ValueKey(isActive),
                  color: isActive
                      ? context.colors.onSurface
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
                      // Ring in the page colour so the badge separates from the
                      // icon beneath it without needing a drop shadow. The bar
                      // itself is translucent, so its own fill is not a colour
                      // anything can be matched against.
                      border: Border.all(
                        color: context.colors.surface,
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
/// while the destinations around it are flat. A rounded square rather than a
/// circle: at 12px it is the same corner as the search field and the prompt
/// chips, which makes it read as a control from this app rather than a Material
/// FAB that wandered into the bar.
///
/// Deliberately a **solid accent fill, not a gradient**. A two-hue gradient with
/// no meaning behind it is the hallmark of a button designed by defaults. One
/// confident colour reads as intent.
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
              width: _slotSize,
              height: _slotSize,
              decoration: BoxDecoration(
                color: context.colors.primary,
                borderRadius: AppRadius.allMd,
              ),
              child: Icon(
                Icons.add_rounded,
                color: context.colors.onPrimary,
                size: AppSizes.iconMd,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
