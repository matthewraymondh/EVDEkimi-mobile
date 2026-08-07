import 'package:equatable/equatable.dart';

/// The authenticated user.
class User extends Equatable {
  const User({
    required this.id,
    required this.email,
    this.displayName,
    this.avatarUrl,
  });

  factory User.fromJson(Map<String, dynamic> json) => User(
    id: json['id'].toString(),
    email: (json['email'] as String?) ?? '',
    displayName: json['name'] as String? ?? json['display_name'] as String?,
    avatarUrl: json['avatar_url'] as String?,
  );

  final String id;
  final String email;
  final String? displayName;
  final String? avatarUrl;

  /// Name for greetings, falling back to the local part of the email.
  String get friendlyName {
    final name = displayName?.trim();
    if (name != null && name.isNotEmpty) return name;
    final localPart = email.split('@').first;
    return localPart.isEmpty ? 'there' : localPart;
  }

  /// Up-to-two-character monogram for the avatar.
  String get initials {
    final source = (displayName?.trim().isNotEmpty ?? false)
        ? displayName!.trim()
        : email;
    final parts = source
        .split(RegExp(r'[\s._-]+'))
        .where((part) => part.isNotEmpty)
        .toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) {
      return parts.first.substring(0, 1).toUpperCase();
    }
    return (parts[0].substring(0, 1) + parts[1].substring(0, 1)).toUpperCase();
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'email': email,
    if (displayName != null) 'name': displayName,
    if (avatarUrl != null) 'avatar_url': avatarUrl,
  };

  @override
  List<Object?> get props => [id, email, displayName, avatarUrl];
}

/// A live session: the user plus the tokens that authenticate them.
///
/// Tokens are part of the domain entity but never leave the auth feature except
/// through `AuthTokenDelegate`, which hands the HTTP layer a bare string. Nothing
/// else in the app can reach a refresh token.
class AuthSession extends Equatable {
  const AuthSession({
    required this.user,
    required this.accessToken,
    required this.refreshToken,
    this.accessTokenExpiresAt,
  });

  final User user;
  final String accessToken;
  final String refreshToken;

  /// Absolute expiry, when the server tells us. Used for proactive refresh.
  final DateTime? accessTokenExpiresAt;

  /// Refresh slightly before the true expiry so an in-flight request does not
  /// race the boundary and take a 401 that the user can perceive.
  static const Duration refreshSkew = Duration(seconds: 60);

  /// Whether the access token is expired (or close enough to count).
  bool get isAccessTokenExpired {
    final expiry = accessTokenExpiresAt;
    if (expiry == null) return false;
    return DateTime.now().toUtc().isAfter(expiry.subtract(refreshSkew));
  }

  AuthSession copyWith({
    User? user,
    String? accessToken,
    String? refreshToken,
    DateTime? accessTokenExpiresAt,
  }) => AuthSession(
    user: user ?? this.user,
    accessToken: accessToken ?? this.accessToken,
    refreshToken: refreshToken ?? this.refreshToken,
    accessTokenExpiresAt: accessTokenExpiresAt ?? this.accessTokenExpiresAt,
  );

  // Tokens are excluded from `props` on purpose: two sessions for the same user
  // are equal for UI purposes, and it keeps credentials out of any diagnostic
  // that prints an entity.
  @override
  List<Object?> get props => [user, accessTokenExpiresAt];

  @override
  String toString() => 'AuthSession(user: ${user.email}, tokens: <redacted>)';
}

/// Sign-in / sign-up input, validated before any network call.
class AuthCredentials extends Equatable {
  const AuthCredentials({
    required this.email,
    required this.password,
    this.displayName,
  });

  final String email;
  final String password;
  final String? displayName;

  static final RegExp _emailPattern = RegExp(
    r'^[\w.!#$%&*+/=?^`{|}~-]+@[\w-]+(\.[\w-]+)+$',
  );

  static const int minPasswordLength = 8;

  /// Field-level errors, empty when the input is valid.
  ///
  /// Validation lives in the domain so both the form and the use case agree on
  /// the rules, and so it is unit-testable without a widget.
  Map<String, String> validate({bool requireDisplayName = false}) {
    final errors = <String, String>{};

    final trimmedEmail = email.trim();
    if (trimmedEmail.isEmpty) {
      errors['email'] = 'Enter your email address.';
    } else if (!_emailPattern.hasMatch(trimmedEmail)) {
      errors['email'] = 'That does not look like a valid email address.';
    }

    if (password.isEmpty) {
      errors['password'] = 'Enter your password.';
    } else if (password.length < minPasswordLength) {
      errors['password'] = 'Use at least $minPasswordLength characters.';
    }

    if (requireDisplayName && (displayName?.trim().isEmpty ?? true)) {
      errors['name'] = 'Enter your name.';
    }

    return errors;
  }

  bool get isValidForSignIn => validate().isEmpty;

  Map<String, dynamic> toJson() => {
    'email': email.trim().toLowerCase(),
    'password': password,
    if (displayName != null) 'name': displayName!.trim(),
  };

  @override
  List<Object?> get props => [email, password, displayName];

  @override
  String toString() => 'AuthCredentials(email: $email, password: <redacted>)';
}
