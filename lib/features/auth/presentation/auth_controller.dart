import 'package:evdekimi_ai/core/error/failure.dart';
import 'package:evdekimi_ai/di/providers.dart';
import 'package:evdekimi_ai/features/auth/domain/entities/auth_session.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Form state for the sign-in / sign-up screen.
class AuthFormState {
  const AuthFormState({
    this.isSubmitting = false,
    this.isSignUp = false,
    this.fieldErrors = const {},
    this.failure,
  });

  final bool isSubmitting;
  final bool isSignUp;

  /// Per-field messages, keyed by field name, so inputs can show their own error.
  final Map<String, String> fieldErrors;

  /// A failure that is not attributable to one field (network, server, 401).
  final Failure? failure;

  AuthFormState copyWith({
    bool? isSubmitting,
    bool? isSignUp,
    Map<String, String>? fieldErrors,
    Failure? failure,
    bool clearFailure = false,
  }) => AuthFormState(
    isSubmitting: isSubmitting ?? this.isSubmitting,
    isSignUp: isSignUp ?? this.isSignUp,
    fieldErrors: fieldErrors ?? this.fieldErrors,
    failure: clearFailure ? null : (failure ?? this.failure),
  );
}

/// Drives authentication from the form.
///
/// The controller owns *form* state only. The session itself lives in
/// `authRepositoryProvider` and is observed through `authSessionProvider`, so the
/// router's redirect guard does not depend on this screen having been built.
class AuthController extends Notifier<AuthFormState> {
  @override
  AuthFormState build() => const AuthFormState();

  void toggleMode() => state = AuthFormState(isSignUp: !state.isSignUp);

  /// Clears the error for a field as soon as the user edits it, so a stale
  /// message does not sit under an input they are already fixing.
  void clearFieldError(String field) {
    if (!state.fieldErrors.containsKey(field)) return;
    final next = Map<String, String>.of(state.fieldErrors)..remove(field);
    state = state.copyWith(fieldErrors: next, clearFailure: true);
  }

  Future<bool> submit({
    required String email,
    required String password,
    String? displayName,
  }) async {
    if (state.isSubmitting) return false;

    state = state.copyWith(
      isSubmitting: true,
      fieldErrors: const {},
      clearFailure: true,
    );

    final credentials = AuthCredentials(
      email: email,
      password: password,
      displayName: displayName,
    );
    final repository = ref.read(authRepositoryProvider);

    final result = state.isSignUp
        ? await repository.signUp(credentials)
        : await repository.signIn(credentials);

    return result.fold(
      ok: (_) {
        // Leave isSubmitting true: the router is about to replace this screen,
        // and flipping the button back to enabled first would flash.
        return true;
      },
      err: (failure) {
        state = state.copyWith(
          isSubmitting: false,
          // A ValidationFailure carries per-field detail; anything else is shown
          // as a single banner above the form.
          fieldErrors: failure is ValidationFailure
              ? failure.fieldErrors
              : const {},
          failure:
              failure is ValidationFailure && failure.fieldErrors.isNotEmpty
              ? null
              : failure,
        );
        return false;
      },
    );
  }

  Future<void> signOut() => ref.read(authRepositoryProvider).signOut();
}

final authControllerProvider = NotifierProvider<AuthController, AuthFormState>(
  AuthController.new,
);
