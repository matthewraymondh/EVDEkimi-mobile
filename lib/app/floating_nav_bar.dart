import 'package:evdekimi_ai/design_system/chat_theme.dart';
import 'package:evdekimi_ai/design_system/glass.dart';
import 'package:evdekimi_ai/design_system/palette.dart';
import 'package:evdekimi_ai/design_system/tokens.dart';
import 'package:evdekimi_ai/di/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Height of the dock, shared by the pane and by every control in it.
const double _barHeight = AppSizes.navBar;

/// Side of the compose action and of each destination's tap target.
const double _slotSize = 48;

/// The gliding capsule behind the selected destination.
const double _pillWidth = 56;
const double _pillHeight = 40;

/// How long the capsule takes to travel between destinations.
///
/// Long enough to be followed by the eye — the movement is the thing that says
/// "you moved from here to there", and at 150ms it just teleports.
const Duration _pillGlide = Duration(milliseconds: 300);

/// A floating glass dock.
///
/// Two layers, which is what separates this from a tinted strip with icons on
/// it. The outer pane is a single heavy slab; the selected destination sits in
/// its own lighter capsule *inside* it, and that capsule glides between
/// destinations rather than fading out in one place and in at another.
///
/// The glide is the whole point. A capsule that cross-fades is two events the
/// eye has to connect; one that travels is a single object moving, so the
/// motion carries the meaning and no highlight is ever in two places at once.
/// It passes behind the compose control on the way, which reads correctly —
/// the filled block is nearer the viewer than the capsule is.
///
/// Three slots, but only two are destinations: the middle is an action, so the
/// capsule steps over it from slot 0 to slot 2.
class FloatingNavBar extends ConsumerWidget {
  const FloatingNavBar({
    super.key,
    required this.currentIndex,
    required this.onSelect,
    required this.onNewChat,
  });

  final int currentIndex;
  final ValueChanged<int> onSelect;
  final VoidCallback onNewChat;

  /// Slot each destination occupies, skipping the compose action in the middle.
  static const List<int> _slotForDestination = [0, 2];

  /// Identifies the gliding capsule so its position can be asserted.
  ///
  /// The capsule is pure decoration with no text and no semantics of its own,
  /// so there is nothing else in the tree to find it by.
  @visibleForTesting
  static const Key activeCapsuleKey = Key('nav-active-capsule');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chat = context.chatTheme;
    final pending = ref.watch(pendingMessageCountProvider).value ?? 0;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSizes.navBarGap,
          0,
          AppSizes.navBarGap,
          AppSizes.navBarGap,
        ),
        child: SizedBox(
          height: _barHeight,
          child: GlassSurface(
            // Half the height, so the continuous-corner shape resolves to a
            // true capsule rather than a rounded rectangle with tall sides.
            cornerRadius: _barHeight / 2,
            blur: 25,
            fill: chat.dockFill,
            stroke: chat.dockStroke,
            highlight: chat.dockHighlight,
            strokeWidth: 1.2,
            highlightWidth: 1.5,
            // Two shadows, not one. A single wide blur reads as fog; a tight
            // contact shadow plus a wide ambient one is how a real object sits
            // above a surface. This is the only elevated element in the app, so
            // it is the one place the cost is justified.
            shadows: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.10),
                blurRadius: 6,
                offset: const Offset(0, 2),
              ),
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.16),
                blurRadius: 28,
                offset: const Offset(0, 12),
              ),
            ],
            child: LayoutBuilder(
              builder: (context, constraints) {
                final slotWidth = constraints.maxWidth / 3;
                final slot =
                    _slotForDestination[currentIndex.clamp(
                      0,
                      _slotForDestination.length - 1,
                    )];

                return Stack(
                  children: [
                    AnimatedPositioned(
                      duration: _pillGlide,
                      curve: Curves.easeOutCubic,
                      left: slotWidth * slot + (slotWidth - _pillWidth) / 2,
                      top: (_barHeight - _pillHeight) / 2,
                      width: _pillWidth,
                      height: _pillHeight,
                      child: const _ActivePill(key: activeCapsuleKey),
                    ),
                    Row(
                      children: [
                        Expanded(
                          child: Center(
                            child: _NavItem(
                              icon: Icons.forum_outlined,
                              activeIcon: Icons.forum_rounded,
                              label: 'Chats',
                              isActive: currentIndex == 0,
                              badgeCount: pending,
                              onTap: () => onSelect(0),
                            ),
                          ),
                        ),
                        Expanded(
                          child: Center(
                            child: _NewChatButton(onTap: onNewChat),
                          ),
                        ),
                        Expanded(
                          child: Center(
                            child: _NavItem(
                              icon: Icons.settings_outlined,
                              activeIcon: Icons.settings_rounded,
                              label: 'Settings',
                              isActive: currentIndex == 1,
                              onTap: () => onSelect(1),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// The inner capsule that marks the selected destination.
///
/// A gradient rather than a flat tint, and top-lighter than bottom, so it reads
/// as a second pane resting on the first rather than as a painted rectangle.
class _ActivePill extends StatelessWidget {
  const _ActivePill({super.key});

  @override
  Widget build(BuildContext context) {
    final chat = context.chatTheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final base = chat.dockActive;

    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: isDark
                ? [
                    base.withValues(alpha: base.a * 1.25),
                    base.withValues(alpha: base.a * 0.45),
                  ]
                : [base, base.withValues(alpha: base.a * 0.6)],
          ),
          borderRadius: BorderRadius.circular(_pillHeight / 2),
          border: Border.all(color: chat.dockStroke),
        ),
      ),
    );
  }
}

/// One destination in the dock.
///
/// Carries no indicator of its own. The selected state is drawn by the capsule
/// gliding behind it, which is what lets the highlight be a single travelling
/// object instead of one per slot fading in and out of existence.
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
    final foreground = context.colors.onSurface;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Semantics(
      button: true,
      selected: isActive,
      label: label,
      child: InkResponse(
        onTap: onTap,
        // Feedback has to be immediate. The capsule takes 300ms to arrive, and
        // a control that shows nothing for a third of a second after a tap
        // feels unresponsive however good the animation is once it starts.
        radius: 26,
        child: SizedBox(
          // Tap target stays a full 48dp even though the capsule behind it is
          // smaller — the accessibility floor is about the finger, not the paint.
          width: _slotSize,
          height: _slotSize,
          child: Stack(
            alignment: Alignment.center,
            clipBehavior: Clip.none,
            children: [
              AnimatedSwitcher(
                duration: AppDuration.fast,
                child: Icon(
                  isActive ? activeIcon : icon,
                  key: ValueKey(isActive),
                  size: AppSizes.iconMd,
                  color: isActive
                      ? foreground
                      : foreground.withValues(alpha: isDark ? 0.5 : 0.4),
                  // A short, tight glow under the selected glyph only. It is
                  // what stops the icon looking pasted onto the capsule: a lit
                  // object spills a little light onto what it rests on.
                  shadows: isActive
                      ? [
                          Shadow(
                            color: foreground.withValues(alpha: 0.35),
                            blurRadius: 10,
                          ),
                        ]
                      : null,
                ),
              ),
              if (badgeCount > 0)
                Positioned(
                  top: 6,
                  right: 4,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    constraints: const BoxConstraints(minWidth: 16),
                    decoration: BoxDecoration(
                      color: context.chatTheme.warning,
                      borderRadius: AppRadius.allPill,
                      // Ring in the page colour so the badge reads as punched
                      // through the dock rather than floating on it — the dock
                      // is translucent, so its own fill is not a colour
                      // anything can be matched against.
                      border: Border.all(color: context.colors.surface),
                    ),
                    child: Text(
                      badgeCount > 9 ? '9+' : '$badgeCount',
                      textAlign: TextAlign.center,
                      style: context.texts.labelSmall?.copyWith(
                        fontSize: 9,
                        height: 1.5,
                        fontWeight: FontWeight.w700,
                        color: AppPalette.zinc950,
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
