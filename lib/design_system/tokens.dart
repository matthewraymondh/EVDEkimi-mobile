import 'package:flutter/widgets.dart';

/// Design tokens.
///
/// Every magic number in the UI resolves to one of these. Two reasons this is
/// worth the indirection: a spacing change becomes one edit instead of a
/// codebase sweep, and — because an AI agent wrote most of the first-draft
/// widgets — a reviewer can spot "invented" values (`padding: 13`) instantly.
abstract final class AppSpacing {
  /// 4pt base grid. Names are sizes, not roles, so they stay honest.
  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
  static const double xxxl = 48;

  /// Horizontal page gutter. Tuned for one-handed reach on a 390pt viewport.
  static const double gutter = 20;

  /// Maximum text column width. Long AI answers become unreadable past roughly
  /// 70 characters, which is what this works out to at the body size.
  static const double readableMaxWidth = 720;
}

/// Corner radii.
///
/// Tuned to the iOS control scale rather than Material's: inputs and chips at
/// 12, cards at 16, floating chrome at 24. Those three carry almost everything,
/// and keeping them a step apart is what stops nested surfaces looking like
/// concentric arcs.
///
/// The values are also the *shader's* radius for glass surfaces, which is why
/// they are exposed as plain doubles alongside the `BorderRadius` forms —
/// `LiquidRoundedSuperellipse` takes a number, not a `BorderRadius`.
abstract final class AppRadius {
  static const double xsValue = 6;
  static const double smValue = 8;

  /// Inputs, chips, and anything the finger treats as a single control.
  static const double mdValue = 12;

  /// Cards and grouped list containers.
  static const double lgValue = 16;

  static const double xlValue = 20;

  /// Floating chrome: the navigation bar and the composer.
  static const double xxlValue = 24;

  static const Radius xs = Radius.circular(xsValue);
  static const Radius sm = Radius.circular(smValue);
  static const Radius md = Radius.circular(mdValue);
  static const Radius lg = Radius.circular(lgValue);
  static const Radius xl = Radius.circular(xlValue);
  static const Radius xxl = Radius.circular(xxlValue);
  static const Radius pill = Radius.circular(999);

  static const BorderRadius allXs = BorderRadius.all(xs);
  static const BorderRadius allSm = BorderRadius.all(sm);
  static const BorderRadius allMd = BorderRadius.all(md);
  static const BorderRadius allLg = BorderRadius.all(lg);
  static const BorderRadius allXl = BorderRadius.all(xl);
  static const BorderRadius allXxl = BorderRadius.all(xxl);
  static const BorderRadius allPill = BorderRadius.all(pill);

  /// Chat bubbles: three round corners and one tucked corner pointing at the
  /// sender, which conveys direction without drawing a tail.
  static const BorderRadius bubbleOutgoing = BorderRadius.only(
    topLeft: lg,
    topRight: lg,
    bottomLeft: lg,
    bottomRight: xs,
  );

  static const BorderRadius bubbleIncoming = BorderRadius.only(
    topLeft: lg,
    topRight: lg,
    bottomLeft: xs,
    bottomRight: lg,
  );
}

/// Motion durations.
///
/// Chosen so interface feedback lands inside the ~100ms window that reads as
/// instant, while content transitions get enough time to be followed by the eye.
abstract final class AppDuration {
  static const Duration instant = Duration(milliseconds: 90);
  static const Duration fast = Duration(milliseconds: 150);
  static const Duration medium = Duration(milliseconds: 250);
  static const Duration slow = Duration(milliseconds: 400);

  /// Cadence of the "assistant is typing" dot animation.
  static const Duration typingCycle = Duration(milliseconds: 1200);

  /// Blink period of the streaming caret.
  static const Duration caretBlink = Duration(milliseconds: 900);

  /// How long a transient snack/toast stays up.
  static const Duration toast = Duration(seconds: 4);
}

abstract final class AppCurve {
  /// Default for entrances and size changes: quick start, soft settle.
  static const Curve standard = Curves.easeOutCubic;

  /// For elements leaving the screen.
  static const Curve exit = Curves.easeInCubic;

  /// Slight overshoot, used sparingly (send button, new-message pop).
  static const Curve emphasised = Curves.easeOutBack;
}

/// Layout breakpoints.
///
/// The app is phone-first, but a chat transcript on a tablet or a foldable
/// deserves the list and thread side by side rather than a stretched column.
abstract final class AppBreakpoint {
  static const double compact = 600;
  static const double medium = 840;

  static bool isExpanded(double width) => width >= medium;

  static bool isCompact(double width) => width < compact;
}

abstract final class AppElevation {
  static const double none = 0;
  static const double low = 1;
  static const double medium = 3;
  static const double high = 8;
}

/// Named durations/sizes for the icon and hit-target system.
abstract final class AppSizes {
  /// Minimum interactive target. Matches the 48dp Material accessibility floor.
  static const double minTapTarget = 48;

  static const double iconSm = 18;
  static const double iconMd = 22;
  static const double iconLg = 28;

  static const double avatarSm = 28;
  static const double avatarMd = 36;

  static const double composerMaxHeight = 160;
}
