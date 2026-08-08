import 'package:flutter/material.dart';

/// Raw brand colours, taken from the EVDEkimi mark.
///
/// These are the only literal colours in the app; everything else reads from
/// `ColorScheme` or `ChatTheme`. Keeping the literals in one file is what makes
/// it possible to answer "is this on-brand?" by reading a single screen of code.
///
/// The identity is a white geometric roofline on deep navy — a property brand,
/// not a tech one. Two consequences follow:
///
/// * **Navy is the primary, and it is dark.** Filled buttons and outgoing
///   message bubbles are near-black navy with white text. That reads as
///   considered and premium, which is the register real estate sells in; a
///   bright saturated primary would read as a consumer app.
/// * **The neutral ramp is navy-tinted, not neutral grey.** Greys mixed toward
///   the brand hue keep large surfaces feeling related to the mark instead of
///   merely adjacent to it.
abstract final class AppPalette {
  /// The mark's background. Primary brand colour.
  static const Color brandNavy = Color(0xFF1B2A41);

  /// Lifted navy for dark mode, where the base navy would disappear into the
  /// surface behind it. Still unmistakably the same hue.
  static const Color brandNavyLifted = Color(0xFF5A7CA8);

  /// Deepest tone, for dark-mode fills that must sit under white text.
  static const Color brandNavyDeep = Color(0xFF0C1421);

  /// Warm brass. Used only where something must read as *distinct* from the
  /// navy system — the on-device badge, a queued state. Never decoratively:
  /// spending it dilutes the one accent the brand has.
  static const Color brandBrass = Color(0xFFC08A2E);

  /// Navy-tinted neutral ramp.
  ///
  /// Hand-tuned rather than generated: Material's neutral ramp carries a violet
  /// cast from the seed, which fights a navy brand on the large surfaces that
  /// make up most of a chat screen.
  static const Color ink900 = Color(0xFF0B1220);
  static const Color ink800 = Color(0xFF111C2E);
  static const Color ink700 = Color(0xFF1B2739);
  static const Color ink600 = Color(0xFF27364C);
  static const Color ink500 = Color(0xFF3A4C68);
  static const Color ink400 = Color(0xFF64748B);
  static const Color ink300 = Color(0xFF94A3B8);
  static const Color ink200 = Color(0xFFCBD5E1);
  static const Color ink100 = Color(0xFFE2E8F0);
  static const Color ink50 = Color(0xFFF1F5F9);
  static const Color white = Color(0xFFFFFFFF);

  /// Page background in light mode.
  ///
  /// Deliberately not white. Cards and message bubbles are white, so the page
  /// beneath them has to be a shade darker for them to read as raised surfaces —
  /// white-on-white needs borders or shadows to separate, and both are heavier
  /// than a two-percent tonal step.
  static const Color canvas = Color(0xFFF4F6FA);

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
