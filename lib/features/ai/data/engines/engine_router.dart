import 'package:evdekimi_ai/core/connectivity/connectivity_service.dart';
import 'package:evdekimi_ai/core/logging/app_logger.dart';
import 'package:evdekimi_ai/features/ai/domain/inference_engine.dart';
import 'package:evdekimi_ai/features/ai/domain/model_descriptor.dart';

/// Why a particular engine was chosen. Surfaced in the UI and the logs.
enum RoutingReason {
  /// The user explicitly picked this model.
  explicitChoice,

  /// Offline, and the on-device engine can serve the request.
  offlineFallback,

  /// Online, but the requested on-device model was unavailable.
  onDeviceUnavailable,

  /// No engine can run right now; the message must be queued.
  queued;

  String get explanation => switch (this) {
    RoutingReason.explicitChoice => 'Using the model you selected.',
    RoutingReason.offlineFallback => "You're offline, so this ran on-device.",
    RoutingReason.onDeviceUnavailable =>
      'The on-device model is unavailable, so this used the cloud model.',
    RoutingReason.queued =>
      'No model can run right now. Your message is queued and will send '
          'automatically.',
  };
}

/// The routing decision.
class RoutingDecision {
  const RoutingDecision({
    required this.reason,
    required this.modelId,
    this.engine,
  });

  /// `null` when nothing can run and the message must be queued.
  final InferenceEngine? engine;

  final String modelId;
  final RoutingReason reason;

  bool get canGenerateNow => engine != null;
}

/// Chooses which engine serves a request.
///
/// All engine selection lives here rather than being spread across the chat
/// repository, so the policy is one readable function and is unit-testable
/// without a database or a network.
///
/// The policy, in order:
///
/// 1. Honour the user's model choice when that engine is actually available.
/// 2. If a cloud model was chosen but there is no network, fall back to
///    on-device — but only when the on-device engine can serve it. It answers a
///    narrow set of intents, and silently downgrading a code question to a
///    canned refusal would be worse than queueing.
/// 3. If an on-device model was chosen but the runtime is broken, use the cloud.
/// 4. Otherwise queue, and let the outbox deliver it later.
///
/// Note what this deliberately does *not* do: it never routes on prompt content
/// to save money. Answer quality changing based on a hidden classifier is
/// exactly the behaviour users find untrustworthy, so cross-engine routing only
/// ever happens when the preferred engine genuinely cannot run.
class EngineRouter {
  EngineRouter({
    required InferenceEngine remoteEngine,
    required InferenceEngine onDeviceEngine,
    required ConnectivityService connectivity,
    required AppLogger logger,
    required String Function() fallbackRemoteModelId,
  }) : _remote = remoteEngine,
       _onDevice = onDeviceEngine,
       _connectivity = connectivity,
       _fallbackRemoteModelId = fallbackRemoteModelId,
       _logger = logger.scoped('ai.router');

  /// Which cloud model to use when an on-device request has to be redirected.
  ///
  /// A callback rather than a value: the user can change their default model at
  /// any time, and rebuilding the router to observe that would tear down live
  /// generations.
  final String Function() _fallbackRemoteModelId;

  final InferenceEngine _remote;
  final InferenceEngine _onDevice;
  final ConnectivityService _connectivity;
  final AppLogger _logger;

  InferenceEngine engineFor(EngineKind kind) =>
      kind.isOnDevice ? _onDevice : _remote;

  /// Resolves which engine should serve [model] right now.
  Future<RoutingDecision> resolve({
    required ModelDescriptor model,
    bool allowOnDeviceFallback = true,
  }) async {
    final preferred = engineFor(model.engine);

    if (await preferred.isAvailable()) {
      return RoutingDecision(
        engine: preferred,
        modelId: model.id,
        reason: RoutingReason.explicitChoice,
      );
    }

    if (model.engine == EngineKind.remote) {
      final isOffline = _connectivity.status.isOffline;
      if (allowOnDeviceFallback && await _onDevice.isAvailable()) {
        _logger.i(
          'Falling back to on-device',
          fields: {'requested': model.id, 'offline': isOffline},
        );
        return RoutingDecision(
          engine: _onDevice,
          modelId: KnownModels.onDeviceRouter,
          reason: RoutingReason.offlineFallback,
        );
      }
      return RoutingDecision(modelId: model.id, reason: RoutingReason.queued);
    }

    // An on-device model was requested but the runtime is not usable.
    if (await _remote.isAvailable()) {
      // The model id must change with the engine. Sending the on-device id to
      // the cloud names a model the backend has never heard of, and the request
      // is rejected as `invalid_model`.
      final fallbackId = _fallbackRemoteModelId();
      _logger.w(
        'On-device unavailable; using cloud',
        fields: {'requested': model.id, 'using': fallbackId},
      );
      return RoutingDecision(
        engine: _remote,
        modelId: fallbackId,
        reason: RoutingReason.onDeviceUnavailable,
      );
    }

    return RoutingDecision(modelId: model.id, reason: RoutingReason.queued);
  }

  Future<void> dispose() async {
    await _remote.dispose();
    await _onDevice.dispose();
  }
}
