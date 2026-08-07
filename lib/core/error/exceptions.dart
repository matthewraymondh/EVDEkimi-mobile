/// Exceptions thrown *inside* the data layer.
///
/// These exist so data sources can fail loudly and precisely without knowing
/// anything about `Failure` or the UI. `ErrorMapper` is the only translator.
library;

/// Base class for every exception this app raises deliberately.
sealed class AppException implements Exception {
  const AppException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => '$runtimeType: $message';
}

/// A non-success HTTP status with whatever structured detail we could parse.
final class ApiException extends AppException {
  const ApiException({
    required String message,
    required this.statusCode,
    this.errorCode,
    this.fieldErrors = const {},
    super.cause,
  }) : super(message);

  final int statusCode;

  /// Backend-supplied stable error identifier, e.g. `invalid_credentials`.
  final String? errorCode;

  /// Per-field validation detail for 422-style responses.
  final Map<String, String> fieldErrors;

  @override
  String toString() =>
      'ApiException($statusCode${errorCode == null ? '' : ' $errorCode'}): $message';
}

/// The server sent bytes we could not interpret as a valid SSE stream.
final class SseFormatException extends AppException {
  const SseFormatException(super.message, {super.cause});
}

/// Refreshing an expired access token failed; the session is unrecoverable.
final class SessionExpiredException extends AppException {
  const SessionExpiredException([
    super.message = 'The refresh token was rejected',
  ]);
}

/// No credentials are stored, so an authenticated call cannot be attempted.
final class MissingSessionException extends AppException {
  const MissingSessionException([
    super.message = 'No authenticated session is available',
  ]);
}

/// Local persistence (sqflite / secure storage / preferences) failed.
final class LocalStoreException extends AppException {
  const LocalStoreException(super.message, {super.cause});
}

/// An on-device model was requested but its weights are not on disk.
final class ModelNotInstalledException extends AppException {
  const ModelNotInstalledException(this.modelId)
    : super('On-device model "$modelId" is not installed');

  final String modelId;
}

/// The selected inference engine cannot run on this device/platform.
final class EngineUnavailableException extends AppException {
  const EngineUnavailableException(super.message, {super.cause});
}

/// Generation was stopped by the user or by a superseding request.
final class InferenceCancelledException extends AppException {
  const InferenceCancelledException([super.message = 'Generation cancelled']);
}

/// The ONNX runtime (or the graph itself) failed during execution.
final class InferenceRuntimeException extends AppException {
  const InferenceRuntimeException(super.message, {super.cause});
}

/// A platform permission was refused.
final class PermissionDeniedException extends AppException {
  const PermissionDeniedException(
    this.permission, {
    this.isPermanentlyDenied = false,
  }) : super('Permission denied: $permission');

  final String permission;
  final bool isPermanentlyDenied;
}
