import 'package:evdekimi_ai/design_system/chat_theme.dart';
import 'package:evdekimi_ai/design_system/palette.dart';
import 'package:evdekimi_ai/design_system/tokens.dart';
import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Builds the light and dark themes.
///
/// Seeded from the accent so Material's generated roles stay related, then every
/// surface and text role is overridden by hand. The overrides are not a tweak —
/// they are the theme. `ColorScheme.fromSeed` spreads a *tinted* tonal palette
/// across surfaces, and a tinted surface is precisely what glass cannot sit on:
/// the refraction has to be the most colourful thing in the panel, so the plane
/// behind it has to be neutral.
///
/// Read the surface roles below as an elevation ladder. Dark climbs
/// `#09090B → #18181B → #27272A`; light climbs `#F8FAFC → #FFFFFF`.
abstract final class AppTheme {
  static ThemeData light() => _build(_lightScheme, ChatTheme.light);

  static ThemeData dark() => _build(_darkScheme, ChatTheme.dark);

  static final ColorScheme _lightScheme =
      ColorScheme.fromSeed(
        seedColor: AppPalette.accentDeep,
        // ignore: avoid_redundant_argument_values
        brightness: Brightness.light,
      ).copyWith(
        surface: AppPalette.slate50,
        surfaceContainerLowest: AppPalette.white,
        surfaceContainerLow: AppPalette.white,
        surfaceContainer: AppPalette.zinc100,
        surfaceContainerHigh: AppPalette.zinc200,
        surfaceContainerHighest: AppPalette.zinc300,
        onSurface: AppPalette.zinc900,
        // zinc400 is the muted tone in dark mode; on this page it is 2.5:1.
        onSurfaceVariant: AppPalette.zinc500,
        outline: AppPalette.zinc400,
        outlineVariant: AppPalette.zinc200,
        primary: AppPalette.accentDeep,
        onPrimary: AppPalette.white,
        primaryContainer: AppPalette.accentMuted,
        error: AppPalette.dangerLight,
      );

  static final ColorScheme _darkScheme =
      ColorScheme.fromSeed(
        seedColor: AppPalette.accent,
        brightness: Brightness.dark,
      ).copyWith(
        surface: AppPalette.zinc950,
        // Pure black, so a well can still sit *below* the page.
        surfaceContainerLowest: const Color(0xFF000000),
        surfaceContainerLow: AppPalette.zinc900,
        surfaceContainer: AppPalette.zinc900,
        surfaceContainerHigh: AppPalette.zinc800,
        surfaceContainerHighest: AppPalette.zinc700,
        onSurface: AppPalette.zinc100,
        onSurfaceVariant: AppPalette.zinc400,
        outline: AppPalette.zinc600,
        outlineVariant: AppPalette.zinc800,
        // A bright tone with a dark foreground, which is the Material 3 dark
        // pattern and the only way round that works: white on #3B82F6 is 3.7:1
        // and fails for button labels.
        primary: AppPalette.accent,
        onPrimary: AppPalette.zinc950,
        primaryContainer: AppPalette.accentDeep,
        error: AppPalette.dangerDark,
      );

  static ThemeData _build(ColorScheme scheme, ChatTheme chatTheme) {
    final isDark = scheme.brightness == Brightness.dark;
    final textTheme = _textTheme(scheme);

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      textTheme: textTheme,
      extensions: <ThemeExtension<dynamic>>[chatTheme],

      // Density is left at the platform default: a chat list is touch-first and
      // tightening it would push rows under the 48dp accessibility floor.
      visualDensity: VisualDensity.standard,

      // Ripples read as heavy on large text surfaces like message bubbles.
      splashFactory: InkSparkle.splashFactory,

      // Predictive back on Android gives the system-driven peek gesture and
      // degrades to the zoom transition where the platform lacks it; iOS keeps
      // its native edge-swipe so the interactive pop feels correct there.
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: PredictiveBackPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        },
      ),

      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: AppElevation.none,
        scrolledUnderElevation: AppElevation.none,
        centerTitle: false,
        titleTextStyle: textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w600,
        ),
        // Keeps the status bar icons legible against our custom surface, which
        // Material cannot infer once `surface` is overridden.
        systemOverlayStyle: isDark
            ? SystemUiOverlayStyle.light
            : SystemUiOverlayStyle.dark,
      ),

      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: 1,
        space: 1,
      ),

      cardTheme: CardThemeData(
        color: scheme.surfaceContainerLow,
        elevation: AppElevation.none,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: AppRadius.allMd,
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerLow,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.md,
        ),
        hintStyle: textTheme.bodyMedium?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
        border: OutlineInputBorder(
          borderRadius: AppRadius.allMd,
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: AppRadius.allMd,
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: AppRadius.allMd,
          borderSide: BorderSide(color: scheme.primary, width: 1.6),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: AppRadius.allMd,
          borderSide: BorderSide(color: scheme.error),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: AppRadius.allMd,
          borderSide: BorderSide(color: scheme.error, width: 1.6),
        ),
      ),

      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(AppSizes.minTapTarget),
          shape: const RoundedRectangleBorder(borderRadius: AppRadius.allMd),
          textStyle: textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
      ),

      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(AppSizes.minTapTarget),
          side: BorderSide(color: scheme.outlineVariant),
          shape: const RoundedRectangleBorder(borderRadius: AppRadius.allMd),
          textStyle: textTheme.labelLarge,
        ),
      ),

      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          textStyle: textTheme.labelLarge,
          shape: const RoundedRectangleBorder(borderRadius: AppRadius.allSm),
        ),
      ),

      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          minimumSize: const Size.square(AppSizes.minTapTarget),
          shape: const RoundedRectangleBorder(borderRadius: AppRadius.allSm),
        ),
      ),

      chipTheme: ChipThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        side: BorderSide(color: scheme.outlineVariant),
        labelStyle: textTheme.labelMedium,
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: AppSpacing.xxs,
        ),
        shape: const RoundedRectangleBorder(borderRadius: AppRadius.allPill),
      ),

      listTileTheme: ListTileThemeData(
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.gutter,
          vertical: AppSpacing.xs,
        ),
        shape: const RoundedRectangleBorder(borderRadius: AppRadius.allMd),
        titleTextStyle: textTheme.bodyLarge,
        subtitleTextStyle: textTheme.bodySmall?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),

      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: isDark ? AppPalette.zinc800 : AppPalette.zinc900,
        contentTextStyle: textTheme.bodyMedium?.copyWith(
          color: AppPalette.zinc100,
        ),
        shape: const RoundedRectangleBorder(borderRadius: AppRadius.allMd),
        insetPadding: const EdgeInsets.all(AppSpacing.lg),
      ),

      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        modalBarrierColor: AppPalette.zinc950.withValues(alpha: 0.6),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: AppRadius.xxl),
        ),
        showDragHandle: true,
      ),

      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(borderRadius: AppRadius.allLg),
        titleTextStyle: textTheme.titleMedium,
        contentTextStyle: textTheme.bodyMedium,
      ),

      tooltipTheme: TooltipThemeData(
        decoration: const BoxDecoration(
          color: AppPalette.zinc800,
          borderRadius: AppRadius.allSm,
        ),
        textStyle: textTheme.labelSmall?.copyWith(color: AppPalette.zinc100),
      ),

      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
        linearMinHeight: 2,
      ),

      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surface,
        indicatorColor: scheme.primary.withValues(alpha: 0.14),
        elevation: AppElevation.none,
        labelTextStyle: WidgetStatePropertyAll(textTheme.labelSmall),
      ),

      scrollbarTheme: ScrollbarThemeData(
        thickness: const WidgetStatePropertyAll(4),
        radius: AppRadius.xs,
        thumbColor: WidgetStatePropertyAll(
          scheme.onSurfaceVariant.withValues(alpha: 0.4),
        ),
      ),
    );
  }

  /// A tuned type scale.
  ///
  /// Deliberately uses the platform UI font instead of a bundled webfont: it
  /// keeps the download small, renders text in the face the user already reads
  /// system-wide, and avoids a runtime font fetch that would fail offline —
  /// which matters for an app whose selling point is working without a network.
  /// The tuning is in the metrics, not the family.
  static TextTheme _textTheme(ColorScheme scheme) {
    final base = Typography.material2021(colorScheme: scheme);
    final source = scheme.brightness == Brightness.dark
        ? base.white
        : base.black;

    return source
        .copyWith(
          // Display/headline get negative tracking: large type set at default
          // tracking looks loose and unintentional.
          headlineSmall: source.headlineSmall?.copyWith(
            fontWeight: FontWeight.w600,
            letterSpacing: -0.4,
            height: 1.25,
          ),
          titleLarge: source.titleLarge?.copyWith(
            fontWeight: FontWeight.w600,
            letterSpacing: -0.2,
          ),
          titleMedium: source.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
            letterSpacing: -0.1,
          ),
          // 1.5 line height on body copy: message text is the one thing users
          // read in volume, and it is set for paragraph reading, not labels.
          bodyLarge: source.bodyLarge?.copyWith(fontSize: 16, height: 1.5),
          bodyMedium: source.bodyMedium?.copyWith(fontSize: 14.5, height: 1.5),
          bodySmall: source.bodySmall?.copyWith(fontSize: 12.5, height: 1.4),
          labelLarge: source.labelLarge?.copyWith(letterSpacing: 0),
          labelSmall: source.labelSmall?.copyWith(letterSpacing: 0.2),
        )
        .apply(displayColor: scheme.onSurface, bodyColor: scheme.onSurface);
  }

  /// Monospace stack for code blocks, resolved per platform.
  static const List<String> monospaceFallback = [
    'SF Mono',
    'Menlo',
    'Roboto Mono',
    'Courier New',
    'monospace',
  ];
}
