import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:evdekimi_ai/core/error/exceptions.dart';
import 'package:evdekimi_ai/core/error/failure.dart';

/// Translates every low-level error into a [Failure], in one place.
///
/// Centralising this keeps `catch` blocks in the data layer trivial and means
/// there is exactly one file to read (or change) to understand how the app
/// classifies errors.
abstract final class ErrorMapper {
  static Failure map(Object error, {StackTrace? stackTrace}) {
    return switch (error) {
      Failure() => error,
      ApiException() => _fromApi(error, stackTrace),
      DioException() => _fromDio(error, stackTrace),
      SessionExpiredException() => AuthFailure(
        message: error.message,
        reason: AuthFailureReason.sessionExpired,
        cause: error,
        stackTrace: stackTrace,
      ),
      MissingSessionException() => AuthFailure(
        message: error.message,
        reason: AuthFailureReason.noSession,
        cause: error,
        stackTrace: stackTrace,
      ),
      LocalStoreException() => CacheFailure(
        message: error.message,
        cause: error.cause ?? error,
        stackTrace: stackTrace,
      ),
      ModelNotInstalledException() => InferenceFailure(
        message: error.message,
        reason: InferenceFailureReason.modelNotInstalled,
        isRetryable: false,
        cause: error,
        stackTrace: stackTrace,
      ),
      EngineUnavailableException() => InferenceFailure(
        message: error.message,
        reason: InferenceFailureReason.engineUnavailable,
        isRetryable: false,
        cause: error,
        stackTrace: stackTrace,
      ),
      InferenceCancelledException() => InferenceFailure(
        message: error.message,
        reason: InferenceFailureReason.cancelled,
        isRetryable: false,
        cause: error,
        stackTrace: stackTrace,
      ),
      InferenceRuntimeException() => InferenceFailure(
        message: error.message,
        reason: InferenceFailureReason.runtimeError,
        cause: error.cause ?? error,
        stackTrace: stackTrace,
      ),
      SseFormatException() => InferenceFailure(
        message: error.message,
        reason: InferenceFailureReason.malformedStream,
        cause: error.cause ?? error,
        stackTrace: stackTrace,
      ),
      PermissionDeniedException() => PermissionFailure(
        message: error.message,
        permission: error.permission,
        isPermanentlyDenied: error.isPermanentlyDenied,
        cause: error,
        stackTrace: stackTrace,
      ),
      SocketException() => NetworkFailure(
        message: error.message,
        cause: error,
        stackTrace: stackTrace,
      ),
      TimeoutException() => NetworkFailure(
        message: error.message ?? 'Operation timed out',
        kind: NetworkFailureKind.timeout,
        cause: error,
        stackTrace: stackTrace,
      ),
      FormatException() => UnknownFailure(
        message: 'Malformed payload: ${error.message}',
        cause: error,
        stackTrace: stackTrace,
      ),
      _ => UnknownFailure(
        message: error.toString(),
        cause: error,
        stackTrace: stackTrace,
      ),
    };
  }

  static Failure _fromApi(ApiException error, StackTrace? stackTrace) {
    // 401/403 are auth problems regardless of what the body says; everything
    // else is classified by status class first, error code second.
    if (error.statusCode == 401) {
      return AuthFailure(
        message: error.message,
        reason: error.errorCode == 'invalid_credentials'
            ? AuthFailureReason.invalidCredentials
            : AuthFailureReason.sessionExpired,
        code: error.errorCode,
        cause: error,
        stackTrace: stackTrace,
      );
    }
    if (error.statusCode == 403) {
      return AuthFailure(
        message: error.message,
        reason: AuthFailureReason.forbidden,
        code: error.errorCode,
        cause: error,
        stackTrace: stackTrace,
      );
    }
    if (error.statusCode == 409 && error.errorCode == 'email_already_in_use') {
      return AuthFailure(
        message: error.message,
        reason: AuthFailureReason.emailAlreadyInUse,
        code: error.errorCode,
        cause: error,
        stackTrace: stackTrace,
      );
    }
    if (error.statusCode == 400 || error.statusCode == 422) {
      return ValidationFailure(
        message: error.message,
        fieldErrors: error.fieldErrors,
        code: error.errorCode,
        cause: error,
        stackTrace: stackTrace,
      );
    }
    return ServerFailure(
      message: error.message,
      statusCode: error.statusCode,
      code: error.errorCode,
      cause: error,
      stackTrace: stackTrace,
    );
  }

  static Failure _fromDio(DioException error, StackTrace? stackTrace) {
    final NetworkFailureKind? networkKind = switch (error.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout ||
      DioExceptionType.transformTimeout => NetworkFailureKind.timeout,
      DioExceptionType.connectionError => NetworkFailureKind.unreachable,
      DioExceptionType.cancel => NetworkFailureKind.cancelled,
      DioExceptionType.badCertificate => NetworkFailureKind.unreachable,
      DioExceptionType.badResponse || DioExceptionType.unknown => null,
    };

    if (networkKind != null) {
      return NetworkFailure(
        message: error.message ?? error.type.name,
        kind: networkKind,
        cause: error,
        stackTrace: stackTrace,
      );
    }

    final response = error.response;
    if (response != null) {
      return _fromApi(
        parseApiException(response.statusCode ?? 0, response.data),
        stackTrace,
      );
    }

    // `unknown` with a socket cause is still just "no network".
    if (error.error is SocketException) {
      return NetworkFailure(
        message: error.message ?? 'Connection failed',
        cause: error,
        stackTrace: stackTrace,
      );
    }

    return UnknownFailure(
      message: error.message ?? 'Unhandled network error',
      cause: error,
      stackTrace: stackTrace,
    );
  }

  /// Builds an [ApiException] from a response body, tolerating shape drift.
  ///
  /// Mock servers and real backends rarely agree on the error envelope, so we
  /// probe the handful of conventional shapes rather than assuming one.
  static ApiException parseApiException(int statusCode, Object? body) {
    var message = 'Request failed with status $statusCode';
    String? errorCode;
    final fieldErrors = <String, String>{};

    if (body is Map) {
      final map = body.cast<Object?, Object?>();
      final error = map['error'];

      // Shape: {"error": {"message": ..., "code": ...}}
      if (error is Map) {
        final errorMap = error.cast<Object?, Object?>();
        message = _asString(errorMap['message']) ?? message;
        errorCode = _asString(errorMap['code']) ?? _asString(errorMap['type']);
      } else {
        // Shapes: {"error": "..."} / {"message": ...} / {"detail": ...}
        message =
            _asString(error) ??
            _asString(map['message']) ??
            _asString(map['detail']) ??
            message;
        errorCode = _asString(map['code']) ?? _asString(map['error_code']);
      }

      // Shape: {"errors": {"email": ["taken"] | "taken"}}
      final errors = map['errors'];
      if (errors is Map) {
        for (final entry in errors.cast<Object?, Object?>().entries) {
          final key = _asString(entry.key);
          if (key == null) continue;
          final value = entry.value;
          final text = value is List
              ? value.map(_asString).nonNulls.join(', ')
              : _asString(value);
          if (text != null && text.isNotEmpty) fieldErrors[key] = text;
        }
      }
    } else if (body is String && body.trim().isNotEmpty) {
      message = body.trim();
    }

    return ApiException(
      message: message,
      statusCode: statusCode,
      errorCode: errorCode,
      fieldErrors: fieldErrors,
    );
  }

  static String? _asString(Object? value) {
    if (value is String) return value.isEmpty ? null : value;
    if (value is num || value is bool) return value.toString();
    return null;
  }
}
