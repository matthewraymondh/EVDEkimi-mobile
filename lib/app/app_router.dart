import 'package:evdekimi_ai/app/home_shell.dart';
import 'package:evdekimi_ai/app/routes.dart';
import 'package:evdekimi_ai/di/providers.dart';
import 'package:evdekimi_ai/features/auth/presentation/sign_in_screen.dart';
import 'package:evdekimi_ai/features/chat/presentation/chat_screen.dart';
import 'package:evdekimi_ai/features/chat/presentation/conversation_list_screen.dart';
import 'package:evdekimi_ai/features/chat/presentation/search_screen.dart';
import 'package:evdekimi_ai/features/diagnostics/log_console_screen.dart';
import 'package:evdekimi_ai/features/settings/presentation/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// The router, with a single authentication guard.
///
/// All access control lives in one `redirect`. Individual screens never check
/// whether the user is signed in, which is what stops a new screen from
/// accidentally being reachable while signed out.
///
/// The guard depends on `authSessionProvider`, and go_router is told to
/// re-evaluate it via [refreshListenable]. So a session expiring anywhere — a 401
/// from a background outbox flush, say — routes the user to sign-in without any
/// screen having to handle it.
final routerProvider = Provider<GoRouter>((ref) {
  final notifier = _AuthRefreshNotifier(ref);
  ref.onDispose(notifier.dispose);

  return GoRouter(
    initialLocation: AppRoutes.splash,
    refreshListenable: notifier,
    debugLogDiagnostics: !ref.read(appConfigProvider).flavor.isProd,
    redirect: (context, state) {
      final session = ref.read(authSessionProvider);

      // Hold on the splash screen until the stored session has been read;
      // redirecting early would flash sign-in for an already-signed-in user.
      if (session.isLoading && !session.hasValue) {
        return state.matchedLocation == AppRoutes.splash
            ? null
            : AppRoutes.splash;
      }

      final isSignedIn = session.value != null;
      final isOnAuthScreen =
          state.matchedLocation == AppRoutes.signIn ||
          state.matchedLocation == AppRoutes.splash;

      if (!isSignedIn) {
        return state.matchedLocation == AppRoutes.signIn
            ? null
            : AppRoutes.signIn;
      }
      if (isOnAuthScreen) return AppRoutes.conversations;
      return null;
    },
    routes: [
      GoRoute(
        path: AppRoutes.splash,
        builder: (context, state) => const _SplashScreen(),
      ),
      GoRoute(
        path: AppRoutes.signIn,
        builder: (context, state) => const SignInScreen(),
      ),
      // The three tabs live in an indexed stack, so each keeps its own
      // navigation history and scroll position across switches.
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) =>
            HomeShell(navigationShell: navigationShell),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: AppRoutes.conversations,
                builder: (context, state) => const ConversationListScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: AppRoutes.search,
                builder: (context, state) => const SearchScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: AppRoutes.settings,
                builder: (context, state) => const SettingsScreen(),
                routes: [
                  // Nested, so the log console keeps the Settings tab selected.
                  GoRoute(
                    path: 'logs',
                    builder: (context, state) => const LogConsoleScreen(),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),

      // Outside the shell on purpose: a transcript is a focused, full-screen
      // task, and it should cover the navigation bar rather than sit above it.
      GoRoute(
        path: AppRoutes.chat,
        builder: (context, state) => ChatScreen(
          conversationId: state.pathParameters[AppRoutes.conversationIdParam]!,
        ),
      ),
    ],
    errorBuilder: (context, state) =>
        Scaffold(body: Center(child: Text('Route not found: ${state.uri}'))),
  );
});

/// Bridges Riverpod's session stream to go_router's `Listenable`.
///
/// go_router only re-runs `redirect` when its refresh listenable fires, so this
/// adapter is what makes the guard reactive instead of evaluated once.
class _AuthRefreshNotifier extends ChangeNotifier {
  _AuthRefreshNotifier(Ref ref) {
    _subscription = ref.listen(
      authSessionProvider,
      (previous, next) => notifyListeners(),
      fireImmediately: true,
    );
  }

  late final ProviderSubscription<dynamic> _subscription;

  @override
  void dispose() {
    _subscription.close();
    super.dispose();
  }
}

/// Shown while the persisted session is being restored.
class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.auto_awesome_rounded,
              size: 40,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 20),
            const SizedBox(
              width: 120,
              child: LinearProgressIndicator(minHeight: 2),
            ),
          ],
        ),
      ),
    );
  }
}
