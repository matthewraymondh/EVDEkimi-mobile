import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:evdekimi_ai/core/logging/app_logger.dart';
import 'package:flutter/foundation.dart';

/// Coarse reachability state used to drive offline UI and the outbox.
enum NetworkStatus {
  online,
  offline;

  bool get isOnline => this == NetworkStatus.online;
  bool get isOffline => this == NetworkStatus.offline;
}

/// Reports whether the device has a usable network interface.
///
/// An important limitation, called out here because it shapes the offline
/// design: `connectivity_plus` reports *interface* state, not reachability. A
/// device on captive-portal Wi-Fi reports `online` while every request fails.
///
/// So this service is treated as a hint, not a source of truth:
///
/// * The UI uses it for the offline banner and to decide when to *try* flushing
///   the outbox.
/// * Whether a message actually sent is decided by the request outcome — a
///   `NetworkFailure` re-queues it regardless of what this service says.
///
/// That inversion is why a failed send is never lost on a flaky network.
abstract interface class ConnectivityService {
  /// The last known status, available synchronously for build methods.
  NetworkStatus get status;

  /// Distinct status changes, starting with the current value.
  Stream<NetworkStatus> get onStatusChanged;

  /// Forces a fresh platform query.
  Future<NetworkStatus> refresh();

  Future<void> dispose();
}

class ConnectivityPlusService implements ConnectivityService {
  ConnectivityPlusService({
    required AppLogger logger,
    Connectivity? connectivity,
  }) : _logger = logger.scoped('connectivity'),
       _connectivity = connectivity ?? Connectivity();

  final AppLogger _logger;
  final Connectivity _connectivity;

  final StreamController<NetworkStatus> _controller =
      StreamController<NetworkStatus>.broadcast();

  StreamSubscription<List<ConnectivityResult>>? _subscription;

  // Optimistic default: assuming online avoids a spurious offline banner during
  // the first frame, before the platform has answered.
  NetworkStatus _status = NetworkStatus.online;
  bool _initialised = false;

  @override
  NetworkStatus get status => _status;

  @override
  Stream<NetworkStatus> get onStatusChanged async* {
    yield _status;
    yield* _controller.stream;
  }

  /// Subscribes to platform changes. Safe to call more than once.
  Future<void> initialise() async {
    if (_initialised) return;
    _initialised = true;

    _subscription = _connectivity.onConnectivityChanged.listen(
      (results) => _emit(_fromResults(results)),
      onError: (Object error, StackTrace stackTrace) {
        // Losing the change stream should not brick the app; fall back to
        // assuming connectivity and let request outcomes correct us.
        _logger.w(
          'Connectivity stream error',
          error: error,
          stackTrace: stackTrace,
        );
        _emit(NetworkStatus.online);
      },
    );

    await refresh();
  }

  @override
  Future<NetworkStatus> refresh() async {
    try {
      final results = await _connectivity.checkConnectivity();
      _emit(_fromResults(results));
    } catch (error, stackTrace) {
      _logger.w(
        'Connectivity check failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
    return _status;
  }

  void _emit(NetworkStatus next) {
    if (next == _status) return;
    _status = next;
    _logger.i('Network status changed', fields: {'status': next.name});
    if (!_controller.isClosed) _controller.add(next);
  }

  static NetworkStatus _fromResults(List<ConnectivityResult> results) {
    final hasInterface = results.any(
      (result) => result != ConnectivityResult.none,
    );
    return hasInterface ? NetworkStatus.online : NetworkStatus.offline;
  }

  @override
  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
    await _controller.close();
  }
}

/// A connectivity service driven imperatively by tests.
@visibleForTesting
class FakeConnectivityService implements ConnectivityService {
  FakeConnectivityService([this._status = NetworkStatus.online]);

  final StreamController<NetworkStatus> _controller =
      StreamController<NetworkStatus>.broadcast();

  NetworkStatus _status;

  @override
  NetworkStatus get status => _status;

  @override
  Stream<NetworkStatus> get onStatusChanged async* {
    yield _status;
    yield* _controller.stream;
  }

  void set(NetworkStatus status) {
    if (status == _status) return;
    _status = status;
    _controller.add(status);
  }

  @override
  Future<NetworkStatus> refresh() async => _status;

  @override
  Future<void> dispose() => _controller.close();
}
