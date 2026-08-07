import 'package:flutter/foundation.dart';

/// Which deployment the binary is pointed at.
enum AppFlavor {
  /// Local Mockoon / dev backend, verbose logging, debug affordances on.
  dev,

  /// Staging backend, verbose logging, debug affordances on.
  staging,

  /// Production backend, minimal logging, debug affordances off.
  prod;

  bool get isProd => this == AppFlavor.prod;
}

/// Immutable, compile-time-injected configuration.
///
/// Every environment-dependent value enters the app here via `--dart-define`,
/// so nothing downstream reads `String.fromEnvironment` directly and tests can
/// construct any configuration they like with [AppConfig.test].
///
/// Run against a local mock:
/// ```
/// flutter run --dart-define=API_BASE_URL=http://10.0.2.2:3001 \
///             --dart-define=FLAVOR=dev
/// ```
@immutable
class AppConfig {
  const AppConfig({
    required this.flavor,
    required this.apiBaseUrl,
    required this.connectTimeout,
    required this.receiveTimeout,
    required this.streamIdleTimeout,
    required this.maxRetryAttempts,
    required this.enableNetworkLogging,
    required this.enableOnDeviceInference,
    required this.outboxFlushInterval,
    required this.messagePageSize,
  });

  /// Reads configuration from `--dart-define` values with dev-friendly
  /// defaults. Defaults intentionally point at a local mock server.
  factory AppConfig.fromEnvironment() {
    const flavorName = String.fromEnvironment('FLAVOR', defaultValue: 'dev');
    final flavor = AppFlavor.values.firstWhere(
      (candidate) => candidate.name == flavorName,
      orElse: () => AppFlavor.dev,
    );

    // 10.0.2.2 is the Android emulator's alias for the host machine. iOS
    // simulators share the host network, so localhost works there.
    const baseUrl = String.fromEnvironment(
      'API_BASE_URL',
      defaultValue: 'http://10.0.2.2:3001',
    );

    return AppConfig(
      flavor: flavor,
      apiBaseUrl: baseUrl,
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 30),
      // Streaming responses legitimately pause between tokens, so the guard we
      // want is "no bytes for N seconds", not a total-duration cap.
      streamIdleTimeout: const Duration(seconds: 25),
      maxRetryAttempts: 2,
      enableNetworkLogging: !flavor.isProd,
      enableOnDeviceInference: const bool.fromEnvironment(
        'ENABLE_ON_DEVICE',
        defaultValue: true,
      ),
      outboxFlushInterval: const Duration(seconds: 15),
      messagePageSize: 50,
    );
  }

  /// A deterministic configuration for tests.
  @visibleForTesting
  factory AppConfig.test({
    String apiBaseUrl = 'http://localhost:3001',
    bool enableOnDeviceInference = true,
    int maxRetryAttempts = 0,
  }) => AppConfig(
    flavor: AppFlavor.dev,
    apiBaseUrl: apiBaseUrl,
    connectTimeout: const Duration(milliseconds: 200),
    receiveTimeout: const Duration(milliseconds: 500),
    streamIdleTimeout: const Duration(milliseconds: 500),
    maxRetryAttempts: maxRetryAttempts,
    enableNetworkLogging: false,
    enableOnDeviceInference: enableOnDeviceInference,
    outboxFlushInterval: const Duration(milliseconds: 100),
    messagePageSize: 20,
  );

  final AppFlavor flavor;
  final String apiBaseUrl;
  final Duration connectTimeout;
  final Duration receiveTimeout;

  /// Maximum silence between two SSE chunks before the stream is abandoned.
  final Duration streamIdleTimeout;

  /// Retries for idempotent requests only; never applied to streaming sends.
  final int maxRetryAttempts;

  final bool enableNetworkLogging;
  final bool enableOnDeviceInference;

  /// How often the outbox retries queued messages while online.
  final Duration outboxFlushInterval;

  final int messagePageSize;

  /// Whether in-app developer surfaces (log console, engine inspector) show.
  bool get showDiagnostics => !flavor.isProd;

  @override
  String toString() =>
      'AppConfig(flavor: ${flavor.name}, apiBaseUrl: $apiBaseUrl, '
      'onDevice: $enableOnDeviceInference)';
}

/// Route/endpoint constants, kept beside config so URL shape is reviewable.
abstract final class ApiRoutes {
  static const String signIn = '/auth/login';
  static const String signUp = '/auth/register';
  static const String refresh = '/auth/refresh';
  static const String signOut = '/auth/logout';
  static const String me = '/auth/me';

  static const String conversations = '/conversations';
  static const String models = '/models';
  static const String uploads = '/uploads';

  /// Streaming completion endpoint (server-sent events).
  static const String chatCompletions = '/chat/completions';

  static String conversation(String id) => '$conversations/$id';

  static String conversationMessages(String id) =>
      '$conversations/$id/messages';
}
