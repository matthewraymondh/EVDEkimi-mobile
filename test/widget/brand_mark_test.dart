import 'package:evdekimi_ai/design_system/app_theme.dart';
import 'package:evdekimi_ai/design_system/widgets/brand_mark.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';

/// The mark has to survive both themes from a single asset.
///
/// The shipped file is monochrome white on transparency — the logo as it appears
/// on the company's navy plate. Rendered as-is it is invisible in light mode,
/// where the page is `#F8FAFC` and cards are white. `BrandMark` tints it with
/// `BlendMode.srcIn`, which is lossless *because* the source is one colour.
///
/// The failure this guards is silent: drop the blend mode, or hand it a themed
/// colour it already matches, and the widget still builds, still lays out, and
/// shows nothing at all on one of the two themes.
void main() {
  Image markIn(WidgetTester tester) =>
      tester.widget<Image>(find.byType(Image).first);

  Future<void> pump(WidgetTester tester, Brightness brightness) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: brightness == Brightness.dark
            ? AppTheme.dark()
            : AppTheme.light(),
        home: const Scaffold(body: Center(child: BrandMark())),
      ),
    );
  }

  testWidgets('is dark on the light theme', (tester) async {
    await pump(tester, Brightness.light);
    final image = markIn(tester);

    expect(image.colorBlendMode, BlendMode.srcIn);
    expect(
      image.color!.computeLuminance(),
      lessThan(0.2),
      reason: 'a white mark on a #F8FAFC page is not subtle, it is absent',
    );
  });

  testWidgets('is light on the dark theme', (tester) async {
    await pump(tester, Brightness.dark);
    expect(markIn(tester).color!.computeLuminance(), greaterThan(0.8));
  });

  testWidgets('honours an explicit colour for marks on their own plate', (
    tester,
  ) async {
    // The launch screen and anything else with a dark fill of its own needs the
    // mark to stay white rather than follow the theme.
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: const Scaffold(
          body: Center(child: BrandMark(color: Colors.white)),
        ),
      ),
    );

    expect(markIn(tester).color, Colors.white);
  });

  testWidgets('the asset is declared and loadable', (tester) async {
    // A missing entry in pubspec fails at runtime, not at compile time, and the
    // splash is the first screen in the app — it would be the first thing a
    // reviewer sees break.
    final data = await rootBundle.load(BrandMark.asset);
    expect(data.lengthInBytes, greaterThan(0));
  });
}
