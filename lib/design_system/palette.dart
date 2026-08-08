import 'package:flutter/material.dart';

/// Raw brand colours.
///
/// These are the only literal colours in the app; everything else reads from
/// `ColorScheme` or `ChatTheme`. Keeping the literals in one file is what makes
/// it possible to answer "is this colour on-brand?" by reading a single screen
/// of code.
abstract final class AppPalette {
  /// EVDEkimi teal. Used as the seed so the generated tonal palettes stay
  /// harmonically related to the brand mark rather than to Material's default
  /// violet.
  static const Color brandTeal = Color(0xFF0E7C6B);
  static const Color brandTealBright = Color(0xFF19A38C);
  static const Color brandTealDeep = Color(0xFF04322C);

  /// Warm secondary, used for accents that must not read as "primary action" —
  /// on-device badges, model chips.
  static const Color brandAmber = Color(0xFFC98A2B);

  /// Neutral ramp. Hand-tuned rather than generated: Material's neutral ramp
  /// carries a violet tint from the seed, which fights the teal in dark mode.
  static const Color ink900 = Color(0xFF08100F);
  static const Color ink800 = Color(0xFF0D1716);
  static const Color ink700 = Color(0xFF14211F);
  static const Color ink600 = Color(0xFF1D2E2B);
  static const Color ink500 = Color(0xFF2A403C);
  static const Color ink400 = Color(0xFF5A716C);
  static const Color ink300 = Color(0xFF8FA5A0);
  static const Color ink200 = Color(0xFFC4D3CF);
  static const Color ink100 = Color(0xFFE4EDEA);
  static const Color ink50 = Color(0xFFF3F8F6);
  static const Color white = Color(0xFFFFFFFF);

  /// Page background in light mode.
  ///
  /// Deliberately *not* white. Cards and message bubbles are white, so the page
  /// beneath them has to be a shade darker for them to read as raised surfaces —
  /// white-on-white needs borders or shadows to separate, and both are heavier
  /// than a two-percent tonal step. Neutral rather than teal-tinted so it stays
  /// quiet under the brand colour.
  static const Color canvas = Color(0xFFF4F6F9);

  /// Semantic status colours, defined for both themes so contrast holds.
  static const Color successLight = Color(0xFF1E7A44);
  static const Color successDark = Color(0xFF6EDBA0);

  static const Color dangerLight = Color(0xFFB3261E);
  static const Color dangerDark = Color(0xFFFF8A80);

  static const Color warningLight = Color(0xFF8A5A00);
  static const Color warningDark = Color(0xFFFFC46B);

  static const Color infoLight = Color(0xFF00658F);
  static const Color infoDark = Color(0xFF7FD1F5);
}
