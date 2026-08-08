import 'package:equatable/equatable.dart';
import 'package:evdekimi_ai/core/persistence/key_value_store.dart';
import 'package:evdekimi_ai/features/ai/domain/model_descriptor.dart';
import 'package:flutter/material.dart' show ThemeMode;

/// User preferences.
class AppSettings extends Equatable {
  const AppSettings({
    this.themeMode = ThemeMode.system,
    this.selectedModelId = 'gpt-4o-mini',
    this.preferredEngine = EngineKind.remote,
    this.useOnDeviceWhenOffline = true,
    this.hapticsEnabled = true,
    this.sendOnEnter = false,
    this.liquidGlass = true,
  });

  final ThemeMode themeMode;
  final String selectedModelId;
  final EngineKind preferredEngine;

  /// Whether an offline send may fall back to the on-device engine instead of
  /// being queued. Exposed because the local model answers a narrow set of
  /// requests and some users would rather wait for the real one.
  final bool useOnDeviceWhenOffline;

  final bool hapticsEnabled;

  /// Hardware-keyboard behaviour: Enter sends, or Enter inserts a newline.
  final bool sendOnEnter;

  /// Refractive glass on the floating chrome.
  ///
  /// Exposed because it is a legibility trade, not just a taste one: glass
  /// lowers contrast between chrome and whatever scrolls behind it. The
  /// platform's high-contrast setting overrides this independently.
  final bool liquidGlass;

  AppSettings copyWith({
    ThemeMode? themeMode,
    String? selectedModelId,
    EngineKind? preferredEngine,
    bool? useOnDeviceWhenOffline,
    bool? hapticsEnabled,
    bool? sendOnEnter,
    bool? liquidGlass,
  }) => AppSettings(
    themeMode: themeMode ?? this.themeMode,
    selectedModelId: selectedModelId ?? this.selectedModelId,
    preferredEngine: preferredEngine ?? this.preferredEngine,
    useOnDeviceWhenOffline:
        useOnDeviceWhenOffline ?? this.useOnDeviceWhenOffline,
    hapticsEnabled: hapticsEnabled ?? this.hapticsEnabled,
    sendOnEnter: sendOnEnter ?? this.sendOnEnter,
    liquidGlass: liquidGlass ?? this.liquidGlass,
  );

  @override
  List<Object?> get props => [
    themeMode,
    selectedModelId,
    preferredEngine,
    useOnDeviceWhenOffline,
    hapticsEnabled,
    sendOnEnter,
    liquidGlass,
  ];
}

/// Reads and writes [AppSettings] through the key-value store.
///
/// Settings are read synchronously after bootstrap so the very first frame paints
/// in the right theme — a persisted dark-mode preference must not flash light.
class SettingsRepository {
  SettingsRepository(this._store);

  final KeyValueStore _store;

  AppSettings load() {
    const defaults = AppSettings();
    return AppSettings(
      themeMode: _readThemeMode() ?? defaults.themeMode,
      selectedModelId:
          _store.getString(PreferenceKeys.selectedModelId) ??
          defaults.selectedModelId,
      preferredEngine: EngineKind.fromName(
        _store.getString(PreferenceKeys.preferredEngine),
      ),
      useOnDeviceWhenOffline:
          _store.getBool(PreferenceKeys.onDeviceWhenOffline) ??
          defaults.useOnDeviceWhenOffline,
      hapticsEnabled:
          _store.getBool(PreferenceKeys.hapticsEnabled) ??
          defaults.hapticsEnabled,
      sendOnEnter:
          _store.getBool(PreferenceKeys.sendOnEnter) ?? defaults.sendOnEnter,
      liquidGlass:
          _store.getBool(PreferenceKeys.liquidGlass) ?? defaults.liquidGlass,
    );
  }

  Future<void> save(AppSettings settings) async {
    await _store.setString(PreferenceKeys.themeMode, settings.themeMode.name);
    await _store.setString(
      PreferenceKeys.selectedModelId,
      settings.selectedModelId,
    );
    await _store.setString(
      PreferenceKeys.preferredEngine,
      settings.preferredEngine.name,
    );
    await _store.setBool(
      PreferenceKeys.onDeviceWhenOffline,
      value: settings.useOnDeviceWhenOffline,
    );
    await _store.setBool(
      PreferenceKeys.hapticsEnabled,
      value: settings.hapticsEnabled,
    );
    await _store.setBool(
      PreferenceKeys.sendOnEnter,
      value: settings.sendOnEnter,
    );
    await _store.setBool(
      PreferenceKeys.liquidGlass,
      value: settings.liquidGlass,
    );
  }

  ThemeMode? _readThemeMode() {
    final raw = _store.getString(PreferenceKeys.themeMode);
    if (raw == null) return null;
    for (final mode in ThemeMode.values) {
      if (mode.name == raw) return mode;
    }
    return null;
  }
}
