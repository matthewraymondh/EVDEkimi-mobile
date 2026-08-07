import 'package:evdekimi_ai/core/error/exceptions.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Storage for credentials, backed by the platform keystore.
///
/// Tokens live here and never in `SharedPreferences`, which is readable on a
/// rooted device and included in some backup flows.
///
/// Platform behaviour, and the one deliberate deviation from defaults:
///
/// * **Android** — `flutter_secure_storage` 11 already defaults to AES-GCM data
///   encryption with an RSA-OAEP key wrapped by the hardware keystore, so no
///   override is needed. `resetOnError` (also on by default) drops an entry that
///   can no longer be decrypted, which is what keeps a keystore invalidated by
///   an OS upgrade from throwing on every launch.
/// * **iOS** — accessibility is pinned to `first_unlock_this_device` rather than
///   the default. `first_unlock` lets a background outbox flush read the token
///   after a reboot without the user opening the app, and `_this_device` stops
///   the credential from being restored onto a different device from a backup.
abstract interface class SecureStore {
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);

  /// Clears every key this app owns. Used on sign-out.
  Future<void> clear();
}

class FlutterSecureStore implements SecureStore {
  FlutterSecureStore({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.first_unlock_this_device,
            ),
          );

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) async {
    try {
      return await _storage.read(key: key);
    } catch (error) {
      // Wrapped, not swallowed. Deciding that an unreadable token means "signed
      // out" is a policy call, and it belongs to the auth repository — which
      // catches this and falls through to the unauthenticated path — not to the
      // storage primitive.
      throw LocalStoreException(
        'Failed to read secure key "$key"',
        cause: error,
      );
    }
  }

  @override
  Future<void> write(String key, String value) async {
    try {
      await _storage.write(key: key, value: value);
    } catch (error) {
      throw LocalStoreException(
        'Failed to write secure key "$key"',
        cause: error,
      );
    }
  }

  @override
  Future<void> delete(String key) async {
    try {
      await _storage.delete(key: key);
    } catch (error) {
      throw LocalStoreException(
        'Failed to delete secure key "$key"',
        cause: error,
      );
    }
  }

  @override
  Future<void> clear() async {
    try {
      await _storage.deleteAll();
    } catch (error) {
      throw LocalStoreException('Failed to clear secure storage', cause: error);
    }
  }
}

/// In-memory secure store for tests and for widget previews.
@visibleForTesting
class InMemorySecureStore implements SecureStore {
  final Map<String, String> values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<void> clear() async => values.clear();
}

/// Keys owned by this app, centralised so nothing collides.
abstract final class SecureKeys {
  static const String accessToken = 'auth.accessToken';
  static const String refreshToken = 'auth.refreshToken';
  static const String accessTokenExpiry = 'auth.accessTokenExpiresAt';
  static const String userProfile = 'auth.userProfile';
}
