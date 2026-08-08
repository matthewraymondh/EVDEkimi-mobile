import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:evdekimi_ai/core/logging/app_logger.dart';
import 'package:evdekimi_ai/core/network/api_client.dart';
import 'package:evdekimi_ai/core/network/auth_token_delegate.dart';
import 'package:evdekimi_ai/core/network/sse/sse_client.dart';
import 'package:evdekimi_ai/core/persistence/secure_store.dart';
import 'package:evdekimi_ai/features/auth/data/auth_remote_data_source.dart';
import 'package:evdekimi_ai/features/auth/data/auth_repository_impl.dart';
import 'package:flutter_test/flutter_test.dart';

/// `AuthTokenDelegate.refreshSession` must collapse concurrent callers.
///
/// The interface documents this as a hard requirement rather than an
/// optimisation, because the backend rotates refresh tokens: a second
/// simultaneous refresh presents one the first has already spent, fails, and
/// signs the user out of a perfectly good session. Two independent transports
/// can now trigger it — the interceptor and the SSE client — and neither can see
/// the other, so the guarantee has to live in the implementation.
void main() {
  late _RefreshCountingAdapter adapter;
  late AuthRepositoryImpl repository;

  setUp(() async {
    adapter = _RefreshCountingAdapter();
    final dio = Dio(BaseOptions(baseUrl: 'https://example.test'))
      ..httpClientAdapter = adapter;
    final logger = AppLogger.silent();

    final store = InMemorySecureStore()
      ..values[SecureKeys.accessToken] = 'stale-access'
      ..values[SecureKeys.refreshToken] = 'refresh-1'
      ..values[SecureKeys.userProfile] = jsonEncode({
        'id': 'u1',
        'email': 'agent@evdekimi.test',
      });

    repository = AuthRepositoryImpl(
      remote: AuthRemoteDataSource(
        ApiClient(
          dio: dio,
          sseClient: SseClient(
            dio: dio,
            logger: logger,
            authDelegate: const NoopAuthTokenDelegate(),
          ),
        ),
      ),
      secureStore: store,
      logger: logger,
    );

    // Loads the stored refresh token; the access token is not yet expired, so
    // this does not itself trigger a refresh.
    await repository.restoreSession();
    expect(adapter.refreshCalls, isZero);
  });

  tearDown(() => repository.dispose());

  test('four simultaneous refreshes make one network call', () async {
    final results = await Future.wait([
      repository.refreshSession(),
      repository.refreshSession(),
      repository.refreshSession(),
      repository.refreshSession(),
    ]);

    expect(adapter.refreshCalls, equals(1));
    expect(results, everyElement(isTrue));
    expect(repository.currentSession?.accessToken, equals('fresh-access-1'));
  });

  test('a later refresh starts a new attempt', () async {
    // The in-flight future must be cleared on completion, or the second token
    // expiry an hour later would silently reuse the first result forever.
    await repository.refreshSession();
    await repository.refreshSession();

    expect(adapter.refreshCalls, equals(2));
    expect(repository.currentSession?.accessToken, equals('fresh-access-2'));
  });

  test('rotated refresh tokens are the reason this matters', () async {
    // Each response hands back a new refresh token and the adapter rejects any
    // request presenting a spent one — the real backend's behaviour. Without
    // single-flight the second concurrent call would 401 here.
    await Future.wait([
      repository.refreshSession(),
      repository.refreshSession(),
    ]);

    expect(adapter.rejectedSpentTokens, isZero);
    expect(repository.currentSession?.refreshToken, equals('refresh-2'));
  });

  test('a failed refresh does not wedge every later attempt', () async {
    adapter.failNext = true;
    expect(await repository.refreshSession(), isFalse);

    expect(await repository.refreshSession(), isTrue);
    expect(adapter.refreshCalls, equals(2));
  });
}

/// Serves `/auth/refresh`, rotating the token and counting real calls.
class _RefreshCountingAdapter implements HttpClientAdapter {
  int refreshCalls = 0;
  int rejectedSpentTokens = 0;
  bool failNext = false;

  /// The only refresh token the server currently considers valid.
  String _liveToken = 'refresh-1';

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (!options.path.contains('refresh')) {
      return ResponseBody.fromString('{}', 200, headers: _jsonHeaders);
    }

    refreshCalls++;
    // A real round trip is not instantaneous, and the race only exists inside
    // that window — so the fake has to have one too.
    await Future<void>.delayed(const Duration(milliseconds: 20));

    if (failNext) {
      failNext = false;
      return ResponseBody.fromString(
        jsonEncode({
          'error': {'message': 'Refresh service unavailable'},
        }),
        503,
        headers: _jsonHeaders,
      );
    }

    // The body has to come off the stream: Dio's transformer has already encoded
    // it by the time an adapter is called, and `options.data` still holds the
    // un-encoded Map.
    final presented =
        (jsonDecode(await _readBody(requestStream)) as Map)['refresh_token'];
    if (presented != _liveToken) {
      rejectedSpentTokens++;
      return ResponseBody.fromString(
        jsonEncode({
          'error': {'message': 'Refresh token already used', 'code': 'rotated'},
        }),
        401,
        headers: _jsonHeaders,
      );
    }

    _liveToken = 'refresh-${refreshCalls + 1}';
    return ResponseBody.fromString(
      jsonEncode({
        'access_token': 'fresh-access-$refreshCalls',
        'refresh_token': _liveToken,
        'expires_in': 300,
        'user': {'id': 'u1', 'email': 'agent@evdekimi.test'},
      }),
      200,
      headers: _jsonHeaders,
    );
  }

  static Future<String> _readBody(Stream<Uint8List>? stream) async {
    if (stream == null) return '{}';
    final bytes = <int>[];
    await for (final chunk in stream) {
      bytes.addAll(chunk);
    }
    return utf8.decode(bytes);
  }

  static const Map<String, List<String>> _jsonHeaders = {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  };

  @override
  void close({bool force = false}) {}
}
