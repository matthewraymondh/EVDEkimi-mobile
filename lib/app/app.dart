import 'package:evdekimi_ai/app/app_router.dart';
import 'package:evdekimi_ai/design_system/app_theme.dart';
import 'package:evdekimi_ai/di/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The application shell.
class EvdekimiApp extends ConsumerWidget {
  const EvdekimiApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(settingsControllerProvider).themeMode;

    // Reading this here starts the outbox coordinator for the app's lifetime, so
    // queued messages are delivered regardless of which screen is on top.
    ref.watch(outboxCoordinatorProvider);

    return MaterialApp.router(
      title: 'EVDEkimi AI',
      debugShowCheckedModeBanner: false,
      routerConfig: ref.watch(routerProvider),

      // Both themes are always supplied and `themeMode` picks between them, so
      // "match system" is handled by the framework and flipping the OS switch
      // re-themes live without a restart.
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: themeMode,

      builder: (context, child) {
        // Clamp text scaling. Accessibility settings must be respected, but past
        // ~1.4x a chat bubble with a metadata footer stops fitting at all, so the
        // cap keeps very large settings usable rather than broken.
        final mediaQuery = MediaQuery.of(context);
        final clamped = mediaQuery.textScaler.clamp(
          minScaleFactor: 0.85,
          maxScaleFactor: 1.4,
        );

        // The app draws edge-to-edge, so the status bar sits over our surface.
        // `AppBarTheme.systemOverlayStyle` only applies on screens that have an
        // AppBar — the conversation list does not, and without this its status
        // bar icons keep whatever the previous screen set and can end up
        // invisible against the light canvas. An AppBar still overrides this.
        final isDark = Theme.of(context).brightness == Brightness.dark;

        return AnnotatedRegion<SystemUiOverlayStyle>(
          value:
              (isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark)
                  .copyWith(
                    statusBarColor: Colors.transparent,
                    systemNavigationBarColor: Colors.transparent,
                  ),
          child: MediaQuery(
            data: mediaQuery.copyWith(textScaler: clamped),
            child: child ?? const SizedBox.shrink(),
          ),
        );
      },
    );
  }
}
