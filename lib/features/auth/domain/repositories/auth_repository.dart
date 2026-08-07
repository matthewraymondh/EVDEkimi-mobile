import 'package:evdekimi_ai/core/result/result.dart';
import 'package:evdekimi_ai/features/auth/domain/entities/auth_session.dart';

/// Auth operations, as the presentation layer sees them.
///
/// Everything returns `Result`, so no caller has to guess which methods throw.
abstract interface class AuthRepository {
  /// The current session, or `null` when signed out. Emits on every change.
  ///
  /// A broadcast stream so the router (redirect guard) and the profile UI can
  /// both listen without one cancelling the other.
  Stream<AuthSession?> get sessionChanges;

  /// The session as of right now, without waiting for the stream.
  AuthSession? get currentSession;

  /// Loads any persisted session at startup and validates it.
  ///
  /// Returns `null` when there is nothing stored or the stored credentials are
  /// unusable — a corrupt keystore entry resolves to "signed out", never to a
  /// crash.
  Future<Result<AuthSession?>> restoreSession();

  Future<Result<AuthSession>> signIn(AuthCredentials credentials);

  Future<Result<AuthSession>> signUp(AuthCredentials credentials);

  /// Clears local credentials and best-effort notifies the server.
  ///
  /// Always succeeds locally: a user who taps sign-out while offline must still
  /// end up signed out on the device.
  Future<Result<void>> signOut();

  /// Exchanges the refresh token. Used by the HTTP layer via the delegate.
  Future<Result<AuthSession>> refresh();
}
