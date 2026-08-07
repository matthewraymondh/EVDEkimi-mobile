import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:evdekimi_ai/core/network/interceptors/auth_interceptor.dart';
import 'package:evdekimi_ai/core/network/interceptors/retry_interceptor.dart';
import 'package:evdekimi_ai/core/network/sse/sse_client.dart';
import 'package:evdekimi_ai/core/network/sse/sse_event.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

/// The single seam between data sources and HTTP.
///
/// Data sources depend on this class rather than on Dio directly, which keeps
/// package-specific types (`Options`, `DioException`, `ResponseBody`) out of the
/// feature code and makes the transport swappable. Errors are deliberately left
/// as thrown `DioException`s: repositories wrap calls in `Result.guardAsync`,
/// and `ErrorMapper` performs the single translation into a `Failure`.
class ApiClient {
  ApiClient({required Dio dio, required SseClient sseClient})
    : _dio = dio,
      _sseClient = sseClient;

  final Dio _dio;
  final SseClient _sseClient;

  /// Exposed for tests that need to install a mock adapter.
  @visibleForTesting
  Dio get raw => _dio;

  Future<Map<String, dynamic>> getJson(
    String path, {
    Map<String, dynamic>? queryParameters,
    CancelToken? cancelToken,
    bool authenticated = true,
  }) async {
    final response = await _dio.get<dynamic>(
      path,
      queryParameters: queryParameters,
      cancelToken: cancelToken,
      options: _options(authenticated: authenticated),
    );
    return _asJsonObject(response.data);
  }

  Future<List<dynamic>> getJsonList(
    String path, {
    Map<String, dynamic>? queryParameters,
    CancelToken? cancelToken,
    bool authenticated = true,
  }) async {
    final response = await _dio.get<dynamic>(
      path,
      queryParameters: queryParameters,
      cancelToken: cancelToken,
      options: _options(authenticated: authenticated),
    );
    final data = response.data;
    if (data is List) return data;
    // Tolerate the common `{"data": [...]}` envelope.
    if (data is Map && data['data'] is List) return data['data'] as List;
    throw DioException(
      requestOptions: response.requestOptions,
      response: response,
      error: 'Expected a JSON array at $path but received ${data.runtimeType}',
    );
  }

  Future<Map<String, dynamic>> postJson(
    String path, {
    Object? body,
    Map<String, dynamic>? queryParameters,
    CancelToken? cancelToken,
    bool authenticated = true,

    /// Only set this when the request carries an idempotency key.
    bool retryable = false,
  }) async {
    final response = await _dio.post<dynamic>(
      path,
      data: body,
      queryParameters: queryParameters,
      cancelToken: cancelToken,
      options: _options(authenticated: authenticated, retryable: retryable),
    );
    return _asJsonObject(response.data);
  }

  Future<Map<String, dynamic>> patchJson(
    String path, {
    Object? body,
    CancelToken? cancelToken,
    bool authenticated = true,
  }) async {
    final response = await _dio.patch<dynamic>(
      path,
      data: body,
      cancelToken: cancelToken,
      options: _options(authenticated: authenticated),
    );
    return _asJsonObject(response.data);
  }

  Future<void> delete(
    String path, {
    CancelToken? cancelToken,
    bool authenticated = true,
  }) async {
    await _dio.delete<dynamic>(
      path,
      cancelToken: cancelToken,
      options: _options(authenticated: authenticated),
    );
  }

  /// Uploads binary content as multipart form data.
  Future<Map<String, dynamic>> uploadBytes(
    String path, {
    required Uint8List bytes,
    required String filename,
    required String field,
    String? contentType,
    Map<String, String> fields = const {},
    CancelToken? cancelToken,
    void Function(int sent, int total)? onProgress,
  }) async {
    final formData = FormData.fromMap({
      ...fields,
      field: MultipartFile.fromBytes(
        bytes,
        filename: filename,
        contentType: contentType == null
            ? null
            : DioMediaType.parse(contentType),
      ),
    });

    final response = await _dio.post<dynamic>(
      path,
      data: formData,
      cancelToken: cancelToken,
      onSendProgress: onProgress,
      options: Options(contentType: 'multipart/form-data'),
    );
    return _asJsonObject(response.data);
  }

  /// Opens a server-sent-events stream.
  Stream<SseEvent> stream({
    required String path,
    Object? body,
    String method = 'POST',
    Map<String, dynamic>? queryParameters,
    CancelToken? cancelToken,
  }) => _sseClient.stream(
    path: path,
    body: body,
    method: method,
    queryParameters: queryParameters,
    cancelToken: cancelToken,
  );

  static Options _options({
    required bool authenticated,
    bool retryable = false,
  }) => Options(
    extra: {
      if (!authenticated) AuthInterceptor.skipAuthFlag: true,
      if (retryable) RetryInterceptor.retryableFlag: true,
    },
  );

  /// Normalises a decoded body into a JSON object.
  ///
  /// An empty 204 body is a legitimate success, so it maps to `{}` rather than
  /// forcing every caller to null-check.
  static Map<String, dynamic> _asJsonObject(Object? data) {
    if (data == null) return const {};
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return data.cast<String, dynamic>();
    if (data is String && data.trim().isEmpty) return const {};
    throw FormatException(
      'Expected a JSON object but received ${data.runtimeType}',
    );
  }
}
