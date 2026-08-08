import 'package:evdekimi_ai/app/routes.dart';
import 'package:flutter_test/flutter_test.dart';

/// Route-shape guarantees.
///
/// Cheap to assert and easy to break: moving the chat route out of the shell
/// changed its path, and a stale `chatPath` would produce a dead link that only
/// shows up by tapping a conversation.
void main() {
  group('AppRoutes', () {
    test('chat path matches the declared pattern', () {
      final path = AppRoutes.chatPath('abc-123');

      expect(path, equals('/chat/abc-123'));
      expect(
        path.startsWith(AppRoutes.chat.split(':').first),
        isTrue,
        reason: 'chatPath must satisfy the pattern go_router registers',
      );
    });

    test('chat sits outside the tab branches', () {
      // If chat were nested under a tab, opening a conversation would leave the
      // navigation bar visible over a full-screen transcript.
      for (final tab in AppRoutes.tabs) {
        expect(
          AppRoutes.chatPath('x').startsWith('$tab/'),
          isFalse,
          reason: 'chat must not be a child of $tab',
        );
      }
    });

    test('tab order matches the navigation bar', () {
      // The shell maps branch index to this list; reordering one without the
      // other silently sends users to the wrong tab.
      expect(
        AppRoutes.tabs,
        equals([AppRoutes.conversations, AppRoutes.search, AppRoutes.settings]),
      );
    });

    test('every tab is a distinct top-level path', () {
      expect(AppRoutes.tabs.toSet(), hasLength(AppRoutes.tabs.length));
      for (final tab in AppRoutes.tabs) {
        expect(tab.startsWith('/'), isTrue);
        expect(tab.substring(1).contains('/'), isFalse, reason: '$tab nested');
      }
    });

    test(
      'the log console is nested under settings so its tab stays selected',
      () {
        expect(AppRoutes.logs.startsWith('${AppRoutes.settings}/'), isTrue);
      },
    );

    test('auth routes stay outside the shell', () {
      // Rendering a navigation bar behind the sign-in screen would let a signed
      // out user tap into tabs the guard is supposed to block.
      for (final route in [AppRoutes.signIn, AppRoutes.splash]) {
        expect(AppRoutes.tabs.contains(route), isFalse);
      }
    });
  });
}
