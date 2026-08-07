import 'dart:async';

import 'package:evdekimi_ai/core/error/exceptions.dart';
import 'package:evdekimi_ai/core/logging/app_logger.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// Live dictation state, rendered by the composer.
class SpeechState {
  const SpeechState({
    this.isListening = false,
    this.isAvailable = false,
    this.transcript = '',
    this.soundLevel = 0,
    this.localeId,
    this.error,
  });

  final bool isListening;
  final bool isAvailable;

  /// Best transcript so far. Interim results are included so text appears while
  /// the user is still speaking.
  final String transcript;

  /// Normalised microphone level in `[0, 1]`, for the waveform indicator.
  final double soundLevel;

  final String? localeId;
  final String? error;

  SpeechState copyWith({
    bool? isListening,
    bool? isAvailable,
    String? transcript,
    double? soundLevel,
    String? localeId,
    String? error,
    bool clearError = false,
  }) => SpeechState(
    isListening: isListening ?? this.isListening,
    isAvailable: isAvailable ?? this.isAvailable,
    transcript: transcript ?? this.transcript,
    soundLevel: soundLevel ?? this.soundLevel,
    localeId: localeId ?? this.localeId,
    error: clearError ? null : (error ?? this.error),
  );
}

/// On-device speech-to-text.
///
/// Uses the platform recogniser (Android `SpeechRecognizer`, iOS `SFSpeechRecognizer`),
/// which keeps dictation working offline on devices with on-device recognition
/// installed and means audio never passes through this app's backend.
///
/// The service owns two pieces of state that are easy to get wrong:
///
/// * **Permission vs. availability.** `initialize()` both requests the mic
///   permission and probes for a recogniser. A denial is reported as a
///   [PermissionDeniedException] so the UI can deep-link to settings rather than
///   silently showing a dead button.
/// * **Session lifetime.** The platform stops listening on its own after a pause.
///   The `onStatus` callback is the only reliable signal for that, so the
///   listening flag is driven from it rather than from our own `stop()` call.
class SpeechInputService {
  SpeechInputService({required AppLogger logger, SpeechToText? speechToText})
    : _logger = logger.scoped('input.speech'),
      _speech = speechToText ?? SpeechToText();

  /// Stop after this much silence, so a user who trails off is not left
  /// recording indefinitely.
  static const Duration _pauseFor = Duration(seconds: 3);

  /// Hard cap on one dictation, as a battery guard.
  static const Duration _listenFor = Duration(minutes: 2);

  /// Recogniser codes that mean "heard nothing", not "something broke".
  static const Set<String> _benignSpeechErrors = {
    'error_no_match',
    'error_speech_timeout',
  };

  final AppLogger _logger;
  final SpeechToText _speech;

  final StreamController<SpeechState> _states =
      StreamController<SpeechState>.broadcast();

  SpeechState _state = const SpeechState();

  SpeechState get state => _state;

  Stream<SpeechState> get onStateChanged async* {
    yield _state;
    yield* _states.stream;
  }

  /// Prepares the recogniser. Safe to call repeatedly.
  Future<bool> initialise() async {
    if (_state.isAvailable) return true;
    try {
      final available = await _speech.initialize(
        onStatus: _handleStatus,
        onError: (SpeechRecognitionError error) {
          // "no match" and "timeout" just mean the recogniser heard nothing
          // usable — the ordinary outcome of tapping the mic and not speaking.
          // Logging those as warnings buries the errors that need attention.
          // The plugin reports both with permanent: true, so that flag cannot be
          // used to tell them apart.
          if (_benignSpeechErrors.contains(error.errorMsg)) {
            _logger.d('No speech detected', fields: {'code': error.errorMsg});
          } else {
            _logger.w(
              'Speech error',
              fields: {'error': error.errorMsg, 'permanent': error.permanent},
            );
          }
          _emit(
            _state.copyWith(
              isListening: false,
              error: _friendlyError(error.errorMsg),
            ),
          );
        },
      );
      _emit(_state.copyWith(isAvailable: available, clearError: true));
      if (!available) {
        _logger.w('No speech recogniser available on this device');
      }
      return available;
    } catch (error, stackTrace) {
      _logger.w(
        'Speech initialisation failed',
        error: error,
        stackTrace: stackTrace,
      );
      _emit(
        _state.copyWith(
          isAvailable: false,
          error: 'Speech recognition is unavailable on this device.',
        ),
      );
      return false;
    }
  }

  /// Starts dictation, reporting partial transcripts as they arrive.
  Future<void> start({String? localeId}) async {
    if (!await initialise()) {
      throw const EngineUnavailableException(
        'Speech recognition is not available',
      );
    }
    if (!await _speech.hasPermission) {
      throw const PermissionDeniedException('Microphone');
    }
    if (_speech.isListening) return;

    _emit(_state.copyWith(transcript: '', isListening: true, clearError: true));

    await _speech.listen(
      onResult: (SpeechRecognitionResult result) {
        _emit(_state.copyWith(transcript: result.recognizedWords));
      },
      onSoundLevelChange: (level) {
        // The platform reports roughly -2..10 dB; map it into [0,1] for the UI.
        final normalised = ((level + 2) / 12).clamp(0.0, 1.0);
        _emit(_state.copyWith(soundLevel: normalised));
      },
      // Everything goes through SpeechListenOptions: the equivalent top-level
      // arguments on listen() are deprecated in 7.x.
      // `partialResults` defaults to true, which is what makes dictation feel
      // live, so it is left at the default rather than restated.
      listenOptions: SpeechListenOptions(
        cancelOnError: true,
        listenMode: ListenMode.dictation,
        pauseFor: _pauseFor,
        listenFor: _listenFor,
        localeId: localeId,
      ),
    );
  }

  /// Stops listening and returns the final transcript.
  Future<String> stop() async {
    if (_speech.isListening) await _speech.stop();
    _emit(_state.copyWith(isListening: false, soundLevel: 0));
    return _state.transcript;
  }

  /// Abandons the session, discarding the transcript.
  Future<void> cancel() async {
    if (_speech.isListening) await _speech.cancel();
    _emit(_state.copyWith(isListening: false, transcript: '', soundLevel: 0));
  }

  /// Locales the recogniser supports, for a language picker.
  Future<List<LocaleName>> locales() async {
    if (!await initialise()) return const [];
    return _speech.locales();
  }

  void _handleStatus(String status) {
    // 'done'/'notListening' can arrive without us calling stop(), so this is the
    // authoritative source for the listening flag.
    final isListening = status == 'listening';
    if (isListening != _state.isListening) {
      _emit(_state.copyWith(isListening: isListening, soundLevel: 0));
    }
  }

  static String _friendlyError(String code) => switch (code) {
    'error_no_match' => "Didn't catch that. Try again.",
    'error_speech_timeout' => 'No speech detected.',
    'error_network' || 'error_network_timeout' =>
      'Speech recognition needs a network on this device.',
    'error_permission' => 'Microphone permission is required.',
    'error_busy' => 'The microphone is in use by another app.',
    _ => 'Dictation failed. Please try again.',
  };

  void _emit(SpeechState state) {
    _state = state;
    if (!_states.isClosed) _states.add(state);
  }

  Future<void> dispose() async {
    await cancel();
    await _states.close();
  }
}
