/// Liquid-glass surfaces for the app's floating chrome.
///
/// Backed by `liquid_glass_widgets`, whose own guidance matches the rule this
/// app already followed: glass belongs on the navigation and control layer, and
/// content stays opaque. Nav bar and composer float above scrolling content, so
/// refraction says something about what is underneath; a message bubble sits *in*
/// the flow, where glass would cost a backdrop pass per item and communicate
/// nothing.
///
/// Two things the package handles that are worth not reimplementing: it bridges
/// the platform's Reduce Transparency and Reduce Motion settings automatically,
/// and it pre-warms shaders before `runApp` to avoid the Android GLES
/// compilation stall that can otherwise register as an ANR on budget hardware.
///
/// What stays local is the *app-level* toggle. A user who turns glass off in
/// Settings is expressing a preference the OS knows nothing about, so
/// [GlassScope] forces the package's frosted fallback in that case — while
/// leaving the system setting authoritative when the toggle is on.
library;

import 'package:evdekimi_ai/design_system/chat_theme.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

/// Whether glass is enabled for a subtree.
///
/// An [InheritedWidget] rather than a provider lookup so widget and golden tests
/// can disable glass with one wrapper.
class GlassScope extends InheritedWidget {
  const GlassScope({required this.isEnabled, required super.child, super.key});

  final bool isEnabled;

  /// Defaults to `false` when no scope is present: an app that forgets to
  /// install one gets plain surfaces, which are always correct, rather than an
  /// effect nobody asked for.
  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<GlassScope>()?.isEnabled ??
      false;

  @override
  bool updateShouldNotify(GlassScope oldWidget) =>
      oldWidget.isEnabled != isEnabled;
}

/// A glass panel that degrades to an opaque one.
///
/// The fallback is not "the same thing without blur": it uses the solid surface
/// colour with the same radius, border and shadows, so switching glass off
/// changes the material and nothing else. Layout, hit targets and geometry are
/// identical either way.
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    required this.child,
    required this.cornerRadius,
    this.shadows = const [],
    this.fallbackColor,
    this.padding,
    super.key,
  });

  final Widget child;
  final double cornerRadius;

  /// Applied in both modes; glass still needs to read as raised.
  final List<BoxShadow> shadows;

  /// Opaque colour used when glass is off. Defaults to the lowest surface.
  final Color? fallbackColor;

  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(cornerRadius);

    if (!GlassScope.of(context)) {
      return Container(
        padding: padding,
        decoration: BoxDecoration(
          color: fallbackColor ?? context.colors.surfaceContainerLowest,
          borderRadius: radius,
          border: Border.all(color: context.colors.outlineVariant),
          boxShadow: shadows,
        ),
        child: child,
      );
    }

    return DecoratedBox(
      // The shadow sits outside the glass: a glass layer captures and refracts
      // its own backdrop, and a shadow inside would be refracted along with it.
      decoration: BoxDecoration(borderRadius: radius, boxShadow: shadows),
      child: GlassContainer(
        // A superellipse, not a circular-radius rounded rect. It is what iOS 26
        // uses, and the continuous curvature is most of why the corners read as
        // moulded rather than cut.
        shape: LiquidRoundedSuperellipse(borderRadius: cornerRadius),
        // Premium runs the full Impeller pipeline — texture capture, refraction
        // and chromatic aberration. Correct here specifically because these are
        // *fixed* surfaces: the package warns premium can misrender inside a
        // scrollable, and neither the nav bar nor the composer scrolls.
        quality: GlassQuality.premium,
        // Isolates this surface's backdrop capture, which is what stops the two
        // glass layers on the chat screen sampling each other.
        useOwnLayer: true,
        padding: padding,
        child: child,
      ),
    );
  }
}

/// The soft wash that gives glass something to refract.
///
/// Glass bends what is behind it, so over a flat fill it bends nothing and reads
/// as slightly murky plastic. Two very low-opacity brand blooms give the chrome
/// gradients to distort. Kept subtle on purpose — if you notice it *as* a
/// gradient it is too strong; its job is to make the chrome above it look like
/// glass.
///
/// Renders nothing when glass is disabled, so the plain theme stays plain.
class AppBackdrop extends StatelessWidget {
  const AppBackdrop({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!GlassScope.of(context)) return child;

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primary = context.colors.primary;
    final accent = context.chatTheme.onDeviceAccent;

    return Stack(
      children: [
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(-0.8, -0.9),
                radius: 1.4,
                colors: [
                  primary.withValues(alpha: isDark ? 0.30 : 0.22),
                  Colors.transparent,
                ],
              ),
            ),
          ),
        ),
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(0.9, 0.7),
                radius: 1.2,
                colors: [
                  accent.withValues(alpha: isDark ? 0.22 : 0.16),
                  Colors.transparent,
                ],
              ),
            ),
          ),
        ),
        child,
      ],
    );
  }
}

/// An app bar that becomes a glass pane when glass is enabled.
///
/// Only meaningful on a `Scaffold` with `extendBodyBehindAppBar: true` — a bar
/// with opaque layout beneath it has nothing to refract, and would look like a
/// slightly cloudy solid bar. Screens using this therefore pad their scrollable
/// by [preferredSize] plus the status-bar inset, so content passes *underneath*
/// rather than starting below.
///
/// The glass lives in `flexibleSpace` rather than replacing the AppBar, so
/// titles, leading buttons, actions, `bottom` widgets and the automatic back
/// button all keep working exactly as Material implements them.
class GlassAppBar extends StatelessWidget implements PreferredSizeWidget {
  const GlassAppBar({
    this.title,
    this.actions,
    this.bottom,
    this.leading,
    super.key,
  });

  final Widget? title;
  final List<Widget>? actions;
  final PreferredSizeWidget? bottom;
  final Widget? leading;

  @override
  Size get preferredSize =>
      Size.fromHeight(kToolbarHeight + (bottom?.preferredSize.height ?? 0));

  @override
  Widget build(BuildContext context) {
    final isGlass = GlassScope.of(context);

    return AppBar(
      title: title,
      actions: actions,
      bottom: bottom,
      leading: leading,
      backgroundColor: isGlass ? Colors.transparent : null,
      // Material's scroll-under tint would fight the glass, which already
      // conveys "content is passing beneath me" far better than a colour shift.
      scrolledUnderElevation: 0,
      flexibleSpace: isGlass
          ? const GlassSurface(cornerRadius: 0, child: SizedBox.expand())
          : null,
    );
  }
}

/// Applies the app's glass preference on top of the system's.
///
/// Only forces the fallback when the user has switched glass *off*. Passing
/// `reduceTransparency: false` would be wrong: the package documents that this
/// scope outranks the system flag, so hard-coding it would silently override
/// someone who had asked the OS for reduced transparency.
class GlassPreference extends StatelessWidget {
  const GlassPreference({
    required this.isEnabled,
    required this.child,
    super.key,
  });

  final bool isEnabled;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scoped = GlassScope(isEnabled: isEnabled, child: child);
    if (isEnabled) return scoped;
    return GlassAccessibilityScope(reduceTransparency: true, child: scoped);
  }
}
