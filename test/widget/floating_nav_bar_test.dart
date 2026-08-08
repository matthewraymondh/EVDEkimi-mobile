import 'package:evdekimi_ai/app/floating_nav_bar.dart';
import 'package:evdekimi_ai/design_system/app_theme.dart';
import 'package:evdekimi_ai/design_system/glass.dart';
import 'package:evdekimi_ai/di/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The dock's selected-state capsule.
///
/// Worth pinning because the layout is the one piece of real geometry in the
/// app: the bar has three slots but only two destinations, so the capsule has
/// to step *over* the compose action in the middle rather than land on it. Every
/// other way of writing this — an index into the children, a fraction of the
/// width, a per-slot indicator — produces a capsule that sits under the compose
/// button for one of the two tabs, and it looks plausible enough in code review
/// to survive.
///
/// Glass is disabled throughout. The fallback path is geometrically identical by
/// construction, and the shader cannot run in a test binding.
void main() {
  const barWidth = 360.0;

  Widget host(
    int index, {
    ValueChanged<int>? onSelect,
    Brightness brightness = Brightness.dark,
  }) => ProviderScope(
    overrides: [
      pendingMessageCountProvider.overrideWith((ref) => Stream.value(0)),
    ],
    child: MaterialApp(
      theme: brightness == Brightness.dark ? AppTheme.dark() : AppTheme.light(),
      home: GlassScope(
        isEnabled: false,
        child: Scaffold(
          body: const SizedBox.shrink(),
          bottomNavigationBar: SizedBox(
            width: barWidth,
            child: FloatingNavBar(
              currentIndex: index,
              onSelect: onSelect ?? (_) {},
              onNewChat: () {},
            ),
          ),
        ),
      ),
    ),
  );

  Rect capsule(WidgetTester tester) =>
      tester.getRect(find.byKey(FloatingNavBar.activeCapsuleKey));

  Rect destination(WidgetTester tester, String label) =>
      tester.getRect(find.bySemanticsLabel(label).first);

  testWidgets('sits over the first destination when Chats is selected', (
    tester,
  ) async {
    await tester.pumpWidget(host(0));
    await tester.pumpAndSettle();

    expect(
      capsule(tester).center.dx,
      moreOrLessEquals(destination(tester, 'Chats').center.dx, epsilon: 1),
    );
  });

  testWidgets('steps over the compose action to reach Settings', (
    tester,
  ) async {
    await tester.pumpWidget(host(1));
    await tester.pumpAndSettle();

    final settings = destination(tester, 'Settings');
    expect(
      capsule(tester).center.dx,
      moreOrLessEquals(settings.center.dx, epsilon: 1),
    );

    // The failure this exists for: with the capsule indexed by destination
    // rather than by slot, tab 1 parks it in the middle — on the compose
    // button, which is not a destination at all.
    expect(
      capsule(tester).center.dx,
      greaterThan(barWidth * 0.6),
      reason: 'the second destination is the third slot, not the second',
    );
  });

  testWidgets('travels between destinations instead of jumping', (
    tester,
  ) async {
    await tester.pumpWidget(host(0));
    await tester.pumpAndSettle();
    final start = capsule(tester).center.dx;

    await tester.pumpWidget(host(1));
    await tester.pump(const Duration(milliseconds: 120));
    final midway = capsule(tester).center.dx;

    await tester.pumpAndSettle();
    final end = capsule(tester).center.dx;

    expect(
      midway,
      greaterThan(start),
      reason: 'a capsule that jumps is already at the end on the first frame',
    );
    expect(midway, lessThan(end));
  });

  testWidgets('tints the icon in step with the capsule, not before it', (
    tester,
  ) async {
    Color tintOf(String label) => tester
        .widgetList<Icon>(
          find.descendant(
            of: find.bySemanticsLabel(label).first,
            matching: find.byType(Icon),
          ),
        )
        .first
        .color!;

    await tester.pumpWidget(host(0));
    await tester.pumpAndSettle();
    final muted = tintOf('Settings');

    await tester.pumpWidget(host(1));
    await tester.pump(const Duration(milliseconds: 150));
    final midway = tintOf('Settings');

    await tester.pumpAndSettle();
    final full = tintOf('Settings');

    // Opacity is what the tween moves, so alpha is what has to be in between.
    // If the tint snapped instead, the glyph would reach full strength while
    // the capsule was still a third of the bar away from it.
    expect(muted.a, lessThan(full.a));
    expect(midway.a, greaterThan(muted.a));
    expect(midway.a, lessThan(full.a));
  });

  testWidgets('uses a dark foreground in light mode', (tester) async {
    // The reference specifies #FFFFFF for the active icon, which is dark-mode
    // reasoning: on a near-white dock a white glyph is not muted, it is gone.
    // Both tints resolve through `onSurface` so the polarity follows the theme.
    await tester.pumpWidget(host(0, brightness: Brightness.light));
    await tester.pumpAndSettle();

    final active = tester
        .widgetList<Icon>(
          find.descendant(
            of: find.bySemanticsLabel('Chats').first,
            matching: find.byType(Icon),
          ),
        )
        .first;

    expect(active.color!.computeLuminance(), lessThan(0.2));
    expect(find.byKey(FloatingNavBar.activeCapsuleKey), findsOneWidget);
  });

  testWidgets('reports the selected destination to assistive tech', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(host(1));
    await tester.pumpAndSettle();

    // The capsule is the only visual cue for the selected tab, so nothing about
    // it reaches a screen reader. The semantics have to say it separately.
    expect(
      tester.getSemantics(find.bySemanticsLabel('Settings').first),
      isSemantics(
        label: 'Settings',
        isButton: true,
        isSelected: true,
        hasTapAction: true,
      ),
    );
    expect(
      tester.getSemantics(find.bySemanticsLabel('Chats').first),
      isSemantics(label: 'Chats', isSelected: false),
    );
    handle.dispose();
  });

  testWidgets('selecting a destination reports its index, not its slot', (
    tester,
  ) async {
    final selected = <int>[];
    await tester.pumpWidget(host(0, onSelect: selected.add));
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel('Settings').first);
    expect(
      selected,
      equals([1]),
      reason: 'Settings is destination 1 even though it occupies slot 2',
    );
  });
}
