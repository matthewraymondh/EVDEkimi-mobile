import 'dart:async';

import 'package:dio/dio.dart';
import 'package:evdekimi_ai/core/logging/app_logger.dart';
import 'package:evdekimi_ai/core/network/auth_token_delegate.dart';

/// Attaches the bearer token and transparently recovers from a 401.
///
/// A chat screen can easily fire several requests at once (history, models, an
/// upload); if the token has just expired they all get a 401 at the same
/// instant. Collapsing those into one refresh is essential — but it is *not*
/// done here, because this interceptor is not the only transport that can hit a
/// 401. `SseClient` bypasses it entirely (see the note there), so a
/// single-flight local to this class would still let two refreshes race.
/// [AuthTokenDelegate.refreshSession] owns that guarantee for every caller.
///
/// What is left here is the per-request half: refresh, then replay this one
/// request exactly once with the new credentials.
class AuthInterceptor extends Interceptor {
  AuthInterceptor({
    required AuthTokenDelegate delegate,
    required AppLogger logger,
  }) : _delegate = delegate,
       _logger = logger.scoped('http.auth');

  /// Requests marked with this flag skip both the header and the retry logic.
  ///
  /// Used by `/auth/login` and `/auth/refresh`, which must never recurse.
  static const String skipAuthFlag = 'skipAuth';

  /// Set on a request that has already been retried once after a refresh, so a
  /// second 401 fails instead of looping.
  static const String _retriedFlag = 'authRetried';

  final AuthTokenDelegate _delegate;
  final AppLogger _logger;

  /// The client this interceptor is installed on, used to replay requests.
  ///
  /// Injected after construction because the client and the interceptor are
  /// mutually dependent. Replaying through the owning client (rather than a
  /// throwaway `Dio()`) preserves the configured adapter, transformer and
  /// base options — a bare instance would silently drop them.
  late final Dio _client;

  /// Called by `DioFactory` immediately after the client is built.
  // ignore: use_setters_to_change_properties
  void attach(Dio client) => _client = client;

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    if (options.extra[skipAuthFlag] == true) {
      return handler.next(options);
    }
    final token = await _delegate.currentAccessToken();
    if (token != null && token.isNotEmpty) {
      options.headers['Authorization'] = 'Bearer $token';
    }
    handler.next(options);
  }

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final options = err.requestOptions;
    final isUnauthorized = err.response?.statusCode == 401;
    final canAttempt =
        isUnauthorized &&
        options.extra[skipAuthFlag] != true &&
        options.extra[_retriedFlag] != true;

    if (!canAttempt) {
      return handler.next(err);
    }

    _logger.d(
      '401 received, attempting refresh',
      fields: {'path': options.path},
    );

    final refreshed = await _delegate.refreshSession();
    if (!refreshed) {
      _logger.w('Refresh failed; invalidating session');
      await _delegate.onSessionInvalidated();
      return handler.next(err);
    }

    // Replay the original request exactly once with the new credentials.
    try {
      final token = await _delegate.currentAccessToken();
      final retryOptions = options
        ..extra[_retriedFlag] = true
        ..headers['Authorization'] = 'Bearer $token';

      final response = await _client.fetch<dynamic>(retryOptions);
      _logger.d(
        'Replay after refresh succeeded',
        fields: {'path': options.path},
      );
      return handler.resolve(response);
    } on DioException catch (retryError) {
      _logger.w(
        'Replay after refresh failed',
        fields: {'path': options.path},
        error: retryError,
      );
      return handler.next(retryError);
    }
  }
}
