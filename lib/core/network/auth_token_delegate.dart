/// The contract the HTTP layer needs in order to authenticate requests.
///
/// Declared in `core` and implemented by the auth feature, so the transport
/// never imports feature code — the dependency points inward. This is what
/// lets `AuthInterceptor` refresh a session without knowing that sessions are
/// stored in secure storage, or that a `User` exists at all.
abstract interface class AuthTokenDelegate {
  /// The current bearer token, or `null` when unauthenticated.
  Future<String?> currentAccessToken();

  /// Attempts to exchange the refresh token for a new access token.
  ///
  /// Returns `true` when a fresh access token is available afterwards.
  /// Implementations must be safe to call concurrently; the interceptor
  /// additionally collapses concurrent callers into a single attempt.
  Future<bool> refreshSession();

  /// Invoked when the session is definitively unusable, so the app can sign the
  /// user out and route to the login screen exactly once.
  Future<void> onSessionInvalidated();
}

/// A delegate for unauthenticated contexts (tests, pre-login bootstrapping).
class NoopAuthTokenDelegate implements AuthTokenDelegate {
  const NoopAuthTokenDelegate();

  @override
  Future<String?> currentAccessToken() async => null;

  @override
  Future<bool> refreshSession() async => false;

  @override
  Future<void> onSessionInvalidated() async {}
}

/// Breaks the construction cycle between the HTTP client and the auth repository.
///
/// The knot: `Dio` needs an [AuthTokenDelegate] to attach tokens, the auth
/// repository *is* that delegate, and it needs `Dio` to make requests. Rather
/// than reach for a service locator or a late-initialised global, the HTTP client
/// is given this indirection and the real delegate is bound once both exist.
///
/// Before binding it behaves exactly like [NoopAuthTokenDelegate], which is the
/// correct behaviour anyway: no session can exist before the repository does, so
/// requests in that window are legitimately unauthenticated.
class DeferredAuthTokenDelegate implements AuthTokenDelegate {
  AuthTokenDelegate? _delegate;

  bool get isBound => _delegate != null;

  /// Installs the real delegate. Calling twice is a programming error.
  void bind(AuthTokenDelegate delegate) {
    assert(
      _delegate == null,
      'DeferredAuthTokenDelegate was already bound; binding twice would leave '
      'requests authenticating against a stale session.',
    );
    _delegate = delegate;
  }

  @override
  Future<String?> currentAccessToken() async =>
      _delegate?.currentAccessToken() ?? Future.value();

  @override
  Future<bool> refreshSession() async =>
      await _delegate?.refreshSession() ?? false;

  @override
  Future<void> onSessionInvalidated() async =>
      _delegate?.onSessionInvalidated();
}
