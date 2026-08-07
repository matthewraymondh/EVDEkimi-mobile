import 'dart:async';
import 'dart:convert';

import 'package:evdekimi_ai/core/error/exceptions.dart';
import 'package:evdekimi_ai/core/error/failure.dart';
import 'package:evdekimi_ai/core/logging/app_logger.dart';
import 'package:evdekimi_ai/core/network/auth_token_delegate.dart';
import 'package:evdekimi_ai/core/persistence/secure_store.dart';
import 'package:evdekimi_ai/core/result/result.dart';
import 'package:evdekimi_ai/features/auth/data/auth_remote_data_source.dart';
import 'package:evdekimi_ai/features/auth/domain/entities/auth_session.dart';
import 'package:evdekimi_ai/features/auth/domain/repositories/auth_repository.dart';

/// Auth backed by the API and the platform keystore.
///
/// Also implements [AuthTokenDelegate], which is how the HTTP layer gets a token
/// without importing anything from this feature — the interceptor holds the
/// interface, this class satisfies it.
class AuthRepositoryImpl implements AuthRepository, AuthTokenDelegate {
  AuthRepositoryImpl({
    required AuthRemoteDataSource remote,
    required SecureStore secureStore,
    required AppLogger logger,
    Future<void> Function()? onSignedOut,
  }) : _remote = remote,
       _secureStore = secureStore,
       _logger = logger.scoped('auth'),
       _onSignedOut = onSignedOut;

  final AuthRemoteDataSource _remote;
  final SecureStore _secureStore;
  final AppLogger _logger;

  /// Invoked after a sign-out so the app can wipe local chat data.
  ///
  /// A callback rather than a direct dependency on the chat layer: auth must not
  /// know that conversations exist.
  final Future<void> Function()? _onSignedOut;

  final StreamController<AuthSession?> _sessions =
      StreamController<AuthSession?>.broadcast();

  AuthSession? _session;

  @override
  AuthSession? get currentSession => _session;

  @override
  Stream<AuthSession?> get sessionChanges async* {
    yield _session;
    yield* _sessions.stream;
  }

  @override
  Future<Result<AuthSession?>> restoreSession() async {
    try {
      final accessToken = await _secureStore.read(SecureKeys.accessToken);
      final refreshToken = await _secureStore.read(SecureKeys.refreshToken);
      if (accessToken == null || refreshToken == null) {
        return const Ok(null);
      }

      final profileJson = await _secureStore.read(SecureKeys.userProfile);
      final expiryRaw = await _secureStore.read(SecureKeys.accessTokenExpiry);

      final restored = AuthSession(
        user: profileJson == null
            ? const User(id: 'me', email: '')
            : User.fromJson(jsonDecode(profileJson) as Map<String, dynamic>),
        accessToken: accessToken,
        refreshToken: refreshToken,
        accessTokenExpiresAt: expiryRaw == null
            ? null
            : DateTime.tryParse(expiryRaw),
      );

      _emit(restored);

      // Refresh proactively when the stored token is already past its skew, so
      // the first real request of the session does not eat a 401.
      if (restored.isAccessTokenExpired) {
        _logger.i('Stored access token expired; refreshing');
        final refreshed = await refresh();
        return refreshed.fold(
          ok: Ok<AuthSession?>.new,
          err: (failure) {
            unawaited(_clearLocalSession());
            return const Ok(null);
          },
        );
      }

      _logger.i('Session restored', fields: {'user': restored.user.email});
      return Ok(restored);
    } on LocalStoreException catch (error, stackTrace) {
      // An unreadable keystore (OS upgrade, restored backup) means "signed out",
      // not "crash on launch". This is the policy call the storage layer
      // deliberately refused to make.
      _logger.w(
        'Could not read stored credentials; starting signed out',
        error: error,
        stackTrace: stackTrace,
      );
      await _clearLocalSession();
      return const Ok(null);
    } catch (error, stackTrace) {
      _logger.e(
        'Unexpected error restoring session',
        error: error,
        stackTrace: stackTrace,
      );
      await _clearLocalSession();
      return const Ok(null);
    }
  }

  @override
  Future<Result<AuthSession>> signIn(AuthCredentials credentials) =>
      _authenticate(credentials, isSignUp: false);

  @override
  Future<Result<AuthSession>> signUp(AuthCredentials credentials) =>
      _authenticate(credentials, isSignUp: true);

  Future<Result<AuthSession>> _authenticate(
    AuthCredentials credentials, {
    required bool isSignUp,
  }) async {
    // Validate before the round trip: instant feedback, and one source of truth
    // for the rules shared with the form.
    final errors = credentials.validate(requireDisplayName: isSignUp);
    if (errors.isNotEmpty) {
      return Err(
        ValidationFailure(
          message: 'Invalid credentials supplied',
          fieldErrors: errors,
        ),
      );
    }

    return Result.guardAsync(() async {
      final session = isSignUp
          ? await _remote.signUp(credentials)
          : await _remote.signIn(credentials);
      await _persist(session);
      _emit(session);
      _logger.i(
        isSignUp ? 'Account created' : 'Signed in',
        fields: {'user': session.user.email},
      );
      return session;
    });
  }

  @override
  Future<Result<void>> signOut() async {
    // Server first, but never block on it: a user who taps sign-out offline must
    // still end up signed out locally.
    try {
      await _remote.signOut();
    } catch (error) {
      _logger.d(
        'Remote sign-out failed; continuing',
        fields: {'error': '$error'},
      );
    }

    await _clearLocalSession();
    await _onSignedOut?.call();
    _logger.i('Signed out');
    return const Ok(null);
  }

  @override
  Future<Result<AuthSession>> refresh() async {
    final refreshToken = _session?.refreshToken;
    if (refreshToken == null || refreshToken.isEmpty) {
      return const Err(
        AuthFailure(
          message: 'No refresh token available',
          reason: AuthFailureReason.noSession,
        ),
      );
    }

    return Result.guardAsync(() async {
      final session = await _remote.refresh(refreshToken);
      await _persist(session);
      _emit(session);
      _logger.i('Access token refreshed');
      return session;
    });
  }

  // ------------------------------------------------- AuthTokenDelegate

  @override
  Future<String?> currentAccessToken() async => _session?.accessToken;

  @override
  Future<bool> refreshSession() async {
    final result = await refresh();
    return result.isOk;
  }

  @override
  Future<void> onSessionInvalidated() async {
    if (_session == null) return;
    _logger.w('Session invalidated by the server');
    await _clearLocalSession();
    await _onSignedOut?.call();
  }

  // ------------------------------------------------- internals

  Future<void> _persist(AuthSession session) async {
    await _secureStore.write(SecureKeys.accessToken, session.accessToken);
    await _secureStore.write(SecureKeys.refreshToken, session.refreshToken);
    await _secureStore.write(
      SecureKeys.userProfile,
      jsonEncode(session.user.toJson()),
    );
    final expiry = session.accessTokenExpiresAt;
    if (expiry != null) {
      await _secureStore.write(
        SecureKeys.accessTokenExpiry,
        expiry.toIso8601String(),
      );
    } else {
      await _secureStore.delete(SecureKeys.accessTokenExpiry);
    }
  }

  Future<void> _clearLocalSession() async {
    try {
      await _secureStore.clear();
    } catch (error) {
      _logger.w('Failed to clear secure storage', fields: {'error': '$error'});
    }
    _emit(null);
  }

  void _emit(AuthSession? session) {
    _session = session;
    if (!_sessions.isClosed) _sessions.add(session);
  }

  Future<void> dispose() => _sessions.close();
}
