import 'package:evdekimi_ai/design_system/chat_theme.dart';
import 'package:evdekimi_ai/design_system/tokens.dart';
import 'package:evdekimi_ai/design_system/widgets/app_widgets.dart';
import 'package:evdekimi_ai/design_system/widgets/brand_mark.dart';
import 'package:evdekimi_ai/di/providers.dart';
import 'package:evdekimi_ai/features/auth/presentation/auth_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Sign-in and sign-up, toggled in place.
///
/// One screen for both because the fields are nearly identical and swapping
/// between them is the most common thing a user does when they mistype which one
/// they wanted.
class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key});

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _nameController = TextEditingController();
  final _passwordFocus = FocusNode();

  bool _obscurePassword = true;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _nameController.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    // Dismiss the keyboard first so the error banner is not hidden behind it.
    FocusScope.of(context).unfocus();

    final succeeded = await ref
        .read(authControllerProvider.notifier)
        .submit(
          email: _emailController.text,
          password: _passwordController.text,
          displayName: ref.read(authControllerProvider).isSignUp
              ? _nameController.text
              : null,
        );

    // Navigation is handled by the router's redirect guard reacting to the new
    // session, so there is nothing to push here.
    if (!succeeded && mounted) {
      final failure = ref.read(authControllerProvider).failure;
      if (failure != null) {
        showAppSnackBar(context, failure.userMessage, isError: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(authControllerProvider);
    final isOnline = ref.watch(isOnlineProvider);

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppSpacing.xl),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const _Wordmark(),
                    const SizedBox(height: AppSpacing.xxl),

                    Text(
                      state.isSignUp ? 'Create your account' : 'Welcome back',
                      style: context.texts.headlineSmall,
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      state.isSignUp
                          ? 'Your conversations are stored on this device.'
                          : 'Sign in to continue your conversations.',
                      style: context.texts.bodyMedium?.copyWith(
                        color: context.colors.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xl),

                    if (!isOnline)
                      const Padding(
                        padding: EdgeInsets.only(bottom: AppSpacing.lg),
                        child: _InlineNotice(
                          icon: Icons.cloud_off_rounded,
                          message:
                              'You appear to be offline. Signing in needs a '
                              'connection the first time.',
                        ),
                      ),

                    if (state.isSignUp) ...[
                      TextFormField(
                        controller: _nameController,
                        textInputAction: TextInputAction.next,
                        autofillHints: const [AutofillHints.name],
                        decoration: InputDecoration(
                          labelText: 'Name',
                          prefixIcon: const Icon(Icons.person_outline_rounded),
                          errorText: state.fieldErrors['name'],
                        ),
                        onChanged: (_) => ref
                            .read(authControllerProvider.notifier)
                            .clearFieldError('name'),
                      ),
                      const SizedBox(height: AppSpacing.lg),
                    ],

                    TextFormField(
                      controller: _emailController,
                      keyboardType: TextInputType.emailAddress,
                      textInputAction: TextInputAction.next,
                      autocorrect: false,
                      autofillHints: const [AutofillHints.email],
                      inputFormatters: [
                        // Emails never contain spaces; blocking them at the
                        // keyboard avoids a class of "invalid email" confusion.
                        FilteringTextInputFormatter.deny(RegExp(r'\s')),
                      ],
                      decoration: InputDecoration(
                        labelText: 'Email',
                        prefixIcon: const Icon(Icons.alternate_email_rounded),
                        errorText: state.fieldErrors['email'],
                      ),
                      onChanged: (_) => ref
                          .read(authControllerProvider.notifier)
                          .clearFieldError('email'),
                      onFieldSubmitted: (_) => _passwordFocus.requestFocus(),
                    ),
                    const SizedBox(height: AppSpacing.lg),

                    TextFormField(
                      controller: _passwordController,
                      focusNode: _passwordFocus,
                      obscureText: _obscurePassword,
                      textInputAction: TextInputAction.done,
                      autofillHints: [
                        state.isSignUp
                            ? AutofillHints.newPassword
                            : AutofillHints.password,
                      ],
                      decoration: InputDecoration(
                        labelText: 'Password',
                        prefixIcon: const Icon(Icons.lock_outline_rounded),
                        errorText: state.fieldErrors['password'],
                        suffixIcon: IconButton(
                          onPressed: () => setState(
                            () => _obscurePassword = !_obscurePassword,
                          ),
                          icon: Icon(
                            _obscurePassword
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                          ),
                          tooltip: _obscurePassword
                              ? 'Show password'
                              : 'Hide password',
                        ),
                      ),
                      onChanged: (_) => ref
                          .read(authControllerProvider.notifier)
                          .clearFieldError('password'),
                      onFieldSubmitted: (_) => _submit(),
                    ),

                    const SizedBox(height: AppSpacing.xl),

                    FilledButton(
                      onPressed: state.isSubmitting ? null : _submit,
                      child: state.isSubmitting
                          ? const SizedBox.square(
                              dimension: AppSizes.iconSm,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(state.isSignUp ? 'Create account' : 'Sign in'),
                    ),

                    const SizedBox(height: AppSpacing.md),

                    TextButton(
                      onPressed: state.isSubmitting
                          ? null
                          : () {
                              ref
                                  .read(authControllerProvider.notifier)
                                  .toggleMode();
                              _formKey.currentState?.reset();
                            },
                      child: Text(
                        state.isSignUp
                            ? 'Already have an account? Sign in'
                            : 'New here? Create an account',
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Wordmark extends StatelessWidget {
  const _Wordmark();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // No tinted plate behind it. The mark already carries its own wordmark
        // and enough negative space; boxing it added a second shape competing
        // with the one the brand actually is.
        const BrandMark(size: 104),
        const SizedBox(height: AppSpacing.sm),
        Text(
          'AI Assistant',
          style: context.texts.labelMedium?.copyWith(
            letterSpacing: 2.4,
            fontWeight: FontWeight.w600,
            color: context.colors.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _InlineNotice extends StatelessWidget {
  const _InlineNotice({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: context.chatTheme.warning.withValues(alpha: 0.12),
        borderRadius: AppRadius.allSm,
      ),
      child: Row(
        children: [
          Icon(icon, size: AppSizes.iconSm, color: context.chatTheme.warning),
          const SizedBox(width: AppSpacing.sm),
          Expanded(child: Text(message, style: context.texts.bodySmall)),
        ],
      ),
    );
  }
}
