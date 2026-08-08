import 'package:flutter/material.dart';

/// Raw colour values. The only literal colours in the app.
///
/// Everything else reads from `ColorScheme` or `ChatTheme`, which is what makes
/// it possible to answer "is this on-brand?" by reading one screen of code.
///
/// ## The system
///
/// Four values are fixed, and the rest of the file exists to serve them:
///
/// | | | |
/// |---|---|---|
/// | `#0F044C` | deep indigo | [ink900] |
/// | `#141E61` | navy | [ink800] |
/// | `#787A91` | slate | [ink400] |
/// | `#EEEEEE` | mist | [ink50] |
///
/// They are four steps along **one hue axis** — a value ramp, not a colour
/// scheme. There is no accent in it and no second hue, and the whole design
/// follows from taking that seriously: hierarchy is carried by lightness alone,
/// and the palette desaturates as it lightens, from saturated indigo at the
/// bottom to plain grey at the top.
///
/// ## Elevation is the two navies
///
/// In dark mode `#0F044C` is the page and `#141E61` is anything raised above it.
/// That single relationship replaces shadows, borders and Material's elevation
/// overlays. It also fixes a real bug: cards previously used
/// `surfaceContainerLowest`, which in Material's dark ramp is the *darkest* tone
/// in the set and resolved to exactly the scaffold colour — the card structure
/// rendered in light mode and was invisible in dark.
///
/// ## The one saturated colour
///
/// [beacon] is the sole exception, reserved for the on-device signal. A
/// single-hue ramp has no capacity to mark anything: [ink400] on a card is
/// indistinguishable from ordinary secondary text. Rather than introduce a
/// second hue, [beacon] spikes the *saturation* of the hue already here, so the
/// app stays one colour end to end. Spending it anywhere else would take the
/// signal away from the only thing that needs one.
///
/// Status colours are deliberately outside all of this. An error cannot be
/// rendered in navy, so they stay recognisable first and on-palette second.
abstract final class AppPalette {
  // ------------------------------------------------------- the ramp

  /// Below the darkest given value, for wells that must recede *under* the
  /// page — a code block on the dark theme, chiefly.
  static const Color ink950 = Color(0xFF070120);

  /// Deep indigo. Dark-mode page, light-mode text, deepest fills.
  static const Color ink900 = Color(0xFF0F044C);

  /// Navy. The brand colour, and every raised surface in dark mode.
  static const Color ink800 = Color(0xFF141E61);

  static const Color ink700 = Color(0xFF202B70);
  static const Color ink600 = Color(0xFF3A4380);

  /// Light-mode secondary text. [ink400] itself only reaches 3.7:1 on [ink50],
  /// which is under the 4.5:1 floor for body copy; this clears it at 5.2:1.
  static const Color ink500 = Color(0xFF5A5F87);

  /// Slate. Borders, disabled states, and tertiary marks.
  static const Color ink400 = Color(0xFF787A91);

  /// Dark-mode secondary text, for the same reason [ink500] exists.
  static const Color ink300 = Color(0xFF9EA0B2);

  static const Color ink200 = Color(0xFFC6C7D1);
  static const Color ink100 = Color(0xFFDFE0E6);

  /// Mist. Light-mode page, dark-mode text.
  static const Color ink50 = Color(0xFFEEEEEE);

  static const Color white = Color(0xFFFFFFFF);

  // ------------------------------------------------------- brand roles

  /// Filled buttons and outgoing message bubbles.
  static const Color brandNavy = ink800;

  /// Deepest brand tone, under light text.
  static const Color brandNavyDeep = ink900;

  /// Dark mode needs the brand *above* the page rather than below it, and
  /// [brandNavy] on an [ink900] background is a 1.2:1 step — correct for a card,
  /// far too quiet for a control. Same hue, lifted until it carries text.
  static const Color brandNavyLifted = Color(0xFF8F98E8);

  /// Page background in light mode.
  ///
  /// Not white, because cards are: the page has to sit a step below them for the
  /// grouping to read without borders or shadows.
  static const Color canvas = ink50;

  // ------------------------------------------------------- the signal

  /// The on-device marker, and nothing else.
  ///
  /// Same hue as the ramp, taken to full saturation. Two values because one
  /// cannot clear contrast on both a near-white page and a deep indigo one.
  static const Color beaconLight = Color(0xFF4A55D6);
  static const Color beaconDark = Color(0xFF7C87FF);

  // ------------------------------------------------------- status

  /// Functional, not decorative. Tuned toward the ramp's coolness so they sit
  /// with it, but never so far that a warning stops looking like a warning.
  static const Color successLight = Color(0xFF16794D);
  static const Color successDark = Color(0xFF5FD3A0);

  static const Color dangerLight = Color(0xFFC42B32);
  static const Color dangerDark = Color(0xFFFF8A93);

  static const Color warningLight = Color(0xFF8A5A00);
  static const Color warningDark = Color(0xFFF0B252);

  static const Color infoLight = Color(0xFF1B5FA8);
  static const Color infoDark = Color(0xFF8FBEEE);
}
