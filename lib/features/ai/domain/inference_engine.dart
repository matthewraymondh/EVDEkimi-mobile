import 'package:equatable/equatable.dart';
import 'package:evdekimi_ai/features/ai/domain/model_descriptor.dart';

/// One turn of prompt context handed to an engine.
///
/// Deliberately *not* the chat feature's `Message` entity. The AI layer must not
/// know about conversations, persistence status, or attachments-in-upload; it
/// takes text and roles. That separation is what allows the same engine to serve
/// chat, conversation auto-titling, and offline semantic search.
class PromptTurn extends Equatable {
  const PromptTurn({required this.role, required this.content});

  const PromptTurn.user(this.content) : role = PromptRole.user;

  const PromptTurn.assistant(this.content) : role = PromptRole.assistant;

  const PromptTurn.system(this.content) : role = PromptRole.system;

  final PromptRole role;
  final String content;

  Map<String, dynamic> toJson() => {'role': role.name, 'content': content};

  @override
  List<Object?> get props => [role, content];
}

enum PromptRole { system, user, assistant }

/// Everything an engine needs for a single generation.
class InferenceRequest extends Equatable {
  const InferenceRequest({
    required this.modelId,
    required this.turns,
    this.systemPrompt,
    this.temperature = 0.7,
    this.maxOutputTokens = 1024,
    this.imageUrls = const [],
    this.recognisedText = const [],
    this.conversationId,
  });

  final String modelId;

  /// Conversation context, oldest first. Excludes the system prompt.
  final List<PromptTurn> turns;

  final String? systemPrompt;
  final double temperature;
  final int maxOutputTokens;

  /// Remote URLs of images to attach, for vision-capable models.
  final List<String> imageUrls;

  /// Text read out of the latest user message's images, on the device.
  ///
  /// Carried as its own field rather than pre-mixed into [turns], because the
  /// two engines need it in opposite forms. A remote model only accepts message
  /// content, so the cloud engine folds this back into the last user turn on the
  /// way out. The on-device engine needs it kept apart: it is a classifier, and
  /// feeding it a page of receipt text concatenated onto "read this" classifies
  /// the receipt rather than the question — which is exactly what happened when
  /// this was folded in upstream, and why an image of a keyboard came back as a
  /// question about property law.
  ///
  /// Separating it also lets the local engine do something honest with an image
  /// offline: it cannot see the picture, but it has the words, so it can quote
  /// them back and search the user's history for them.
  final List<String> recognisedText;

  /// Passed through for logging/telemetry correlation only.
  final String? conversationId;

  /// The prompt including the system turn, in the order an engine should see it.
  List<PromptTurn> get resolvedTurns => [
    if (systemPrompt case final String prompt when prompt.isNotEmpty)
      PromptTurn.system(prompt),
    ...turns,
  ];

  @override
  List<Object?> get props => [
    modelId,
    turns,
    systemPrompt,
    temperature,
    maxOutputTokens,
    imageUrls,
    recognisedText,
  ];
}

/// Incremental output from an engine.
///
/// A sealed hierarchy rather than a bare `Stream<String>` so the consumer can
/// exhaustively handle lifecycle as well as content — which is what makes it
/// possible to record latency and the engine actually used, and to distinguish
/// "finished" from "stopped by the user" without out-of-band flags.
sealed class InferenceEvent {
  const InferenceEvent();
}

/// Emitted once, before any text, as soon as the engine commits to running.
final class InferenceStarted extends InferenceEvent {
  const InferenceStarted({required this.modelId, required this.engine});

  final String modelId;
  final EngineKind engine;
}

/// A chunk of generated text to append to the message being built.
final class InferenceDelta extends InferenceEvent {
  const InferenceDelta(this.text);

  final String text;
}

/// Engine-supplied progress note shown while nothing is streaming yet
/// (loading weights, searching local history). Never part of the answer.
final class InferenceStatus extends InferenceEvent {
  const InferenceStatus(this.message);

  final String message;
}

/// Terminal success event.
final class InferenceCompleted extends InferenceEvent {
  const InferenceCompleted({
    this.finishReason = FinishReason.stop,
    this.outputTokens,
    this.latency,
  });

  final FinishReason finishReason;
  final int? outputTokens;
  final Duration? latency;
}

enum FinishReason { stop, length, contentFilter, cancelled, error }

/// What an engine can do, so the UI can enable/disable affordances instead of
/// discovering limits by failing mid-request.
class EngineCapabilities extends Equatable {
  const EngineCapabilities({
    required this.supportsStreaming,
    required this.supportsVision,
    required this.requiresNetwork,
    this.maxContextTokens = 8192,
  });

  final bool supportsStreaming;
  final bool supportsVision;
  final bool requiresNetwork;
  final int maxContextTokens;

  @override
  List<Object?> get props => [
    supportsStreaming,
    supportsVision,
    requiresNetwork,
    maxContextTokens,
  ];
}

/// The port every inference backend implements.
///
/// This is the seam the whole "future on-device models" requirement rests on.
/// Chat code depends only on this interface, so adding llama.cpp or swapping the
/// hosted provider is a new implementation plus one line in the engine registry
/// — no change to repositories, controllers, or UI.
///
/// **Cancellation contract:** cancelling the returned stream's subscription must
/// abort the underlying work promptly (close the socket, stop the ONNX loop).
/// There is no separate token, because a `StreamSubscription` already expresses
/// exactly this lifetime and keeps the API honest about ownership.
abstract interface class InferenceEngine {
  EngineKind get kind;

  EngineCapabilities get capabilities;

  /// Whether this engine can run right now (weights present, network up).
  ///
  /// Cheap and side-effect free; the router calls it on every send.
  Future<bool> isAvailable();

  /// Streams a response for [request].
  ///
  /// Implementations emit exactly one [InferenceStarted], zero or more
  /// [InferenceDelta]/[InferenceStatus], and terminate with either
  /// [InferenceCompleted] or a stream error.
  Stream<InferenceEvent> generate(InferenceRequest request);

  /// Releases native resources (ONNX sessions, HTTP clients).
  Future<void> dispose();
}
