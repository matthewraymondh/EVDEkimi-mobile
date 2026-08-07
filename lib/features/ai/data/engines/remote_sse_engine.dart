import 'dart:async';
import 'dart:convert';

import 'package:evdekimi_ai/core/config/app_config.dart';
import 'package:evdekimi_ai/core/connectivity/connectivity_service.dart';
import 'package:evdekimi_ai/core/error/exceptions.dart';
import 'package:evdekimi_ai/core/logging/app_logger.dart';
import 'package:evdekimi_ai/core/network/api_client.dart';
import 'package:evdekimi_ai/features/ai/domain/inference_engine.dart';
import 'package:evdekimi_ai/features/ai/domain/model_descriptor.dart';

/// Hosted inference over server-sent events.
///
/// Speaks the OpenAI streaming shape, because that is what almost every hosted
/// provider and every mock server emits:
///
/// ```
/// data: {"choices":[{"delta":{"content":"Hel"}}]}
/// data: {"choices":[{"delta":{"content":"lo"}}]}
/// data: [DONE]
/// ```
///
/// Chunk parsing is tolerant by design. A malformed chunk mid-stream is skipped
/// with a warning rather than failing the whole response: the user has already
/// seen partial text, and discarding it because chunk 40 of 200 was truncated
/// would be strictly worse than continuing.
class RemoteSseEngine implements InferenceEngine {
  RemoteSseEngine({
    required ApiClient apiClient,
    required AppLogger logger,
    required ConnectivityService connectivity,
  }) : _apiClient = apiClient,
       _logger = logger.scoped('ai.remote'),
       _connectivity = connectivity;

  final ApiClient _apiClient;
  final AppLogger _logger;
  final ConnectivityService _connectivity;

  @override
  EngineKind get kind => EngineKind.remote;

  @override
  EngineCapabilities get capabilities => const EngineCapabilities(
    supportsStreaming: true,
    supportsVision: true,
    requiresNetwork: true,
    maxContextTokens: 32768,
  );

  @override
  Future<bool> isAvailable() async => _connectivity.status.isOnline;

  @override
  Stream<InferenceEvent> generate(InferenceRequest request) async* {
    final stopwatch = Stopwatch()..start();

    yield InferenceStarted(modelId: request.modelId, engine: kind);

    final events = _apiClient.stream(
      path: ApiRoutes.chatCompletions,
      body: _buildBody(request),
    );

    var tokenCount = 0;
    var finishReason = FinishReason.stop;
    var sawContent = false;

    await for (final event in events) {
      if (event.isDone) break;

      final payload = _decode(event.data);
      if (payload == null) continue;

      // An error can arrive *inside* a 200 stream once generation has started;
      // the status code told us nothing about it.
      final error = payload['error'];
      if (error != null) {
        throw InferenceRuntimeException(
          error is Map ? (error['message']?.toString() ?? '$error') : '$error',
        );
      }

      final delta = _extractDelta(payload);
      if (delta != null && delta.isNotEmpty) {
        sawContent = true;
        tokenCount++;
        yield InferenceDelta(delta);
      }

      final reason = _extractFinishReason(payload);
      if (reason != null) {
        finishReason = reason;
        if (reason != FinishReason.stop) break;
      }
    }

    stopwatch.stop();

    // A stream that closed without a single content chunk is a failure the user
    // would otherwise see as an empty bubble.
    if (!sawContent && finishReason == FinishReason.stop) {
      throw const SseFormatException(
        'The model stream ended without producing any content',
      );
    }

    _logger.i(
      'Remote generation finished',
      fields: {
        'model': request.modelId,
        'chunks': tokenCount,
        'ms': stopwatch.elapsedMilliseconds,
        'finish': finishReason.name,
      },
    );

    yield InferenceCompleted(
      finishReason: finishReason,
      outputTokens: tokenCount,
      latency: stopwatch.elapsed,
    );
  }

  Map<String, dynamic> _buildBody(InferenceRequest request) => {
    'model': request.modelId,
    'stream': true,
    'temperature': request.temperature,
    'max_tokens': request.maxOutputTokens,
    'messages': request.resolvedTurns
        .map(
          (turn) => request.imageUrls.isEmpty || turn.role != PromptRole.user
              ? turn.toJson()
              : _multimodalTurn(turn, request.imageUrls),
        )
        .toList(growable: false),
  };

  /// OpenAI-style multimodal content: a list of typed parts instead of a string.
  Map<String, dynamic> _multimodalTurn(
    PromptTurn turn,
    List<String> imageUrls,
  ) => {
    'role': turn.role.name,
    'content': [
      {'type': 'text', 'text': turn.content},
      for (final url in imageUrls)
        {
          'type': 'image_url',
          'image_url': {'url': url},
        },
    ],
  };

  Map<String, dynamic>? _decode(String data) {
    if (data.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(data);
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException catch (error) {
      _logger.w('Skipping malformed chunk', fields: {'error': '$error'});
      return null;
    }
  }

  /// Pulls the text out of whichever streaming shape the server used.
  static String? _extractDelta(Map<String, dynamic> payload) {
    final choices = payload['choices'];
    if (choices is List && choices.isNotEmpty) {
      final first = choices.first;
      if (first is Map) {
        // Streaming shape.
        final delta = first['delta'];
        if (delta is Map) {
          final content = delta['content'];
          if (content is String) return content;
          // Some providers send content as typed parts even when streaming.
          if (content is List) {
            return content
                .whereType<Map<Object?, Object?>>()
                .map((part) => part['text'])
                .whereType<String>()
                .join();
          }
        }
        // Non-streaming shape, in case `stream:false` was honoured.
        final message = first['message'];
        if (message is Map && message['content'] is String) {
          return message['content'] as String;
        }
        if (first['text'] is String) return first['text'] as String;
      }
    }

    // Minimal shapes used by simple mocks.
    if (payload['delta'] is String) return payload['delta'] as String;
    if (payload['content'] is String) return payload['content'] as String;
    if (payload['text'] is String) return payload['text'] as String;
    return null;
  }

  static FinishReason? _extractFinishReason(Map<String, dynamic> payload) {
    final choices = payload['choices'];
    Object? raw;
    if (choices is List && choices.isNotEmpty && choices.first is Map) {
      raw = (choices.first as Map)['finish_reason'];
    }
    raw ??= payload['finish_reason'];
    if (raw is! String || raw.isEmpty) return null;

    return switch (raw) {
      'stop' || 'end_turn' => FinishReason.stop,
      'length' || 'max_tokens' => FinishReason.length,
      'content_filter' => FinishReason.contentFilter,
      _ => FinishReason.stop,
    };
  }

  @override
  Future<void> dispose() async {}
}
