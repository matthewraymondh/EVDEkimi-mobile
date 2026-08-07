import 'package:equatable/equatable.dart';

/// The vocabulary of things that can go wrong, expressed for the *caller*.
///
/// A [Failure] is deliberately not an `Exception`: it is a value that travels
/// through `Result` and is pattern-matched by the UI. Data-layer exceptions
/// (Dio, sqflite, platform channels) are translated into these once, at the
/// repository boundary, by `ErrorMapper`.
sealed class Failure extends Equatable {
  const Failure({
    required this.message,
    this.code,
    this.cause,
    this.stackTrace,
    this.isRetryable = false,
  });

  /// Developer-facing detail. Logged, never rendered verbatim.
  final String message;

  /// Stable machine-readable identifier, when the backend supplies one.
  final String? code;

  /// The original error, kept for logging and crash reporting.
  final Object? cause;

  final StackTrace? stackTrace;

  /// Whether retrying the same operation could plausibly succeed.
  ///
  /// Drives whether the UI offers a "Try again" affordance, so it is part of
  /// the domain contract rather than a per-screen guess.
  final bool isRetryable;

  /// Short, human-readable text safe to show to a user.
  ///
  /// Kept on the failure itself so every surface renders the same wording. If
  /// the app later adopts ARB localisation this becomes a key lookup and no
  /// call site changes.
  String get userMessage;

  @override
  List<Object?> get props => [runtimeType, message, code, isRetryable];

  @override
  String toString() =>
      '$runtimeType(message: $message, code: $code, retryable: $isRetryable)';
}

/// No usable connectivity, DNS failure, timeout, or a dropped socket.
final class NetworkFailure extends Failure {
  const NetworkFailure({
    required super.message,
    this.kind = NetworkFailureKind.unreachable,
    super.code,
    super.cause,
    super.stackTrace,
  }) : super(isRetryable: true);

  final NetworkFailureKind kind;

  @override
  String get userMessage => switch (kind) {
    NetworkFailureKind.offline =>
      "You're offline. Your message is saved and will send automatically.",
    NetworkFailureKind.timeout =>
      'The server took too long to respond. Please try again.',
    NetworkFailureKind.unreachable =>
      "Couldn't reach the server. Check your connection and try again.",
    NetworkFailureKind.cancelled => 'Request cancelled.',
  };

  @override
  List<Object?> get props => [...super.props, kind];
}

enum NetworkFailureKind { offline, timeout, unreachable, cancelled }

/// The server answered, but with a non-success status.
final class ServerFailure extends Failure {
  const ServerFailure({
    required super.message,
    required this.statusCode,
    super.code,
    super.cause,
    super.stackTrace,
  }) : super(isRetryable: statusCode >= 500 || statusCode == 429);

  final int statusCode;

  /// Whether the caller should back off before retrying.
  bool get isRateLimited => statusCode == 429;

  @override
  String get userMessage {
    if (isRateLimited) {
      return 'Too many requests right now. Please wait a moment.';
    }
    if (statusCode >= 500) {
      return 'The AI service is having trouble. Please try again shortly.';
    }
    return 'The request was rejected by the server.';
  }

  @override
  List<Object?> get props => [...super.props, statusCode];
}

/// Authentication or authorisation problem.
final class AuthFailure extends Failure {
  const AuthFailure({
    required super.message,
    required this.reason,
    super.code,
    super.cause,
    super.stackTrace,
  });

  final AuthFailureReason reason;

  @override
  String get userMessage => switch (reason) {
    AuthFailureReason.invalidCredentials => 'Incorrect email or password.',
    AuthFailureReason.sessionExpired =>
      'Your session expired. Please sign in again.',
    AuthFailureReason.emailAlreadyInUse =>
      'An account with that email already exists.',
    AuthFailureReason.weakPassword =>
      'Please choose a password with at least 8 characters.',
    AuthFailureReason.noSession => 'Please sign in to continue.',
    AuthFailureReason.forbidden =>
      "You don't have access to this conversation.",
  };

  @override
  List<Object?> get props => [...super.props, reason];
}

enum AuthFailureReason {
  invalidCredentials,
  sessionExpired,
  emailAlreadyInUse,
  weakPassword,
  noSession,
  forbidden,
}

/// Client-side input that failed validation, optionally per field.
final class ValidationFailure extends Failure {
  const ValidationFailure({
    required super.message,
    this.fieldErrors = const {},
    super.code,
    super.cause,
    super.stackTrace,
  });

  /// Field name to message, so forms can attach errors to inputs.
  final Map<String, String> fieldErrors;

  @override
  String get userMessage =>
      fieldErrors.values.firstOrNull ?? 'Please check the highlighted fields.';

  @override
  List<Object?> get props => [...super.props, fieldErrors];
}

/// Local database or key-value store problem.
final class CacheFailure extends Failure {
  const CacheFailure({
    required super.message,
    super.code,
    super.cause,
    super.stackTrace,
    super.isRetryable = false,
  });

  @override
  String get userMessage => "Couldn't read locally saved data on this device.";
}

/// Something went wrong producing a model response.
final class InferenceFailure extends Failure {
  const InferenceFailure({
    required super.message,
    required this.reason,
    super.code,
    super.cause,
    super.stackTrace,
    super.isRetryable = true,
  });

  final InferenceFailureReason reason;

  @override
  String get userMessage => switch (reason) {
    InferenceFailureReason.cancelled => 'Generation stopped.',
    InferenceFailureReason.modelNotInstalled =>
      'That on-device model is not installed yet. Download it in Settings.',
    InferenceFailureReason.engineUnavailable =>
      'On-device inference is not available on this device.',
    InferenceFailureReason.contextTooLong =>
      'This conversation is too long for the selected model.',
    InferenceFailureReason.contentFiltered =>
      'The response was blocked by a content filter.',
    InferenceFailureReason.malformedStream =>
      'The response stream was interrupted. Please try again.',
    InferenceFailureReason.runtimeError =>
      "The model couldn't produce a response.",
  };

  @override
  List<Object?> get props => [...super.props, reason];
}

enum InferenceFailureReason {
  cancelled,
  modelNotInstalled,
  engineUnavailable,
  contextTooLong,
  contentFiltered,
  malformedStream,
  runtimeError,
}

/// An OS permission was denied (microphone, camera, photo library).
final class PermissionFailure extends Failure {
  const PermissionFailure({
    required super.message,
    required this.permission,
    this.isPermanentlyDenied = false,
    super.code,
    super.cause,
    super.stackTrace,
  });

  final String permission;

  /// When true the user must change it in system settings; prompting again is
  /// a no-op, so the UI should deep-link instead of re-asking.
  final bool isPermanentlyDenied;

  @override
  String get userMessage => isPermanentlyDenied
      ? 'Enable $permission access in system settings to use this feature.'
      : '$permission access is required for this feature.';

  @override
  List<Object?> get props => [...super.props, permission, isPermanentlyDenied];
}

/// Anything we failed to classify. Always logged with its cause.
final class UnknownFailure extends Failure {
  const UnknownFailure({
    required super.message,
    super.code,
    super.cause,
    super.stackTrace,
  });

  @override
  String get userMessage => 'Something went wrong. Please try again.';
}
