import 'package:equatable/equatable.dart';

/// Where inference physically runs.
///
/// This is the axis the whole AI layer is organised around. Making it an
/// explicit domain concept — rather than an implementation detail of one
/// repository — is what allows a conversation, a message and a model to each
/// record which engine produced them, and lets the router switch engines
/// mid-session without any caller special-casing it.
enum EngineKind {
  /// A hosted model reached over HTTP with server-sent events.
  remote('Cloud'),

  /// A model executing locally through ONNX Runtime. No network involved.
  onDevice('On-device');

  const EngineKind(this.label);

  final String label;

  bool get isOnDevice => this == EngineKind.onDevice;

  static EngineKind fromName(String? name) => EngineKind.values.firstWhere(
    (kind) => kind.name == name,
    orElse: () => EngineKind.remote,
  );
}

/// A model the user can choose, whether hosted or local.
class ModelDescriptor extends Equatable {
  const ModelDescriptor({
    required this.id,
    required this.name,
    required this.provider,
    required this.engine,
    this.contextWindow = 8192,
    this.supportsStreaming = true,
    this.supportsVision = false,
    this.isDefault = false,
    this.description,
    this.sizeBytes,
    this.isInstalled = true,
  });

  factory ModelDescriptor.fromJson(Map<String, dynamic> json) {
    return ModelDescriptor(
      id: json['id'] as String,
      name: (json['name'] as String?) ?? json['id'] as String,
      provider: (json['provider'] as String?) ?? 'unknown',
      engine: EngineKind.fromName(json['engine'] as String?),
      contextWindow: (json['context_window'] as num?)?.toInt() ?? 8192,
      supportsStreaming: json['supports_streaming'] as bool? ?? true,
      supportsVision: json['supports_vision'] as bool? ?? false,
      isDefault: json['is_default'] as bool? ?? false,
      description: json['description'] as String?,
      sizeBytes: (json['size_bytes'] as num?)?.toInt(),
    );
  }

  final String id;
  final String name;
  final String provider;
  final EngineKind engine;

  /// Token budget. Used to decide when history must be trimmed.
  final int contextWindow;

  final bool supportsStreaming;

  /// Whether the model accepts image inputs.
  final bool supportsVision;

  final bool isDefault;
  final String? description;

  /// On-disk size for on-device models; `null` for hosted ones.
  final int? sizeBytes;

  /// Whether an on-device model's weights are present. Always true for remote.
  final bool isInstalled;

  /// Whether this model can be used right now given connectivity.
  bool isUsable({required bool isOnline}) =>
      engine.isOnDevice ? isInstalled : isOnline;

  ModelDescriptor copyWith({bool? isInstalled}) => ModelDescriptor(
    id: id,
    name: name,
    provider: provider,
    engine: engine,
    contextWindow: contextWindow,
    supportsStreaming: supportsStreaming,
    supportsVision: supportsVision,
    isDefault: isDefault,
    description: description,
    sizeBytes: sizeBytes,
    isInstalled: isInstalled ?? this.isInstalled,
  );

  @override
  List<Object?> get props => [
    id,
    name,
    provider,
    engine,
    contextWindow,
    supportsStreaming,
    supportsVision,
    isDefault,
    isInstalled,
  ];
}

/// Identifiers for the models this app ships knowledge of.
abstract final class KnownModels {
  /// The on-device router/embedder that ships in the app bundle.
  static const String onDeviceRouter = 'evdekimi-router-onnx-v1';

  static const ModelDescriptor onDevice = ModelDescriptor(
    id: onDeviceRouter,
    name: 'EVDEkimi Local',
    provider: 'on-device',
    engine: EngineKind.onDevice,
    contextWindow: 2048,
    description:
        'Runs entirely on this device through ONNX Runtime. Classifies intent '
        'and answers from your own conversation history — no network needed.',
  );
}
