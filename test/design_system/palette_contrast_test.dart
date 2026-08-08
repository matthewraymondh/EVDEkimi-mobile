import 'dart:math' as math;

import 'package:evdekimi_ai/design_system/app_theme.dart';
import 'package:evdekimi_ai/design_system/chat_theme.dart';
import 'package:evdekimi_ai/design_system/palette.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Contrast floors for every foreground/background pair the app actually paints.
///
/// A palette is the one part of a design system where "looks fine on my screen"
/// is least trustworthy: the failures are gradual, they show up on cheap panels
/// and in sunlight rather than on a desk, and nothing in the toolchain reports
/// them. The specified values are fixed, so the derived tones exist precisely to
/// clear these numbers — which makes them worth asserting rather than
/// eyeballing.
///
/// `#A1A1AA` is the case in point. It is the muted text tone, and against the
/// dark page it is a comfortable 7.8:1 — but on the light page it is 2.5:1, a
/// third of what body copy needs, while still looking entirely readable in a
/// swatch. That is why the light theme derives `zinc500` instead of reusing it.
void main() {
  const bodyText = 4.5; // WCAG AA, text below 18pt
  const largeText = 3.0; // WCAG AA, 18pt+ or bold 14pt+
  const nonText = 3.0; // WCAG AA, icons and control boundaries

  for (final (name, theme, chat) in [
    ('light', AppTheme.light(), ChatTheme.light),
    ('dark', AppTheme.dark(), ChatTheme.dark),
  ]) {
    group('$name theme', () {
      final scheme = theme.colorScheme;

      void check(
        String description,
        Color foreground,
        Color background,
        double floor,
      ) {
        test(description, () {
          final ratio = _contrast(foreground, background);
          expect(
            ratio,
            greaterThanOrEqualTo(floor),
            reason:
                '${_hex(foreground)} on ${_hex(background)} is '
                '${ratio.toStringAsFixed(2)}:1, below the $floor:1 floor',
          );
        });
      }

      check(
        'body text on the page',
        scheme.onSurface,
        scheme.surface,
        bodyText,
      );
      check(
        'body text on a raised card',
        scheme.onSurface,
        chat.raisedSurface,
        bodyText,
      );

      // The row excerpt, every caption, and most metadata in the app.
      check(
        'secondary text on the page',
        scheme.onSurfaceVariant,
        scheme.surface,
        bodyText,
      );
      check(
        'secondary text on a raised card',
        scheme.onSurfaceVariant,
        chat.raisedSurface,
        bodyText,
      );

      check('filled button label', scheme.onPrimary, scheme.primary, bodyText);
      check(
        'outgoing bubble text',
        chat.onOutgoingBubble,
        chat.outgoingBubble,
        bodyText,
      );
      check(
        'incoming bubble text',
        chat.onIncomingBubble,
        chat.incomingBubble,
        bodyText,
      );
      check(
        'offline banner text',
        chat.onOfflineBanner,
        chat.offlineBanner,
        bodyText,
      );

      // AppBadge fills with the accent at 12% over whatever is behind it, so
      // the label sits on a tint of the card rather than on the card itself.
      check(
        'on-device badge label',
        chat.onDeviceAccent,
        _composite(
          chat.onDeviceAccent.withValues(alpha: 0.12),
          chat.raisedSurface,
        ),
        largeText,
      );

      check('error text', scheme.error, scheme.surface, bodyText);
      check('danger text', chat.danger, chat.raisedSurface, bodyText);

      // A hairline only has to be *visible*, not readable — but it does have to
      // be visible from both sides, because it is the card's only edge. Neither
      // theme separates a card from its page by tone: white on #F8FAFC is
      // 1.05:1 and #18181B on #09090B is 1.13:1. That is not a defect to fix by
      // pushing the fills apart — near-white on near-white cannot go much
      // higher, and the dark pair is specified. It is the reason the stroke
      // exists, so the stroke is what gets the floor.
      final edge = _composite(chat.raisedBorder, chat.raisedSurface);
      check('card edge against its own fill', edge, chat.raisedSurface, 1.15);
      check('card edge against the page', edge, scheme.surface, 1.15);

      test('$name theme: a card is never the page', () {
        // The literal bug this file was written after: cards took
        // `surfaceContainerLowest`, which in Material's dark ramp is the
        // darkest tone in the set and resolved to exactly the scaffold colour.
        // The card structure rendered in light mode and was invisible in dark.
        expect(_hex(chat.raisedSurface), isNot(equals(_hex(scheme.surface))));
      });

      check('streaming caret', chat.caret, chat.incomingBubble, nonText);
    });
  }

  test('the specified values survive as themselves', () {
    // The ramp is allowed to grow derived steps, but not to quietly restate the
    // given colours as something near them.
    expect(_hex(AppTheme.dark().colorScheme.surface), equals('#09090B'));
    expect(_hex(ChatTheme.dark.raisedSurface), equals('#18181B'));
    expect(_hex(AppTheme.dark().colorScheme.onSurface), equals('#F4F4F5'));
    expect(
      _hex(AppTheme.dark().colorScheme.onSurfaceVariant),
      equals('#A1A1AA'),
    );
    expect(_hex(AppTheme.dark().colorScheme.primary), equals('#3B82F6'));
    expect(_hex(AppTheme.light().colorScheme.surface), equals('#F8FAFC'));
  });

  test('the whole grey ramp is actually grey', () {
    // Glass has to be the most colourful thing in a panel, so the plane behind
    // it must be neutral — a tinted surface competes with the refraction and
    // the effect stops reading as glass.
    //
    // This covers the ramp rather than the handful of roles pinned above,
    // because those are already exact-matched and a cast cannot reach them
    // without failing that test first. What it catches is a *new* tone added
    // later that looks grey in a swatch and is quietly slate — the widest
    // channel spread in the ramp today is 9/255, so anything past 11/255 is a
    // decision someone made rather than rounding.
    //
    // `slate50` is deliberately absent: it is the light page, and the one
    // value in the file allowed a trace of blue.
    const ramp = <String, Color>{
      'zinc950': AppPalette.zinc950,
      'zinc900': AppPalette.zinc900,
      'zinc800': AppPalette.zinc800,
      'zinc700': AppPalette.zinc700,
      'zinc600': AppPalette.zinc600,
      'zinc500': AppPalette.zinc500,
      'zinc400': AppPalette.zinc400,
      'zinc300': AppPalette.zinc300,
      'zinc200': AppPalette.zinc200,
      'zinc100': AppPalette.zinc100,
      'zinc50': AppPalette.zinc50,
    };

    for (final MapEntry(key: name, value: color) in ramp.entries) {
      final channels = [color.r, color.g, color.b];
      final spread = channels.reduce(math.max) - channels.reduce(math.min);
      expect(
        spread,
        lessThan(11 / 255),
        reason:
            '$name (${_hex(color)}) spreads ${(spread * 255).round()}/255 '
            'across its channels — that is a colour cast, not a neutral',
      );
    }
  });
}

/// WCAG 2.1 relative-contrast ratio.
double _contrast(Color foreground, Color background) {
  final a = foreground.computeLuminance();
  final b = background.computeLuminance();
  return (math.max(a, b) + 0.05) / (math.min(a, b) + 0.05);
}

/// Flattens a translucent colour onto an opaque one.
Color _composite(Color foreground, Color background) {
  final alpha = foreground.a;
  return Color.from(
    alpha: 1,
    red: foreground.r * alpha + background.r * (1 - alpha),
    green: foreground.g * alpha + background.g * (1 - alpha),
    blue: foreground.b * alpha + background.b * (1 - alpha),
  );
}

String _hex(Color color) {
  String channel(double value) =>
      (value * 255).round().toRadixString(16).padLeft(2, '0').toUpperCase();
  return '#${channel(color.r)}${channel(color.g)}${channel(color.b)}';
}
