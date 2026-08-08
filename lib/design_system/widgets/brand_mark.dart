import 'package:evdekimi_ai/design_system/chat_theme.dart';
import 'package:flutter/material.dart';

/// The EVDEkimi mark, recoloured to suit whichever theme it lands on.
///
/// The shipped asset is **monochrome white on transparency** — the mark as it
/// appears on the company's navy plate. Dropped in as-is it is invisible in
/// light mode, where the page is `#F8FAFC` and cards are white.
///
/// Rather than ship two files that can drift apart, it is tinted at render time
/// with [BlendMode.srcIn], which replaces every pixel's colour and keeps its
/// alpha. That is lossless here precisely *because* the source is one colour:
/// there is no shading to flatten. A logo with more than one tone would need a
/// real second asset instead.
///
/// The default is `onSurface`, so the mark reads as the darkest thing on a light
/// page and the brightest on a dark one — which is what a monochrome logo is
/// for.
class BrandMark extends StatelessWidget {
  const BrandMark({this.size = 88, this.color, super.key});

  /// Edge length of the asset's **canvas**, not of the visible mark.
  ///
  /// The two differ a lot: the logo occupies 104×84 px of a 200×200 file, so
  /// roughly half the box is transparent padding and the mark renders at about
  /// half whatever is passed here. `size: 88` shows a mark around 46 pt wide.
  ///
  /// That padding also sets the sharpness ceiling. 104 source pixels stay crisp
  /// up to about 35 pt on a 3× screen, so the sizes used here trade a little
  /// softness for presence — the right way round for a logo, whose edges are
  /// antialiased curves rather than text. A 512 px export would remove the
  /// trade entirely.
  final double size;

  /// Overrides the tint. Pass this when the mark sits on a fill of its own —
  /// on a dark plate it should stay white rather than following the theme.
  final Color? color;

  static const String asset = 'assets/images/evdekimi.png';

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      asset,
      width: size,
      height: size,
      color: color ?? context.colors.onSurface,
      colorBlendMode: BlendMode.srcIn,
      // A logo carries no information a screen reader needs beyond the name,
      // and every place it appears already has the name in text next to it.
      excludeFromSemantics: true,
    );
  }
}
