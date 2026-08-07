import 'dart:async';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:evdekimi_ai/core/logging/app_logger.dart';

/// Retries transient failures with exponential backoff and full jitter.
///
/// Two deliberate restrictions keep this safe:
///
/// * **Opt-in, not opt-out.** Only idempotent methods (GET/HEAD) retry by
///   default. A POST that creates a message must not be replayed blindly, so
///   non-idempotent callers opt in explicitly via [retryableFlag] once they
///   carry an idempotency key.
/// * **Never streaming.** A partially consumed SSE response cannot be replayed
///   without duplicating tokens the UI already rendered, so stream requests are
///   excluded outright and recovery is handled at the chat-repository level.
class RetryInterceptor extends Interceptor {
  RetryInterceptor({
    required AppLogger logger,
    required this.maxAttempts,
    this.baseDelay = const Duration(milliseconds: 300),
    this.maxDelay = const Duration(seconds: 8),
    Random? random,
  }) : _logger = logger.scoped('http.retry'),
       _random = random ?? Random();

  /// Set `extra[retryableFlag] = true` to allow retrying a non-idempotent call.
  static const String retryableFlag = 'retryable';

  static const String _attemptKey = 'retryAttempt';

  final AppLogger _logger;
  final int maxAttempts;
  final Duration baseDelay;
  final Duration maxDelay;
  final Random _random;

  late final Dio _client;

  /// Called by `DioFactory` after the client is constructed.
  // ignore: use_setters_to_change_properties
  void attach(Dio client) => _client = client;

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final options = err.requestOptions;
    final attempt = (options.extra[_attemptKey] as int?) ?? 0;

    if (!_shouldRetry(err, attempt)) {
      return handler.next(err);
    }

    final delay = _delayFor(attempt, err.response);
    _logger.d(
      'Retrying request',
      fields: {
        'path': options.path,
        'attempt': attempt + 1,
        'maxAttempts': maxAttempts,
        'delayMs': delay.inMilliseconds,
      },
    );

    await Future<void>.delayed(delay);

    try {
      final response = await _client.fetch<dynamic>(
        options..extra[_attemptKey] = attempt + 1,
      );
      return handler.resolve(response);
    } on DioException catch (retryError) {
      // Re-enter onError so the next attempt is evaluated with the bumped
      // counter rather than terminating the chain here.
      return handler.next(retryError);
    }
  }

  bool _shouldRetry(DioException err, int attempt) {
    if (attempt >= maxAttempts) return false;

    // A stream response is already being consumed downstream; replaying it
    // would emit duplicate tokens.
    if (err.requestOptions.responseType == ResponseType.stream) return false;

    if (err.type == DioExceptionType.cancel) return false;

    final method = err.requestOptions.method.toUpperCase();
    final isIdempotent = method == 'GET' || method == 'HEAD';
    final isOptedIn = err.requestOptions.extra[retryableFlag] == true;
    if (!isIdempotent && !isOptedIn) return false;

    return switch (err.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout ||
      DioExceptionType.transformTimeout ||
      DioExceptionType.connectionError => true,
      DioExceptionType.badResponse => _isRetryableStatus(
        err.response?.statusCode,
      ),
      DioExceptionType.badCertificate ||
      DioExceptionType.cancel ||
      DioExceptionType.unknown => false,
    };
  }

  static bool _isRetryableStatus(int? statusCode) =>
      statusCode == 408 ||
      statusCode == 429 ||
      (statusCode != null && statusCode >= 500 && statusCode < 600);

  /// Exponential backoff with full jitter, capped, honouring `Retry-After`.
  ///
  /// Full jitter (a uniform draw over the whole window rather than a fixed
  /// delay) is what prevents a fleet of clients from retrying in lockstep after
  /// a server blip.
  Duration _delayFor(int attempt, Response<dynamic>? response) {
    final retryAfter = _parseRetryAfter(response);
    if (retryAfter != null) {
      return retryAfter > maxDelay ? maxDelay : retryAfter;
    }

    final exponential = baseDelay.inMilliseconds * pow(2, attempt).toInt();
    final capped = min(exponential, maxDelay.inMilliseconds);
    // Guard against a zero-width window when baseDelay is tiny in tests.
    final jittered = capped <= 0 ? 0 : _random.nextInt(capped + 1);
    return Duration(milliseconds: jittered);
  }

  static Duration? _parseRetryAfter(Response<dynamic>? response) {
    final header = response?.headers.value('retry-after');
    if (header == null) return null;

    final seconds = int.tryParse(header.trim());
    if (seconds != null) return Duration(seconds: seconds);

    // The header may also be an HTTP date.
    final date = DateTime.tryParse(header);
    if (date == null) return null;
    final delta = date.difference(DateTime.now());
    return delta.isNegative ? Duration.zero : delta;
  }
}
