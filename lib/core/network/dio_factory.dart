import 'package:dio/dio.dart';
import 'package:evdekimi_ai/core/config/app_config.dart';
import 'package:evdekimi_ai/core/logging/app_logger.dart';
import 'package:evdekimi_ai/core/network/auth_token_delegate.dart';
import 'package:evdekimi_ai/core/network/interceptors/auth_interceptor.dart';
import 'package:evdekimi_ai/core/network/interceptors/logging_interceptor.dart';
import 'package:evdekimi_ai/core/network/interceptors/retry_interceptor.dart';

/// Builds the single configured [Dio] instance used by every data source.
///
/// Interceptor order is load-bearing and is asserted by a test:
/// logging → auth → retry.
///
/// * Logging runs first on the request so it observes the outbound call before
///   headers are attached, and last on the error path so it sees the terminal
///   outcome after recovery has been attempted.
/// * Auth precedes retry so a 401 is resolved by refreshing once rather than
///   being burned as one of the retry attempts.
abstract final class DioFactory {
  static Dio create({
    required AppConfig config,
    required AppLogger logger,
    required AuthTokenDelegate authDelegate,
    HttpClientAdapter? adapter,
  }) {
    final dio = Dio(
      BaseOptions(
        baseUrl: config.apiBaseUrl,
        connectTimeout: config.connectTimeout,
        receiveTimeout: config.receiveTimeout,
        // Cross-platform: never let a stray HTML error page be parsed as JSON.
        contentType: Headers.jsonContentType,
        headers: const {'Accept': 'application/json'},
      ),
    );

    if (adapter != null) {
      dio.httpClientAdapter = adapter;
    }

    final authInterceptor = AuthInterceptor(
      delegate: authDelegate,
      logger: logger,
    );
    final retryInterceptor = RetryInterceptor(
      logger: logger,
      maxAttempts: config.maxRetryAttempts,
    );

    // Both interceptors replay requests, which requires a reference back to the
    // client they belong to. Resolved here rather than by constructing a second
    // Dio, so the adapter and transformer configured above are preserved.
    authInterceptor.attach(dio);
    retryInterceptor.attach(dio);

    dio.interceptors.addAll([
      if (config.enableNetworkLogging) LoggingInterceptor(logger: logger),
      authInterceptor,
      retryInterceptor,
    ]);

    return dio;
  }
}
