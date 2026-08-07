import 'dart:async';

import 'package:evdekimi_ai/app/app.dart';
import 'package:evdekimi_ai/core/config/app_config.dart';
import 'package:evdekimi_ai/core/connectivity/connectivity_service.dart';
import 'package:evdekimi_ai/core/logging/app_logger.dart';
import 'package:evdekimi_ai/core/logging/log_sink.dart';
import 'package:evdekimi_ai/core/persistence/key_value_store.dart';
import 'package:evdekimi_ai/di/providers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Composes the app and installs global error handling.
///
/// Ordering here is deliberate. Logging comes first so anything that fails
/// afterwards is recorded; the error handlers are installed before the first
/// widget is built; and the async singletons (preferences, connectivity) are
/// awaited so no screen has to render a loading state for infrastructure.
Future<void> bootstrap() async {
  WidgetsFlutterBinding.ensureInitialized();

  final config = AppConfig.fromEnvironment();

  // Defaults to a 500-record buffer at debug level; trace would be far too
  // chatty to keep anything useful in a bounded buffer.
  final logBuffer = RingBufferLogSink();
  final logger = AppLogger(
    sinks: [
      // The console sink is debug/profile only: in release it would be dead
      // weight, and `dart:developer` output is not collected there anyway.
      if (!kReleaseMode) ConsoleLogSink(),
      logBuffer,
    ],
  );

  logger.i('Starting EVDEkimi AI', fields: {'config': config.toString()});

  // Everything from here runs inside a guarded zone so an async error in a
  // repository or a stream cannot silently vanish.
  await runZonedGuarded(
    () async {
      _installErrorHandlers(logger);

      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);

      // Let the app draw behind the system bars; the theme sets the icon
      // brightness to match our custom surfaces.
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

      final keyValueStore = await SharedPreferencesStore.open();

      final connectivity = ConnectivityPlusService(logger: logger);
      await connectivity.initialise();

      final container = ProviderContainer(
        overrides: [
          appConfigProvider.overrideWithValue(config),
          loggerProvider.overrideWithValue(logger),
          logBufferProvider.overrideWithValue(logBuffer),
          keyValueStoreProvider.overrideWithValue(keyValueStore),
          connectivityServiceProvider.overrideWithValue(connectivity),
        ],
      );

      // Restore the session before the first frame so the router's guard has an
      // answer and the splash screen resolves straight to the right destination.
      await _warmUp(container, logger);

      runApp(
        UncontrolledProviderScope(
          container: container,
          child: const EvdekimiApp(),
        ),
      );
    },
    (error, stackTrace) {
      logger.e('Uncaught zone error', error: error, stackTrace: stackTrace);
    },
  );
}

/// Work that must complete before the first frame.
///
/// Kept small on purpose: anything not needed for the first routing decision is
/// scheduled after startup instead of delaying it.
Future<void> _warmUp(ProviderContainer container, AppLogger logger) async {
  try {
    final authRepository = container.read(authRepositoryProvider);
    await authRepository.restoreSession();

    final chatRepository = container.read(chatRepositoryProvider);

    // A message left in `sending`/`streaming` by a force-quit can never resume,
    // so demote it now rather than letting the UI show a spinner forever.
    await chatRepository.recoverInterruptedMessages();

    // Deliberately not awaited: these are useful but must not hold the first
    // frame. Failures are logged inside.
    unawaited(chatRepository.flushOutbox());
    unawaited(chatRepository.backfillEmbeddings(limit: 50));
  } catch (error, stackTrace) {
    // Startup must be survivable. A failure here leaves the user signed out
    // rather than looking at a blank screen.
    logger.e('Warm-up failed', error: error, stackTrace: stackTrace);
  }
}

/// Routes framework and platform errors into our logger.
void _installErrorHandlers(AppLogger logger) {
  final flutterLogger = logger.scoped('flutter');

  FlutterError.onError = (details) {
    flutterLogger.e(
      details.exceptionAsString(),
      fields: {
        if (details.library != null) 'library': details.library!,
        if (details.context != null) 'context': details.context!.toString(),
      },
      error: details.exception,
      stackTrace: details.stack,
    );
    // Keep the default red-screen/console behaviour in debug.
    if (kDebugMode) FlutterError.presentError(details);
  };

  // Errors from the platform side that never reach a Dart zone.
  PlatformDispatcher.instance.onError = (error, stackTrace) {
    flutterLogger.e(
      'Platform dispatcher error',
      error: error,
      stackTrace: stackTrace,
    );
    return true;
  };
}
