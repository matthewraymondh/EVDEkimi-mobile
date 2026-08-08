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
    required this.raisedSurface,
    required this.raisedBorder,
    required this.outgoingBubble,
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
    raisedSurface: AppPalette.white,
    raisedBorder: AppPalette.ink100,
    // The user's own messages carry the brand colour: it is the one element on
    // screen that should feel like "you", and it anchors the eye when scanning.
    outgoingBubble: AppPalette.brandNavy,
    onOutgoingBubble: AppPalette.white,
    // Assistant messages are white on the canvas rather than a tinted fill.
    // Model output is long-form text and needs to read like a document page.
    incomingBubble: AppPalette.white,
    onIncomingBubble: AppPalette.ink900,
    bubbleBorder: AppPalette.ink100,
    caret: AppPalette.brandNavy,
    codeBackground: AppPalette.ink800,
    codeBorder: AppPalette.ink700,
    inlineCodeBackground: AppPalette.ink100,
    composerBackground: AppPalette.white,
    composerBorder: AppPalette.ink200,
    onDeviceAccent: AppPalette.brandBrass,
    offlineBanner: AppPalette.ink700,
    onOfflineBanner: AppPalette.ink50,
    success: AppPalette.successLight,
    warning: AppPalette.warningLight,
    danger: AppPalette.dangerLight,
    skeletonBase: AppPalette.ink100,
    skeletonHighlight: AppPalette.ink50,
  );

  static const ChatTheme dark = ChatTheme(
    // Lighter than the page, not darker. `surfaceContainerLowest` is what a card
    // reaches for by reflex, and in Material's dark ramp that resolves to the
    // *darkest* tone in the set — identical to the scaffold here, which is why
    // the conversation cards were invisible in dark mode while looking correct
    // in light. Elevation reads as light in the dark, so the token has to be
    // semantic rather than positional.
    raisedSurface: AppPalette.ink800,
    raisedBorder: AppPalette.ink700,
    // Dark mode inverts the emphasis: a saturated fill at full brightness is
    // fatiguing, so the outgoing bubble uses a deep brand tone with a bright
    // foreground instead.
    outgoingBubble: AppPalette.brandNavyDeep,
    onOutgoingBubble: AppPalette.ink100,
    incomingBubble: AppPalette.ink800,
    onIncomingBubble: AppPalette.ink100,
    bubbleBorder: AppPalette.ink700,
    caret: AppPalette.brandNavyLifted,
    codeBackground: AppPalette.ink900,
    codeBorder: AppPalette.ink700,
    inlineCodeBackground: AppPalette.ink700,
    composerBackground: AppPalette.ink800,
    composerBorder: AppPalette.ink600,
    onDeviceAccent: AppPalette.warningDark,
    offlineBanner: AppPalette.ink600,
    onOfflineBanner: AppPalette.ink100,
    success: AppPalette.successDark,
    warning: AppPalette.warningDark,
    danger: AppPalette.dangerDark,
    skeletonBase: AppPalette.ink700,
    skeletonHighlight: AppPalette.ink600,
  );

  /// Fill for a card that must read as sitting above the page.
  ///
  /// Resolves in opposite directions per theme: lighter than the background in
  /// dark mode, whiter than the canvas in light. Use this rather than a
  /// `surfaceContainer*` role for anything raised.
  final Color raisedSurface;

  /// Hairline that separates rows inside a [raisedSurface] card.
  final Color raisedBorder;

  final Color outgoingBubble;
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
    Color? raisedSurface,
    Color? raisedBorder,
    Color? outgoingBubble,
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
    raisedSurface: raisedSurface ?? this.raisedSurface,
    raisedBorder: raisedBorder ?? this.raisedBorder,
    outgoingBubble: outgoingBubble ?? this.outgoingBubble,
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
      raisedSurface: Color.lerp(raisedSurface, other.raisedSurface, t)!,
      raisedBorder: Color.lerp(raisedBorder, other.raisedBorder, t)!,
      outgoingBubble: Color.lerp(outgoingBubble, other.outgoingBubble, t)!,
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
