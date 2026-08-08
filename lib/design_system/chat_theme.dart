import 'package:evdekimi_ai/design_system/palette.dart';
import 'package:flutter/material.dart';

/// Chat-surface colours that `ColorScheme` has no slot for.
///
/// Bubble fills, the streaming caret, code-block chrome and the on-device badge
/// are domain concepts, not Material roles. Putting them in a [ThemeExtension]
/// rather than reaching for `Colors.grey[200]` inside widgets means dark mode is
/// resolved in one place and a widget can never render a hard-coded colour that
/// only works in one theme.
@immutable
class ChatTheme extends ThemeExtension<ChatTheme> {
  const ChatTheme({
    required this.glassFill,
    required this.glassStroke,
    required this.glassHighlight,
    required this.dockFill,
    required this.dockStroke,
    required this.dockHighlight,
    required this.dockActiveTop,
    required this.dockActiveBottom,
    required this.dockActiveBorder,
    required this.raisedSurface,
    required this.raisedBorder,
    required this.outgoingBubble,
    required this.outgoingBubbleEnd,
    required this.onOutgoingBubble,
    required this.incomingBubble,
    required this.onIncomingBubble,
    required this.bubbleBorder,
    required this.caret,
    required this.codeBackground,
    required this.codeBorder,
    required this.inlineCodeBackground,
    required this.composerBackground,
    required this.composerBorder,
    required this.onDeviceAccent,
    required this.offlineBanner,
    required this.onOfflineBanner,
    required this.success,
    required this.warning,
    required this.danger,
    required this.skeletonBase,
    required this.skeletonHighlight,
  });

  static const ChatTheme light = ChatTheme(
    // Glass over a near-white page has almost nothing to darken, so the fill is
    // a whitening rather than a tint, and the stroke does most of the work of
    // saying where the panel ends.
    glassFill: Color(0x99FFFFFF),
    // 10%, not the 6% this started at. On a near-white page a 6% line is
    // present in a colour picker and absent to the eye — the navigation bar
    // read as a pale blob with no edge at all. Dark mode does not need the
    // same push, because a light line on a dark ground carries much further
    // than a dark line on a light one at equal alpha.
    glassStroke: Color(0x1A000000),
    // Light mode still lights from above, but a white rim on a near-white panel
    // is invisible, so the highlight is what a bright edge actually looks like
    // there: *less* of the darkening the rest of the outline carries.
    glassHighlight: Color(0x0AFFFFFF),
    // White at 55%, so the dock resolves toward white over a near-white page.
    dockFill: Color(0x8CFFFFFF),
    // Dark, not white. The reference docks use a white edge because they float
    // over photographs; over a #F8FAFC page a white line is the page.
    dockStroke: Color(0x1A000000),
    // A brighter top edge in light mode means *less* of the darkening the rest
    // of the outline carries, which is what a lit edge actually looks like here.
    dockHighlight: Color(0x99FFFFFF),
    dockActiveTop: Color(0x14000000),
    dockActiveBottom: Color(0x0A000000),
    // Dark, not white. A white border on a near-white dock is the dock.
    dockActiveBorder: Color(0x1A000000),
    raisedSurface: AppPalette.white,
    // Heavier than the glass stroke, and it has to be. A white card on a
    // #F8FAFC page is 1.05:1 — the tonal step is not a separation at all, so
    // this line *is* the card's edge rather than a refinement of it.
    raisedBorder: Color(0x1F000000),
    // The user's own messages carry the accent: it is the one element on screen
    // that should feel like "you", and it anchors the eye when scanning.
    outgoingBubble: AppPalette.accentDeep,
    outgoingBubbleEnd: AppPalette.accentPressed,
    onOutgoingBubble: AppPalette.white,
    // Assistant messages are white on the canvas rather than a tinted fill.
    // Model output is long-form text and needs to read like a document page.
    incomingBubble: AppPalette.white,
    onIncomingBubble: AppPalette.zinc900,
    bubbleBorder: AppPalette.zinc200,
    caret: AppPalette.accentDeep,
    codeBackground: AppPalette.zinc900,
    codeBorder: AppPalette.zinc800,
    inlineCodeBackground: AppPalette.zinc200,
    composerBackground: AppPalette.white,
    composerBorder: AppPalette.zinc200,
    onDeviceAccent: AppPalette.accentDeep,
    offlineBanner: AppPalette.zinc800,
    onOfflineBanner: AppPalette.zinc100,
    success: AppPalette.successLight,
    warning: AppPalette.warningLight,
    danger: AppPalette.dangerLight,
    skeletonBase: AppPalette.zinc200,
    skeletonHighlight: AppPalette.zinc100,
  );

  static const ChatTheme dark = ChatTheme(
    // `Colors.white.withOpacity(0.05)` over the page, expressed as the literal
    // it resolves to. Anything heavier stops being glass and becomes a panel.
    glassFill: Color(0x0DFFFFFF),
    glassStroke: Color(0x14FFFFFF),
    glassHighlight: Color(0x1FFFFFFF),
    // Several times the fill of the composer, and deliberately so: a composer
    // is a film you type through, a dock is a slab you rest controls on. Under
    // 45% the dock stops being an object and becomes a smudge with icons in it.
    dockFill: Color(0x73121214),
    dockStroke: Color(0x26FFFFFF),
    dockHighlight: Color(0x40FFFFFF),
    dockActiveTop: Color(0x33FFFFFF),
    dockActiveBottom: Color(0x14FFFFFF),
    dockActiveBorder: Color(0x40FFFFFF),
    raisedSurface: AppPalette.zinc900,
    raisedBorder: Color(0x14FFFFFF),
    outgoingBubble: AppPalette.accentDeep,
    outgoingBubbleEnd: AppPalette.accentPressed,
    onOutgoingBubble: AppPalette.white,
    incomingBubble: AppPalette.zinc900,
    onIncomingBubble: AppPalette.zinc100,
    bubbleBorder: AppPalette.zinc800,
    caret: AppPalette.accent,
    // Below the page, not above it: a code block is a well, and pure black is
    // the one tone that sits under zinc950.
    codeBackground: Color(0xFF000000),
    codeBorder: AppPalette.zinc800,
    inlineCodeBackground: AppPalette.zinc800,
    composerBackground: AppPalette.zinc900,
    composerBorder: AppPalette.zinc800,
    onDeviceAccent: AppPalette.accent,
    offlineBanner: AppPalette.zinc800,
    onOfflineBanner: AppPalette.zinc100,
    success: AppPalette.successDark,
    warning: AppPalette.warningDark,
    danger: AppPalette.dangerDark,
    skeletonBase: AppPalette.zinc800,
    skeletonHighlight: AppPalette.zinc700,
  );

  /// Translucent fill painted inside a glass panel.
  ///
  /// Glass needs *some* body or it reads as a smudge, but the fill is the first
  /// thing to get overdone: past roughly 10% in dark mode the refraction stops
  /// being visible and the panel just looks like frosted plastic.
  final Color glassFill;

  /// Brightness added to the *top* rim of a glass panel.
  ///
  /// What separates a pane from a panel. A uniform outline says where the edge
  /// is; an edge that is brighter at the top says the thing is lit from above
  /// and has physical depth, which is the whole illusion.
  final Color glassHighlight;

  /// The floating dock's own material, which is heavier than the rest of the
  /// chrome on purpose.
  ///
  /// A dark fill over a near-black page is a small tonal step — deliberately.
  /// The reference docks read as objects because of their *edges*, not their
  /// fills: they float over photographs, where a dark pane has plenty to darken.
  /// Over a #09090B page there is almost nothing, so [dockStroke] and
  /// [dockHighlight] are what carry the shape, which is why both are several
  /// times stronger than [glassStroke].
  final Color dockFill;
  final Color dockStroke;
  final Color dockHighlight;

  /// The capsule that glides under the selected destination.
  ///
  /// Lighter at the top than the bottom, which is the same rule the dock's own
  /// rim follows: a pane lit from above is brightest where it faces the light.
  /// A flat tint reads as a painted rectangle; the falloff is what makes it read
  /// as a second sheet of glass resting on the first.
  ///
  /// Its border is stronger than [dockStroke] on purpose — it sits *on* glass
  /// rather than against the page, so it needs more to separate from.
  final Color dockActiveTop;
  final Color dockActiveBottom;
  final Color dockActiveBorder;

  /// The 1px hairline around every glass panel.
  ///
  /// This is what makes glass read as glass rather than as a blurred region.
  /// A real pane has an edge that catches light; without one the eye has no
  /// boundary to attach the refraction to, and the effect reads as a rendering
  /// artefact instead of a material.
  final Color glassStroke;

  /// Fill for a card that must read as sitting above the page.
  ///
  /// Resolves in opposite directions per theme: lighter than the background in
  /// dark mode, whiter than the canvas in light. Use this rather than a
  /// `surfaceContainer*` role for anything raised.
  final Color raisedSurface;

  /// Hairline that separates rows inside a [raisedSurface] card.
  final Color raisedBorder;

  /// Top of the outgoing bubble's fill.
  final Color outgoingBubble;

  /// Bottom of it.
  ///
  /// A gradient inside one hue, not across two. The distinction matters: a
  /// two-hue decorative gradient is the hallmark of a surface designed by
  /// defaults, whereas one step of the same colour is a light-falloff cue and
  /// reads as depth. Contrast is checked against this end, since it is darker.
  final Color outgoingBubbleEnd;

  final Color onOutgoingBubble;
  final Color incomingBubble;
  final Color onIncomingBubble;
  final Color bubbleBorder;

  /// Colour of the block caret shown while tokens are still arriving.
  final Color caret;

  final Color codeBackground;
  final Color codeBorder;
  final Color inlineCodeBackground;

  final Color composerBackground;
  final Color composerBorder;

  /// Accent for anything indicating local/on-device execution.
  final Color onDeviceAccent;

  final Color offlineBanner;
  final Color onOfflineBanner;

  final Color success;
  final Color warning;
  final Color danger;

  final Color skeletonBase;
  final Color skeletonHighlight;

  @override
  ChatTheme copyWith({
    Color? glassFill,
    Color? glassStroke,
    Color? glassHighlight,
    Color? dockFill,
    Color? dockStroke,
    Color? dockHighlight,
    Color? dockActiveTop,
    Color? dockActiveBottom,
    Color? dockActiveBorder,
    Color? raisedSurface,
    Color? raisedBorder,
    Color? outgoingBubble,
    Color? outgoingBubbleEnd,
    Color? onOutgoingBubble,
    Color? incomingBubble,
    Color? onIncomingBubble,
    Color? bubbleBorder,
    Color? caret,
    Color? codeBackground,
    Color? codeBorder,
    Color? inlineCodeBackground,
    Color? composerBackground,
    Color? composerBorder,
    Color? onDeviceAccent,
    Color? offlineBanner,
    Color? onOfflineBanner,
    Color? success,
    Color? warning,
    Color? danger,
    Color? skeletonBase,
    Color? skeletonHighlight,
  }) => ChatTheme(
    glassFill: glassFill ?? this.glassFill,
    glassStroke: glassStroke ?? this.glassStroke,
    glassHighlight: glassHighlight ?? this.glassHighlight,
    dockFill: dockFill ?? this.dockFill,
    dockStroke: dockStroke ?? this.dockStroke,
    dockHighlight: dockHighlight ?? this.dockHighlight,
    dockActiveTop: dockActiveTop ?? this.dockActiveTop,
    dockActiveBottom: dockActiveBottom ?? this.dockActiveBottom,
    dockActiveBorder: dockActiveBorder ?? this.dockActiveBorder,
    raisedSurface: raisedSurface ?? this.raisedSurface,
    raisedBorder: raisedBorder ?? this.raisedBorder,
    outgoingBubble: outgoingBubble ?? this.outgoingBubble,
    outgoingBubbleEnd: outgoingBubbleEnd ?? this.outgoingBubbleEnd,
    onOutgoingBubble: onOutgoingBubble ?? this.onOutgoingBubble,
    incomingBubble: incomingBubble ?? this.incomingBubble,
    onIncomingBubble: onIncomingBubble ?? this.onIncomingBubble,
    bubbleBorder: bubbleBorder ?? this.bubbleBorder,
    caret: caret ?? this.caret,
    codeBackground: codeBackground ?? this.codeBackground,
    codeBorder: codeBorder ?? this.codeBorder,
    inlineCodeBackground: inlineCodeBackground ?? this.inlineCodeBackground,
    composerBackground: composerBackground ?? this.composerBackground,
    composerBorder: composerBorder ?? this.composerBorder,
    onDeviceAccent: onDeviceAccent ?? this.onDeviceAccent,
    offlineBanner: offlineBanner ?? this.offlineBanner,
    onOfflineBanner: onOfflineBanner ?? this.onOfflineBanner,
    success: success ?? this.success,
    warning: warning ?? this.warning,
    danger: danger ?? this.danger,
    skeletonBase: skeletonBase ?? this.skeletonBase,
    skeletonHighlight: skeletonHighlight ?? this.skeletonHighlight,
  );

  /// Enables a smooth cross-fade when the user flips light/dark mid-session.
  @override
  ChatTheme lerp(ChatTheme? other, double t) {
    if (other == null) return this;
    return ChatTheme(
      glassFill: Color.lerp(glassFill, other.glassFill, t)!,
      glassStroke: Color.lerp(glassStroke, other.glassStroke, t)!,
      glassHighlight: Color.lerp(glassHighlight, other.glassHighlight, t)!,
      dockFill: Color.lerp(dockFill, other.dockFill, t)!,
      dockStroke: Color.lerp(dockStroke, other.dockStroke, t)!,
      dockHighlight: Color.lerp(dockHighlight, other.dockHighlight, t)!,
      dockActiveTop: Color.lerp(dockActiveTop, other.dockActiveTop, t)!,
      dockActiveBottom: Color.lerp(
        dockActiveBottom,
        other.dockActiveBottom,
        t,
      )!,
      dockActiveBorder: Color.lerp(
        dockActiveBorder,
        other.dockActiveBorder,
        t,
      )!,
      raisedSurface: Color.lerp(raisedSurface, other.raisedSurface, t)!,
      raisedBorder: Color.lerp(raisedBorder, other.raisedBorder, t)!,
      outgoingBubble: Color.lerp(outgoingBubble, other.outgoingBubble, t)!,
      outgoingBubbleEnd: Color.lerp(
        outgoingBubbleEnd,
        other.outgoingBubbleEnd,
        t,
      )!,
      onOutgoingBubble: Color.lerp(
        onOutgoingBubble,
        other.onOutgoingBubble,
        t,
      )!,
      incomingBubble: Color.lerp(incomingBubble, other.incomingBubble, t)!,
      onIncomingBubble: Color.lerp(
        onIncomingBubble,
        other.onIncomingBubble,
        t,
      )!,
      bubbleBorder: Color.lerp(bubbleBorder, other.bubbleBorder, t)!,
      caret: Color.lerp(caret, other.caret, t)!,
      codeBackground: Color.lerp(codeBackground, other.codeBackground, t)!,
      codeBorder: Color.lerp(codeBorder, other.codeBorder, t)!,
      inlineCodeBackground: Color.lerp(
        inlineCodeBackground,
        other.inlineCodeBackground,
        t,
      )!,
      composerBackground: Color.lerp(
        composerBackground,
        other.composerBackground,
        t,
      )!,
      composerBorder: Color.lerp(composerBorder, other.composerBorder, t)!,
      onDeviceAccent: Color.lerp(onDeviceAccent, other.onDeviceAccent, t)!,
      offlineBanner: Color.lerp(offlineBanner, other.offlineBanner, t)!,
      onOfflineBanner: Color.lerp(onOfflineBanner, other.onOfflineBanner, t)!,
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      skeletonBase: Color.lerp(skeletonBase, other.skeletonBase, t)!,
      skeletonHighlight: Color.lerp(
        skeletonHighlight,
        other.skeletonHighlight,
        t,
      )!,
    );
  }
}

/// `context.chatTheme` instead of the verbose extension lookup.
extension ChatThemeX on BuildContext {
  ChatTheme get chatTheme => Theme.of(this).extension<ChatTheme>()!;

  ColorScheme get colors => Theme.of(this).colorScheme;

  TextTheme get texts => Theme.of(this).textTheme;
}
