import 'package:flutter/material.dart';

/// Raw colour values. The only literal colours in the app.
///
/// Everything else reads from `ColorScheme` or `ChatTheme`, which is what makes
/// it possible to answer "is this on-brand?" by reading one screen of code.
///
/// ## A neutral ramp and one accent
///
/// The greys are a true neutral scale — no blue cast, no purple cast, nothing
/// borrowed from a seed colour. That is the whole point of them: glass only
/// reads as glass when the surface behind it is quiet, and a tinted grey
/// competes with the refraction instead of supporting it.
///
/// | | | |
/// |---|---|---|
/// | [zinc950] `#09090B` | dark page |
/// | [zinc900] `#18181B` | dark glass fill |
/// | [zinc400] `#A1A1AA` | dark secondary text |
/// | [zinc100] `#F4F4F5` | dark primary text |
/// | [slate50] `#F8FAFC` | light page |
///
/// Hierarchy comes from lightness and from the hairline strokes in
/// `ChatTheme.glassStroke`, not from colour. [accent] is the only saturated
/// value in the system and carries every active state — the selected tab, the
/// send button, the user's own messages.
///
/// Status colours sit outside all of this. An error cannot be rendered in grey,
/// so they stay recognisable first and on-palette second.
abstract final class AppPalette {
  // ------------------------------------------------------- neutrals

  /// Page background in dark mode. Deep enough to switch OLED pixels off.
  static const Color zinc950 = Color(0xFF09090B);

  /// Every glass fill and raised surface in dark mode.
  static const Color zinc900 = Color(0xFF18181B);

  static const Color zinc800 = Color(0xFF27272A);
  static const Color zinc700 = Color(0xFF3F3F46);
  static const Color zinc600 = Color(0xFF52525B);

  /// Light-mode secondary text. [zinc400] is the muted tone in dark mode, but on
  /// a near-white page it lands at 2.5:1 — nowhere near the 4.5:1 floor for body
  /// copy, and this role sets every excerpt and caption in the app.
  static const Color zinc500 = Color(0xFF71717A);

  /// Dark-mode secondary text.
  static const Color zinc400 = Color(0xFFA1A1AA);

  static const Color zinc300 = Color(0xFFD4D4D8);
  static const Color zinc200 = Color(0xFFE4E4E7);

  /// Dark-mode primary text. Off-white rather than pure white: at full white the
  /// halation around glyphs on a near-black background is genuinely tiring.
  static const Color zinc100 = Color(0xFFF4F4F5);

  static const Color zinc50 = Color(0xFFFAFAFA);
  static const Color white = Color(0xFFFFFFFF);

  /// Page background in light mode.
  ///
  /// The one place a trace of blue survives, and deliberately: cards are pure
  /// white, so the page has to sit a step below them, and a *cool* step reads as
  /// depth where a warm one reads as dirt.
  static const Color slate50 = Color(0xFFF8FAFC);

  // ------------------------------------------------------- accent

  /// Active states, in dark mode.
  ///
  /// Paired with [zinc950] as its foreground, not white — this is a bright tone
  /// on a dark theme, so the text that sits on it has to be dark. White on it is
  /// 3.7:1, which fails for button labels.
  static const Color accent = Color(0xFF3B82F6);

  /// Active states in light mode, and filled surfaces in both.
  ///
  /// One step deeper than [accent] so white text clears the floor on it, which
  /// [accent] itself does not.
  static const Color accentDeep = Color(0xFF2563EB);

  /// The accent, quietened for large washes and inactive tints.
  static const Color accentMuted = Color(0xFF60A5FA);

  // ------------------------------------------------------- status

  /// Functional, not decorative. Neutral-friendly, but never so restrained that
  /// a warning stops looking like a warning.
  static const Color successLight = Color(0xFF047857);
  static const Color successDark = Color(0xFF34D399);

  static const Color dangerLight = Color(0xFFDC2626);
  static const Color dangerDark = Color(0xFFF87171);

  static const Color warningLight = Color(0xFFB45309);
  static const Color warningDark = Color(0xFFFBBF24);

  static const Color infoLight = Color(0xFF0369A1);
  static const Color infoDark = Color(0xFF7DD3FC);
}
