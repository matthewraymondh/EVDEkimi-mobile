import 'dart:math' as math;

import 'package:evdekimi_ai/design_system/app_theme.dart';
import 'package:evdekimi_ai/design_system/chat_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Contrast floors for every foreground/background pair the app actually paints.
///
/// A palette is the one part of a design system where "looks fine on my screen"
/// is least trustworthy: the failures are gradual, they show up on cheap panels
/// and in sunlight rather than on a desk, and nothing in the toolchain reports
/// them. The four brand values are fixed, so the derived tones exist precisely
/// to clear these numbers — which makes them worth asserting rather than
/// eyeballing. `#787A91` on `#EEEEEE` is the case in point: it reaches 3.7:1,
/// looks perfectly readable, and is under the floor for body copy.
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

      // Hairlines only have to be *visible*, not readable.
      check('card hairline', chat.raisedBorder, chat.raisedSurface, 1.15);
      check('card against the page', chat.raisedSurface, scheme.surface, 1.15);

      check('streaming caret', chat.caret, chat.incomingBubble, nonText);
    });
  }

  test('the four brand values survive as themselves', () {
    // The ramp is allowed to grow derived steps, but not to quietly restate the
    // given colours as something near them.
    expect(_hex(AppTheme.dark().colorScheme.surface), equals('#0F044C'));
    expect(_hex(ChatTheme.dark.raisedSurface), equals('#141E61'));
    expect(_hex(AppTheme.light().colorScheme.surface), equals('#EEEEEE'));
    expect(_hex(AppTheme.light().colorScheme.primary), equals('#141E61'));
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
