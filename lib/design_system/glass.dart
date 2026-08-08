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

import 'dart:ui' as ui;

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
/// colour with the same radius, stroke and shadows, so switching glass off
/// changes the material and nothing else. Layout, hit targets and geometry are
/// identical either way.
///
/// ## The stroke is not trim
///
/// Every panel gets a 1px hairline, and it is the single detail that decides
/// whether the effect reads as a material or as a bug. A real pane of glass has
/// a machined edge that catches light; without one the eye has no boundary to
/// attach the refraction to, and a blurred region with soft edges looks like a
/// rendering artefact — something failing to resolve — rather than something
/// physically there. It is drawn on `LiquidRoundedSuperellipse` itself rather
/// than an approximated `RoundedRectangleBorder`, so the line follows the exact
/// curve the shader used and does not drift away from it at the corners.
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    required this.child,
    required this.cornerRadius,
    this.shadows = const [],
    this.fallbackColor,
    this.padding,
    this.blur = defaultBlur,
    super.key,
  });

  final Widget child;
  final double cornerRadius;

  /// Applied in both modes; glass still needs to read as raised.
  final List<BoxShadow> shadows;

  /// Opaque colour used when glass is off. Defaults to the raised surface.
  final Color? fallbackColor;

  final EdgeInsetsGeometry? padding;

  /// Backdrop blur for this surface, in logical pixels.
  final double blur;

  /// Blur for chrome that sits over quiet, mostly-static content.
  ///
  /// Low on purpose. Blur and refraction compete: past a point the backdrop is
  /// smeared flat, there is nothing structured left to bend, and the panel reads
  /// as frosted plastic rather than glass.
  static const double defaultBlur = 12;

  /// Blur for chrome that sits over arbitrary scrolling content.
  ///
  /// The app bar needs roughly twice the nav bar's, and the reason is what is
  /// underneath rather than what the bar is. A navigation bar floats over a list
  /// of muted text; an app bar floats over whatever the user scrolls into it,
  /// including a saturated blue message bubble. At σ12 that bubble stayed a
  /// recognisable blue *shape* under the bar — a smear with an edge, which reads
  /// as a rendering fault rather than as a pane. Enough blur to dissolve the
  /// shape is what turns it back into a tint.
  static const double heavyBlur = 28;

  @override
  Widget build(BuildContext context) {
    final chat = context.chatTheme;
    final shape = LiquidRoundedSuperellipse(borderRadius: cornerRadius);

    if (!GlassScope.of(context)) {
      return Container(
        padding: padding,
        decoration: ShapeDecoration(
          color: fallbackColor ?? chat.raisedSurface,
          shape: shape.copyWith(side: BorderSide(color: chat.glassStroke)),
          shadows: shadows,
        ),
        child: child,
      );
    }

    return DecoratedBox(
      // The shadow sits outside the glass: a glass layer captures and refracts
      // its own backdrop, and a shadow inside would be refracted along with it.
      decoration: ShapeDecoration(shape: shape, shadows: shadows),
      child: _GlassEdge(
        shape: shape,
        stroke: chat.glassStroke,
        highlight: chat.glassHighlight,
        child: GlassContainer(
          // A superellipse, not a circular-radius rounded rect. It is what
          // iOS 26 uses, and the continuous curvature is most of why the corners
          // read as moulded rather than cut.
          shape: shape,
          settings: LiquidGlassSettings(
            blur: blur,
            glassColor: chat.glassFill,
            // No boost at all. The package raises saturation by default so
            // glass looks lively over colourful content, but on a neutral
            // palette the only thing there is to boost is the single accent —
            // so the effect was precisely inverted: it left every quiet surface
            // untouched and made the one blue element garish wherever chrome
            // passed over it.
            saturation: 1,
          ),
          // Premium runs the full Impeller pipeline — texture capture,
          // refraction and chromatic aberration. Correct here specifically
          // because these are *fixed* surfaces: the package warns premium can
          // misrender inside a scrollable, and none of this chrome scrolls.
          quality: GlassQuality.premium,
          // Isolates this surface's backdrop capture, which is what stops the
          // two glass layers on the chat screen sampling each other.
          useOwnLayer: true,
          padding: padding,
          child: child,
        ),
      ),
    );
  }
}

/// The edge of a glass panel: a full outline plus a brighter top rim.
///
/// Two strokes on the same path, not one. A uniform outline says "here is the
/// boundary"; what says *glass* is that the top edge is brighter than the
/// bottom, because a pane lit from above catches light along its upper rim and
/// almost none along its lower one. Painting a flat 1px line all the way round
/// is the difference between a panel and a pane.
///
/// The highlight is a vertical gradient rather than a separate top-edge segment,
/// which is why it wraps the shoulders and fades out down the sides instead of
/// stopping abruptly at the corners — the same way a real specular does.
class _GlassEdge extends StatelessWidget {
  const _GlassEdge({
    required this.shape,
    required this.stroke,
    required this.highlight,
    required this.child,
  });

  final LiquidShape shape;
  final Color stroke;
  final Color highlight;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      // Over the glass, not under it: the refraction would otherwise wash the
      // edge out, which is exactly the detail that must survive.
      foregroundPainter: _GlassEdgePainter(
        shape: shape,
        stroke: stroke,
        highlight: highlight,
      ),
      child: child,
    );
  }
}

class _GlassEdgePainter extends CustomPainter {
  const _GlassEdgePainter({
    required this.shape,
    required this.stroke,
    required this.highlight,
  });

  final LiquidShape shape;
  final Color stroke;
  final Color highlight;

  /// Fraction of the panel's height the highlight survives to.
  ///
  /// Short. Past roughly a third it stops reading as a lit edge and starts
  /// reading as a gradient fill leaking out of the border.
  static const double _falloff = 0.35;

  @override
  void paint(Canvas canvas, Size size) {
    // Inset by half the stroke so a 1px line lands *inside* the shape rather
    // than straddling it, which would leave half a pixel of it outside the clip
    // and read as a soft edge.
    final rect = (Offset.zero & size).deflate(0.5);
    if (rect.isEmpty) return;
    final path = shape.getOuterPath(rect);

    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = stroke,
    );

    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..shader = ui.Gradient.linear(
          rect.topCenter,
          Offset(rect.center.dx, rect.top + rect.height * _falloff),
          [highlight, highlight.withValues(alpha: 0)],
        ),
    );
  }

  @override
  bool shouldRepaint(_GlassEdgePainter oldDelegate) =>
      oldDelegate.shape != shape ||
      oldDelegate.stroke != stroke ||
      oldDelegate.highlight != highlight;
}

/// The ambient wash that gives glass something to refract.
///
/// Glass bends what is behind it, so over a flat fill it bends nothing and reads
/// as slightly murky plastic. Two large, heavily blurred spots — one warm-ish
/// slate high on the right, one deeper navy low on the left — give the chrome
/// real structure to distort instead of a uniform field.
///
/// **Why blurred circles rather than radial gradients.** A radial gradient falls
/// off linearly and produces a visible ring where it terminates. A Gaussian has
/// no such edge, so at this scale the spots read as depth in the room rather
/// than as shapes on the page. That is the entire difference between glass that
/// looks lit and glass that looks like a grey rectangle.
///
/// They are also the one place a hue is allowed back in. It survives at roughly
/// a percent of effective opacity after the blur, which is enough for refraction
/// to have something to separate and far too little to tint a surface — the
/// thing the neutral ramp exists to avoid.
///
/// Renders nothing when glass is disabled, so the plain theme stays plain.
class AppBackdrop extends StatelessWidget {
  const AppBackdrop({required this.child, super.key});

  final Widget child;

  /// Blur applied to each spot. Large enough that no edge survives it.
  static const double _spotBlur = 80;

  @override
  Widget build(BuildContext context) {
    if (!GlassScope.of(context)) return child;

    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Stack(
      children: [
        // One boundary around both spots, not one each. They never change, so
        // this lets the compositor cache the whole blurred layer and reuse it
        // instead of re-running two 80-sigma filters on every frame — which at
        // full-screen size is the difference between free and expensive.
        Positioned.fill(
          child: RepaintBoundary(
            child: IgnorePointer(
              child: ImageFiltered(
                imageFilter: ui.ImageFilter.blur(
                  sigmaX: _spotBlur,
                  sigmaY: _spotBlur,
                ),
                child: Stack(
                  children: [
                    _AmbientSpot(
                      alignment: const Alignment(1.1, -0.85),
                      color: isDark
                          ? const Color(0xFF1E293B).withValues(alpha: 0.30)
                          : Colors.white,
                      diameter: 300,
                    ),
                    _AmbientSpot(
                      alignment: const Alignment(-1.0, 0.9),
                      color: isDark
                          ? const Color(0xFF0F172A).withValues(alpha: 0.40)
                          : const Color(0xFF64748B).withValues(alpha: 0.10),
                      diameter: 340,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        child,
      ],
    );
  }
}

/// One blurred disc of the ambient wash.
class _AmbientSpot extends StatelessWidget {
  const _AmbientSpot({
    required this.alignment,
    required this.color,
    required this.diameter,
  });

  final Alignment alignment;
  final Color color;
  final double diameter;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: alignment,
      child: Container(
        width: diameter,
        height: diameter,
        decoration: BoxDecoration(shape: BoxShape.circle, color: color),
      ),
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
      flexibleSpace: isGlass ? const _GlassBarPane() : null,
    );
  }
}

/// The glass pane behind an app bar, oversized so only its bottom edge shows.
///
/// A glass surface is lit as a physical object: the shader draws a specular rim
/// around the *whole* shape. On a floating pill that rim is the best part of the
/// effect — it is what reads as a polished edge. On a bar that spans the screen
/// it is wrong, because it outlines the top and sides too and the result looks
/// like a pasted-on rectangle rather than a pane the content passes beneath.
///
/// So the pane is drawn larger than the bar and clipped to it: the left, right
/// and top rims fall outside the visible area, and only the bottom edge — the
/// one that genuinely divides chrome from content — survives.
class _GlassBarPane extends StatelessWidget {
  const _GlassBarPane();

  /// Enough to push the rim and its glow past the clip on every edge.
  static const double _bleed = 48;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final topInset = MediaQuery.paddingOf(context).top;

    return ClipRect(
      child: OverflowBox(
        // Anchored to the bottom so the bar's lower edge is the one that lines
        // up; everything else overflows and is clipped away.
        alignment: Alignment.bottomCenter,
        maxWidth: double.infinity,
        maxHeight: double.infinity,
        child: SizedBox(
          width: size.width + _bleed * 2,
          height: kToolbarHeight + topInset + _bleed,
          child: const GlassSurface(
            cornerRadius: 0,
            blur: GlassSurface.heavyBlur,
            child: SizedBox.expand(),
          ),
        ),
      ),
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
