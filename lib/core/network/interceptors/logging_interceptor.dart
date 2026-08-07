import 'package:dio/dio.dart';
import 'package:evdekimi_ai/core/logging/app_logger.dart';

/// Structured request/response logging with secret redaction.
///
/// Bodies are never logged wholesale. Prompts are user content and tokens are
/// credentials, so the interceptor records shape and timing (method, path,
/// status, duration, byte count) rather than payloads. That keeps logs useful
/// for debugging latency and 4xx/5xx patterns without turning the log buffer
/// into a transcript of everything the user typed.
class LoggingInterceptor extends Interceptor {
  LoggingInterceptor({required AppLogger logger})
    : _logger = logger.scoped('http');

  static const String _startKey = 'requestStartedAt';

  static const Set<String> _sensitiveHeaders = {
    'authorization',
    'cookie',
    'set-cookie',
    'x-api-key',
  };

  final AppLogger _logger;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.extra[_startKey] = DateTime.now();
    _logger.d(
      '→ ${options.method} ${options.path}',
      fields: {
        if (options.queryParameters.isNotEmpty)
          'query': options.queryParameters.keys.join(','),
        'headers': _redactHeaders(options.headers),
      },
    );
    handler.next(options);
  }

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    _logger.i(
      '← ${response.statusCode} ${response.requestOptions.method} '
      '${response.requestOptions.path}',
      fields: {
        'durationMs': _elapsedMs(response.requestOptions),
        if (response.requestOptions.responseType == ResponseType.stream)
          'stream': true,
      },
    );
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    _logger.w(
      '✗ ${err.response?.statusCode ?? err.type.name} '
      '${err.requestOptions.method} ${err.requestOptions.path}',
      fields: {
        'durationMs': _elapsedMs(err.requestOptions),
        'type': err.type.name,
      },
      error: err.error ?? err.message,
    );
    handler.next(err);
  }

  static int? _elapsedMs(RequestOptions options) {
    final startedAt = options.extra[_startKey];
    if (startedAt is! DateTime) return null;
    return DateTime.now().difference(startedAt).inMilliseconds;
  }

  /// Lists header names, replacing the values of credential-bearing ones.
  static String _redactHeaders(Map<String, dynamic> headers) {
    if (headers.isEmpty) return '-';
    return headers.keys
        .map(
          (key) =>
              _sensitiveHeaders.contains(key.toLowerCase()) ? '$key=***' : key,
        )
        .join(',');
  }
}
