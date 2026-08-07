import 'package:evdekimi_ai/core/error/error_mapper.dart';
import 'package:evdekimi_ai/core/error/failure.dart';

/// A total, exhaustively-matchable outcome type.
///
/// Repositories and use cases return `Result<T>` instead of throwing. Throwing
/// is confined to the data layer (where SDKs throw at us); everything above the
/// repository boundary deals in values. That makes error paths visible in the
/// type signature and impossible to forget, which is the main reason the UI
/// never has to guess whether a call can fail.
sealed class Result<T> {
  const Result();

  /// Runs [body], converting any thrown error into an [Err] via [ErrorMapper].
  ///
  /// This is the single sanctioned place where an exception becomes a
  /// [Failure], so mapping rules live in exactly one file.
  static Future<Result<T>> guardAsync<T>(
    Future<T> Function() body, {
    Failure Function(Object error, StackTrace stackTrace)? onError,
  }) async {
    try {
      return Ok<T>(await body());
    } catch (error, stackTrace) {
      return Err<T>(
        onError?.call(error, stackTrace) ??
            ErrorMapper.map(error, stackTrace: stackTrace),
      );
    }
  }

  /// Synchronous counterpart of [guardAsync].
  static Result<T> guard<T>(
    T Function() body, {
    Failure Function(Object error, StackTrace stackTrace)? onError,
  }) {
    try {
      return Ok<T>(body());
    } catch (error, stackTrace) {
      return Err<T>(
        onError?.call(error, stackTrace) ??
            ErrorMapper.map(error, stackTrace: stackTrace),
      );
    }
  }

  bool get isOk => this is Ok<T>;

  bool get isErr => this is Err<T>;

  /// The success value, or `null` when this is an [Err].
  T? get valueOrNull => switch (this) {
    Ok<T>(:final value) => value,
    Err<T>() => null,
  };

  /// The failure, or `null` when this is an [Ok].
  Failure? get failureOrNull => switch (this) {
    Ok<T>() => null,
    Err<T>(:final failure) => failure,
  };

  /// Collapses both branches into a single value.
  R fold<R>({
    required R Function(T value) ok,
    required R Function(Failure failure) err,
  }) => switch (this) {
    Ok<T>(:final value) => ok(value),
    Err<T>(:final failure) => err(failure),
  };

  /// Transforms the success value, preserving any failure.
  Result<R> map<R>(R Function(T value) transform) => switch (this) {
    Ok<T>(:final value) => Ok<R>(transform(value)),
    Err<T>(:final failure) => Err<R>(failure),
  };

  /// Chains another fallible operation.
  Result<R> flatMap<R>(Result<R> Function(T value) transform) => switch (this) {
    Ok<T>(:final value) => transform(value),
    Err<T>(:final failure) => Err<R>(failure),
  };

  /// Replaces the failure, preserving any success value.
  Result<T> mapErr(Failure Function(Failure failure) transform) =>
      switch (this) {
        Ok<T>() => this,
        Err<T>(:final failure) => Err<T>(transform(failure)),
      };

  /// The success value, or [fallback] when this is an [Err].
  T getOrElse(T Function(Failure failure) fallback) => switch (this) {
    Ok<T>(:final value) => value,
    Err<T>(:final failure) => fallback(failure),
  };
}

/// A successful outcome carrying [value].
final class Ok<T> extends Result<T> {
  const Ok(this.value);

  final T value;

  @override
  String toString() => 'Ok($value)';

  @override
  bool operator ==(Object other) =>
      other is Ok<T> &&
      other.runtimeType == runtimeType &&
      other.value == value;

  @override
  int get hashCode => Object.hash(runtimeType, value);
}

/// A failed outcome carrying [failure].
final class Err<T> extends Result<T> {
  const Err(this.failure);

  final Failure failure;

  @override
  String toString() => 'Err($failure)';

  @override
  bool operator ==(Object other) =>
      other is Err<T> &&
      other.runtimeType == runtimeType &&
      other.failure == failure;

  @override
  int get hashCode => Object.hash(runtimeType, failure);
}

/// Convenience helpers for the common `Result<void>` shape.
extension ResultVoidX on Result<void> {
  /// A `Result<void>` success, spelled without a dummy value at call sites.
  static Result<void> get success => const Ok<void>(null);
}

extension FutureResultX<T> on Future<Result<T>> {
  /// Maps the eventual success value without unwrapping at the call site.
  Future<Result<R>> mapOk<R>(R Function(T value) transform) async =>
      (await this).map(transform);
}
