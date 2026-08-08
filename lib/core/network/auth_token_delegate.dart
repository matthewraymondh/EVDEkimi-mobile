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
  ///
  /// **Implementations must collapse concurrent calls into one attempt.** This
  /// is a hard requirement, not an optimisation. There are two independent
  /// transports here — the interceptor for ordinary requests, the SSE client for
  /// streaming — and both can see a 401 in the same instant when a token ages
  /// out mid-screen. With rotating refresh tokens the second attempt presents
  /// one the first has already spent, so it fails, the session is torn down, and
  /// the user is signed out for no reason. The obligation sits here rather than
  /// in either caller precisely because neither can see the other.
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
