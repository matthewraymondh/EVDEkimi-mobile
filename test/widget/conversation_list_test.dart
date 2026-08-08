import 'package:evdekimi_ai/design_system/app_theme.dart';
import 'package:evdekimi_ai/design_system/widgets/app_widgets.dart';
import 'package:evdekimi_ai/di/providers.dart';
import 'package:evdekimi_ai/features/ai/domain/model_descriptor.dart';
import 'package:evdekimi_ai/features/auth/domain/entities/auth_session.dart';
import 'package:evdekimi_ai/features/chat/domain/entities/conversation.dart';
import 'package:evdekimi_ai/features/chat/presentation/conversation_list_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Widget tests for the home list.
///
/// These pin the decisions that a later "tidy-up" is most likely to undo,
/// because each one looks like an omission rather than a choice: no per-row
/// avatar, no markup in an excerpt, and no excerpt at all when it only repeats
/// the title.
void main() {
  final now = DateTime.now();

  Conversation conversation({
    required String id,
    required String title,
    String? preview,
    Duration age = Duration.zero,
    EngineKind engine = EngineKind.remote,
    bool isPinned = false,
    int messageCount = 4,
  }) {
    final timestamp = now.subtract(age);
    return Conversation(
      id: id,
      title: title,
      modelId: 'mock-gpt',
      engine: engine,
      lastMessagePreview: preview,
      messageCount: messageCount,
      isPinned: isPinned,
      createdAt: timestamp,
      updatedAt: timestamp,
    );
  }

  Widget host(List<Conversation> conversations) => ProviderScope(
    overrides: [
      conversationsProvider.overrideWith((ref) => Stream.value(conversations)),
      pendingMessageCountProvider.overrideWith((ref) => Stream.value(0)),
      isOnlineProvider.overrideWithValue(true),
      currentUserProvider.overrideWithValue(
        const User(id: 'u1', email: 'matthew@evdekimi.test'),
      ),
    ],
    child: MaterialApp(
      theme: AppTheme.light(),
      home: const ConversationListScreen(),
    ),
  );

  testWidgets('groups rows under date headings', (tester) async {
    await tester.pumpWidget(
      host([
        conversation(id: 'a', title: 'Villas in Canggu'),
        conversation(
          id: 'b',
          title: 'Ownership rules',
          age: const Duration(days: 1),
        ),
        conversation(
          id: 'c',
          title: 'Uluwatu land',
          age: const Duration(days: 3),
        ),
      ]),
    );
    await tester.pump();

    expect(find.text('TODAY'), findsOneWidget);
    expect(find.text('YESTERDAY'), findsOneWidget);
    expect(find.text('EARLIER THIS WEEK'), findsOneWidget);
  });

  testWidgets('pinned threads get their own group, not a row icon', (
    tester,
  ) async {
    await tester.pumpWidget(
      host([
        conversation(
          id: 'a',
          title: 'Villa Melati',
          isPinned: true,
          age: const Duration(days: 40),
        ),
        conversation(id: 'b', title: 'Pererenan plots'),
      ]),
    );
    await tester.pump();

    expect(find.text('PINNED'), findsOneWidget);
    expect(find.text('TODAY'), findsOneWidget);
    // The pin lived on the row before; the heading says it once instead.
    expect(find.byIcon(Icons.push_pin_rounded), findsNothing);
  });

  testWidgets('renders an excerpt as plain text, never as markup', (
    tester,
  ) async {
    await tester.pumpWidget(
      host([
        conversation(
          id: 'a',
          title: 'Price check',
          preview: 'Canggu sits around **\$310k** for a 3BR.',
        ),
        conversation(
          id: 'b',
          title: 'Market rates',
          // Stored previews written before the DAO stripped markup still look
          // like this, which is why the row strips again on the way out.
          preview:
              'Where the market sits:\n'
              '| Area | 2BR |\n'
              '| --- | --- |\n'
              '| Canggu | \$195k |',
        ),
      ]),
    );
    await tester.pump();

    expect(
      find.text(r'Canggu sits around $310k for a 3BR.'),
      findsOneWidget,
      reason: 'the row has no markdown renderer, so it must receive none',
    );
    expect(
      find.text(r'Where the market sits: Area · 2BR Canggu · $195k'),
      findsOneWidget,
      reason: "a table's separator row carries no words",
    );
  });

  testWidgets('drops an excerpt that only restates the title', (tester) async {
    await tester.pumpWidget(
      host([
        conversation(
          id: 'a',
          title: 'Can I schedule a viewing…',
          preview:
              'You asked about **Can I schedule a viewing this '
              'Saturday afternoon?**. Here is what I found.',
          messageCount: 6,
        ),
      ]),
    );
    await tester.pump();

    expect(find.textContaining('You asked about'), findsNothing);
    expect(
      find.text('6 messages'),
      findsOneWidget,
      reason:
          'the row keeps two lines, but the second one has to say something',
    );
  });

  testWidgets('marks on-device threads and leaves the rest unmarked', (
    tester,
  ) async {
    await tester.pumpWidget(
      host([
        conversation(
          id: 'a',
          title: 'Offline recall',
          engine: EngineKind.onDevice,
          preview: 'Searched your saved messages on this device.',
        ),
        conversation(
          id: 'b',
          title: 'Villas in Canggu',
          preview: 'Here are three that fit what you described.',
        ),
      ]),
    );
    await tester.pump();

    expect(
      find.widgetWithText(AppBadge, 'On-device'),
      findsOneWidget,
      reason: 'exactly the one row it is true of',
    );
  });

  testWidgets('rows carry no avatar', (tester) async {
    // The regression this guards: every row used to show an identical circle
    // with an identical sparkle. Every thread here is with the assistant, so
    // the mark distinguished nothing and cost a third of the row width.
    await tester.pumpWidget(
      host([
        conversation(id: 'a', title: 'Villas in Canggu', preview: 'Three fit.'),
        conversation(id: 'b', title: 'Ownership rules', preview: 'Hak Pakai.'),
      ]),
    );
    await tester.pump();

    expect(find.text('Villas in Canggu'), findsOneWidget);
    expect(find.byType(AppAvatar), findsNothing);
  });
}
