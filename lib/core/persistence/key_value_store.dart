import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Non-sensitive local preferences (theme, selected model, feature toggles).
///
/// Deliberately separate from [SecureStore]: this is fast, synchronous-after-
/// load, and unencrypted. Anything that would be damaging to leak belongs in
/// secure storage instead, and keeping the two behind different interfaces makes
/// that choice explicit at every call site.
abstract interface class KeyValueStore {
  String? getString(String key);

  Future<void> setString(String key, String value);

  bool? getBool(String key);

  Future<void> setBool(String key, {required bool value});

  int? getInt(String key);

  Future<void> setInt(String key, int value);

  Map<String, dynamic>? getJson(String key);

  Future<void> setJson(String key, Map<String, dynamic> value);

  Future<void> remove(String key);
}

class SharedPreferencesStore implements KeyValueStore {
  SharedPreferencesStore(this._preferences);

  /// Loads the backing store. Called once during bootstrap.
  static Future<SharedPreferencesStore> open() async =>
      SharedPreferencesStore(await SharedPreferences.getInstance());

  final SharedPreferences _preferences;

  @override
  String? getString(String key) => _preferences.getString(key);

  @override
  Future<void> setString(String key, String value) =>
      _preferences.setString(key, value);

  @override
  bool? getBool(String key) => _preferences.getBool(key);

  @override
  Future<void> setBool(String key, {required bool value}) =>
      _preferences.setBool(key, value);

  @override
  int? getInt(String key) => _preferences.getInt(key);

  @override
  Future<void> setInt(String key, int value) => _preferences.setInt(key, value);

  @override
  Map<String, dynamic>? getJson(String key) {
    final raw = _preferences.getString(key);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      // A value we cannot parse is treated as absent rather than fatal: a
      // corrupted preference should never block app start.
      return null;
    }
  }

  @override
  Future<void> setJson(String key, Map<String, dynamic> value) =>
      _preferences.setString(key, jsonEncode(value));

  @override
  Future<void> remove(String key) => _preferences.remove(key);
}

/// Map-backed store for tests.
@visibleForTesting
class InMemoryKeyValueStore implements KeyValueStore {
  InMemoryKeyValueStore([Map<String, Object>? initial])
    : values = {...?initial};

  final Map<String, Object> values;

  @override
  String? getString(String key) => values[key] as String?;

  @override
  Future<void> setString(String key, String value) async => values[key] = value;

  @override
  bool? getBool(String key) => values[key] as bool?;

  @override
  Future<void> setBool(String key, {required bool value}) async =>
      values[key] = value;

  @override
  int? getInt(String key) => values[key] as int?;

  @override
  Future<void> setInt(String key, int value) async => values[key] = value;

  @override
  Map<String, dynamic>? getJson(String key) {
    final raw = values[key] as String?;
    if (raw == null) return null;
    final decoded = jsonDecode(raw);
    return decoded is Map<String, dynamic> ? decoded : null;
  }

  @override
  Future<void> setJson(String key, Map<String, dynamic> value) async =>
      values[key] = jsonEncode(value);

  @override
  Future<void> remove(String key) async => values.remove(key);
}

/// Preference keys owned by the app.
abstract final class PreferenceKeys {
  static const String themeMode = 'settings.themeMode';
  static const String selectedModelId = 'settings.selectedModelId';
  static const String preferredEngine = 'settings.preferredEngine';
  static const String onDeviceWhenOffline = 'settings.onDeviceWhenOffline';
  static const String smartRouting = 'settings.smartRouting';
  static const String hapticsEnabled = 'settings.haptics';
  static const String sendOnEnter = 'settings.sendOnEnter';
  static const String hasSeenOnboarding = 'app.hasSeenOnboarding';
}
