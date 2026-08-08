/// Liquid-glass surfaces for the app's floating chrome.
///
/// Three things govern how this is used, and they are why glass appears on a
/// handful of surfaces rather than everywhere.
///
/// **Glass needs something behind it.** A refractive surface over a flat fill
/// bends nothing and just looks like a slightly murky rectangle. That is why
/// [AppBackdrop] exists: it lays down a soft brand-tinted wash so the chrome has
/// gradients and content to distort. Without it the effect is invisible and the
/// GPU cost is pure waste.
///
/// **It belongs on chrome, not on content.** The navigation bar, the composer
/// and the app bars float above scrolling content, so refraction tells you what
/// is underneath. A message bubble or a list card sits *in* the flow — glass
/// there costs a backdrop pass per item and communicates nothing.
///
/// **It must be switchable.** Refraction reduces contrast between foreground
/// text and whatever is passing behind it, which is exactly the problem
/// "Reduce Transparency" exists to solve. [GlassScope] resolves a user setting
/// and the platform's high-contrast flag, and every surface here falls back to
/// an opaque one that keeps the same geometry.
library;

import 'package:evdekimi_ai/design_system/chat_theme.dart';
import 'package:evdekimi_ai/design_system/palette.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';

/// How glass should behave for a subtree.
///
/// An [InheritedWidget] rather than a provider lookup so that widget tests and
/// golden tests can disable glass with one wrapper, and so the resolution
/// happens once per frame rather than per surface.
class GlassScope extends InheritedWidget {
  const GlassScope({required this.isEnabled, required super.child, super.key});

  final bool isEnabled;

  /// Whether glass should render here.
  ///
  /// Defaults to `false` when no scope is present: an app that forgets to
  /// install one gets the plain surfaces, which are always correct, rather than
  /// an effect nobody asked for.
  static bool of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<GlassScope>();
    if (scope == null) return false;
    // The platform accessibility setting always wins over the app preference.
    // Someone who has asked the OS for higher contrast has already answered
    // this question.
    if (MediaQuery.highContrastOf(context)) return false;
    return scope.isEnabled;
  }

  @override
  bool updateShouldNotify(GlassScope oldWidget) =>
      oldWidget.isEnabled != isEnabled;
}

/// Standard glass treatments.
///
/// Named by role rather than by parameters, so a surface asks for "the
/// navigation bar treatment" and cannot invent its own refraction values.
abstract final class AppGlass {
  /// Chrome that floats over scrolling content.
  ///
  /// Refraction is kept low on purpose. Strong distortion is enjoyable in a
  /// demo and unpleasant to use — it smears the text scrolling beneath and draws
  /// attention to the container instead of the content.
  static LiquidGlassStyle surface(
    BuildContext context, {
    required double cornerRadius,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return LiquidGlassStyle(
      shape: LiquidGlassShape.continuousRoundedRectangle(
        cornerRadius: cornerRadius,
        // A bright hairline along the edge is what reads as a physical pane
        // rather than a blur. It is the cheapest part of the effect and does
        // the most work.
        borderColor: isDark
            ? AppPalette.white.withValues(alpha: 0.14)
            : AppPalette.white.withValues(alpha: 0.55),
      ),
      appearance: LiquidGlassAppearance(
        // Tint carries the surface. Blur alone turns everything to grey soup;
        // a light tint keeps the material feeling like the app's own colour.
        color: isDark
            ? AppPalette.ink800.withValues(alpha: 0.55)
            : AppPalette.white.withValues(alpha: 0.62),
        blur: const LiquidGlassBlur(sigmaX: 18, sigmaY: 18),
        // Slightly above 1 so colours passing behind stay lively instead of
        // washing out through the blur.
        saturation: 1.25,
      ),
      refraction: const LiquidGlassRefraction(
        distortion: 0.35,
        magnification: 1.02,
        // Chromatic aberration is the detail that separates real glass from a
        // blur, but past a whisper it fringes text and looks broken.
        chromaticAberration: 0.06,
      ),
    );
  }
}

/// A glass panel that degrades to an opaque one.
///
/// The fallback is deliberately not "the same thing without blur": it uses the
/// solid surface colour and the same border and radius, so turning glass off
/// changes the material and nothing else. Layout, hit targets and geometry are
/// identical either way.
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    required this.child,
    required this.cornerRadius,
    this.shadows = const [],
    this.fallbackColor,
    super.key,
  });

  final Widget child;
  final double cornerRadius;

  /// Applied in both modes; glass still needs to read as raised.
  final List<BoxShadow> shadows;

  /// Opaque colour used when glass is off. Defaults to the lowest surface.
  final Color? fallbackColor;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(cornerRadius);

    if (!GlassScope.of(context)) {
      return DecoratedBox(
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
      // The shadow has to sit outside the lens: a lens draws its own backdrop,
      // and a shadow inside it would be refracted along with the content.
      decoration: BoxDecoration(borderRadius: radius, boxShadow: shadows),
      child: LiquidGlassLens(
        style: AppGlass.surface(context, cornerRadius: cornerRadius),
        child: child,
      ),
    );
  }
}

/// The soft wash that gives glass something to refract.
///
/// Two very low-opacity brand blooms over the scaffold colour. Kept subtle on
/// purpose — this is a backdrop, and if you notice it as a gradient it is too
/// strong. Its real job is to make the chrome above it look like glass.
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
                  primary.withValues(alpha: isDark ? 0.16 : 0.10),
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
                  accent.withValues(alpha: isDark ? 0.10 : 0.07),
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
