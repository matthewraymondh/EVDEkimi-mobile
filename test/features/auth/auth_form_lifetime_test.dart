import 'package:evdekimi_ai/core/error/failure.dart';
import 'package:evdekimi_ai/core/result/result.dart';
import 'package:evdekimi_ai/di/providers.dart';
import 'package:evdekimi_ai/features/auth/domain/entities/auth_session.dart';
import 'package:evdekimi_ai/features/auth/domain/repositories/auth_repository.dart';
import 'package:evdekimi_ai/features/auth/presentation/auth_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The sign-in form must not outlive the sign-in screen.
///
/// A successful submit deliberately leaves `isSubmitting: true`, because the
/// router is about to replace the screen and flipping the button back to enabled
/// first would flash. That is a good decision and a completely safe one — as
/// long as the state is thrown away with the screen.
///
/// Held for the app's lifetime it is a lock-out. Sign in, sign out, and the
/// sign-in screen returns holding the `true` from last time: a spinner that
/// never stops, on a button that is disabled while it spins. The only way back
/// in is to kill the app.
void main() {
  late _StubAuthRepository repository;

  ProviderContainer containerWith() {
    final container = ProviderContainer(
      overrides: [authRepositoryProvider.overrideWithValue(repository)],
    );
    addTearDown(container.dispose);
    return container;
  }

  setUp(() => repository = _StubAuthRepository());

  test('stays submitting through a successful sign-in', () async {
    final container = containerWith();
    final screen = container.listen(authControllerProvider, (_, _) {});

    final ok = await container
        .read(authControllerProvider.notifier)
        .submit(email: 'a@b.test', password: 'password123');

    expect(ok, isTrue);
    expect(
      screen.read().isSubmitting,
      isTrue,
      reason: 'the button must not flash back to enabled before the redirect',
    );
  });

  test('forgets it once the screen goes away', () async {
    final container = containerWith();

    // The sign-in screen, subscribed.
    final screen = container.listen(authControllerProvider, (_, _) {});
    await container
        .read(authControllerProvider.notifier)
        .submit(email: 'a@b.test', password: 'password123');
    expect(screen.read().isSubmitting, isTrue);

    // The router replaces the screen with home: last listener gone.
    screen.close();

    // Riverpod disposes on a later turn, not the instant the last listener
    // leaves. The gap is not a workaround for the test — it is what actually
    // happens, and then some: signing out is a whole user journey after the
    // screen was replaced, thousands of frames later.
    await Future<void>.delayed(Duration.zero);

    // Sign out, and the sign-in screen mounts again.
    final reopened = container.listen(authControllerProvider, (_, _) {});

    expect(
      reopened.read().isSubmitting,
      isFalse,
      reason:
          'a spinning, disabled button here means the user cannot sign back in '
          'at all without killing the app',
    );
    expect(reopened.read().failure, isNull);
    expect(reopened.read().fieldErrors, isEmpty);
  });

  test('a failed sign-in clears submitting on its own', () async {
    // The screen is not replaced in this case, so the state has to recover
    // without help from disposal.
    repository.failure = const AuthFailure(
      message: 'nope',
      reason: AuthFailureReason.invalidCredentials,
    );

    final container = containerWith();
    final screen = container.listen(authControllerProvider, (_, _) {});

    final ok = await container
        .read(authControllerProvider.notifier)
        .submit(email: 'a@b.test', password: 'wrongpassword');

    expect(ok, isFalse);
    expect(screen.read().isSubmitting, isFalse);
    expect(screen.read().failure, isNotNull);
  });

  test('ignores a second submit while one is in flight', () async {
    final container = containerWith();
    container.listen(authControllerProvider, (_, _) {});
    final controller = container.read(authControllerProvider.notifier);

    final first = controller.submit(email: 'a@b.test', password: 'password123');
    final second = controller.submit(
      email: 'a@b.test',
      password: 'password123',
    );

    expect(await first, isTrue);
    expect(await second, isFalse);
    expect(
      repository.signInCalls,
      equals(1),
      reason: 'a double tap must not open two sessions',
    );
  });
}

class _StubAuthRepository implements AuthRepository {
  int signInCalls = 0;
  Failure? failure;

  AuthSession get _session => AuthSession(
    user: const User(id: 'u1', email: 'a@b.test'),
    accessToken: 'access',
    refreshToken: 'refresh',
    accessTokenExpiresAt: DateTime.now().add(const Duration(minutes: 5)),
  );

  @override
  Future<Result<AuthSession>> signIn(AuthCredentials credentials) async {
    signInCalls++;
    final error = failure;
    return error == null ? Ok(_session) : Err(error);
  }

  @override
  Future<Result<AuthSession>> signUp(AuthCredentials credentials) =>
      signIn(credentials);

  @override
  Future<Result<void>> signOut() async => const Ok(null);

  @override
  Future<Result<AuthSession?>> restoreSession() async => const Ok(null);

  @override
  Future<Result<AuthSession>> refresh() async => Ok(_session);

  @override
  AuthSession? get currentSession => null;

  @override
  Stream<AuthSession?> get sessionChanges => const Stream.empty();
}
