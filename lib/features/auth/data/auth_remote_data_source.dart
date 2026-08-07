import 'package:evdekimi_ai/core/config/app_config.dart';
import 'package:evdekimi_ai/core/error/exceptions.dart';
import 'package:evdekimi_ai/core/network/api_client.dart';
import 'package:evdekimi_ai/features/auth/domain/entities/auth_session.dart';

/// HTTP calls for authentication.
///
/// Every request here is marked `authenticated: false` so `AuthInterceptor`
/// leaves it alone. Without that, a failing refresh would trigger a refresh,
/// which would fail, which would trigger a refresh.
class AuthRemoteDataSource {
  AuthRemoteDataSource(this._apiClient);

  final ApiClient _apiClient;

  Future<AuthSession> signIn(AuthCredentials credentials) async {
    final response = await _apiClient.postJson(
      ApiRoutes.signIn,
      body: credentials.toJson(),
      authenticated: false,
    );
    return _parseSession(response);
  }

  Future<AuthSession> signUp(AuthCredentials credentials) async {
    final response = await _apiClient.postJson(
      ApiRoutes.signUp,
      body: credentials.toJson(),
      authenticated: false,
    );
    return _parseSession(response);
  }

  Future<AuthSession> refresh(String refreshToken) async {
    final response = await _apiClient.postJson(
      ApiRoutes.refresh,
      body: {'refresh_token': refreshToken},
      authenticated: false,
    );
    return _parseSession(response, fallbackRefreshToken: refreshToken);
  }

  /// Best-effort server-side invalidation. Local sign-out does not depend on it.
  Future<void> signOut() => _apiClient.postJson(ApiRoutes.signOut).then((_) {});

  Future<User> fetchProfile() async {
    final response = await _apiClient.getJson(ApiRoutes.me);
    final userJson = response['user'] ?? response;
    return User.fromJson(_asMap(userJson));
  }

  /// Parses a token response, tolerating the field-name variations that mock
  /// servers and real providers differ on.
  ///
  /// A refresh response often omits the refresh token (meaning "keep the one you
  /// have"), so [fallbackRefreshToken] preserves it instead of wiping the session.
  static AuthSession _parseSession(
    Map<String, dynamic> json, {
    String? fallbackRefreshToken,
  }) {
    final accessToken =
        (json['access_token'] ?? json['accessToken'] ?? json['token'])
            as String?;
    if (accessToken == null || accessToken.isEmpty) {
      throw const ApiException(
        message: 'The sign-in response did not contain an access token',
        statusCode: 502,
      );
    }

    final refreshToken =
        (json['refresh_token'] ?? json['refreshToken']) as String? ??
        fallbackRefreshToken;
    if (refreshToken == null || refreshToken.isEmpty) {
      throw const ApiException(
        message: 'The sign-in response did not contain a refresh token',
        statusCode: 502,
      );
    }

    final userJson = json['user'];
    final user = userJson == null
        ? const User(id: 'me', email: '')
        : User.fromJson(_asMap(userJson));

    return AuthSession(
      user: user,
      accessToken: accessToken,
      refreshToken: refreshToken,
      accessTokenExpiresAt: _parseExpiry(json),
    );
  }

  /// Accepts either an absolute timestamp or a relative `expires_in`.
  static DateTime? _parseExpiry(Map<String, dynamic> json) {
    final expiresIn = json['expires_in'] ?? json['expiresIn'];
    if (expiresIn is num) {
      return DateTime.now().toUtc().add(Duration(seconds: expiresIn.toInt()));
    }
    final expiresAt = json['expires_at'] ?? json['expiresAt'];
    if (expiresAt is String) return DateTime.tryParse(expiresAt)?.toUtc();
    if (expiresAt is num) {
      // Heuristic: values below ~1e12 are seconds, above are milliseconds.
      final value = expiresAt.toInt();
      return DateTime.fromMillisecondsSinceEpoch(
        value < 1000000000000 ? value * 1000 : value,
        isUtc: true,
      );
    }
    return null;
  }

  static Map<String, dynamic> _asMap(Object? value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return value.cast<String, dynamic>();
    return const {};
  }
}
