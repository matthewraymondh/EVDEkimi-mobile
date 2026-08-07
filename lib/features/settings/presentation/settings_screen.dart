import 'package:evdekimi_ai/app/routes.dart';
import 'package:evdekimi_ai/design_system/chat_theme.dart';
import 'package:evdekimi_ai/design_system/tokens.dart';
import 'package:evdekimi_ai/design_system/widgets/app_widgets.dart';
import 'package:evdekimi_ai/di/providers.dart';
import 'package:evdekimi_ai/features/auth/presentation/auth_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// Preferences, engine status, and account actions.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsControllerProvider);
    final controller = ref.read(settingsControllerProvider.notifier);
    final user = ref.watch(currentUserProvider);
    final config = ref.watch(appConfigProvider);
    final onDeviceAsync = ref.watch(onDeviceAvailableProvider);
    final pendingCount = ref.watch(pendingMessageCountProvider).value ?? 0;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          if (user != null)
            ListTile(
              leading: AppAvatar(label: user.initials),
              title: Text(user.friendlyName),
              subtitle: Text(user.email),
            ),

          const _SectionHeader('Appearance'),
          // Flutter 3.44 moved radio group state to a RadioGroup ancestor; the
          // per-tile groupValue/onChanged pair is deprecated.
          RadioGroup<ThemeMode>(
            groupValue: settings.themeMode,
            onChanged: (value) {
              if (value != null) controller.setThemeMode(value);
            },
            child: Column(
              children: [
                for (final mode in ThemeMode.values)
                  RadioListTile<ThemeMode>(
                    value: mode,
                    title: Text(switch (mode) {
                      ThemeMode.system => 'Match system',
                      ThemeMode.light => 'Light',
                      ThemeMode.dark => 'Dark',
                    }),
                  ),
              ],
            ),
          ),

          const _SectionHeader('On-device AI'),
          onDeviceAsync.when(
            loading: () => const ListTile(
              leading: SizedBox.square(
                dimension: AppSizes.iconSm,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              title: Text('Checking the on-device model…'),
            ),
            error: (error, _) => ListTile(
              leading: Icon(
                Icons.error_outline_rounded,
                color: context.chatTheme.danger,
              ),
              title: const Text('On-device model unavailable'),
              subtitle: Text('$error'),
            ),
            data: (isAvailable) => ListTile(
              leading: Icon(
                Icons.memory_rounded,
                color: isAvailable
                    ? context.chatTheme.onDeviceAccent
                    : context.colors.onSurfaceVariant,
              ),
              title: Text(
                isAvailable
                    ? 'ONNX Runtime ready'
                    : 'ONNX Runtime not available',
              ),
              subtitle: Text(
                isAvailable
                    ? 'A 130 KB classifier and embedder runs locally. Powers '
                          'offline answers and on-device semantic search.'
                    : 'This device could not load the bundled model. The app '
                          'will use cloud models only.',
              ),
            ),
          ),
          SwitchListTile(
            value: settings.useOnDeviceWhenOffline,
            onChanged: (value) =>
                controller.setUseOnDeviceWhenOffline(value: value),
            title: const Text('Use on-device model when offline'),
            subtitle: const Text(
              'Off: messages are queued instead and sent when you reconnect.',
            ),
          ),

          const _SectionHeader('Composing'),
          SwitchListTile(
            value: settings.sendOnEnter,
            onChanged: (value) => controller.setSendOnEnter(value: value),
            title: const Text('Enter sends the message'),
            subtitle: const Text('Off: Enter inserts a line break.'),
          ),
          SwitchListTile(
            value: settings.hapticsEnabled,
            onChanged: (value) => controller.setHaptics(value: value),
            title: const Text('Haptic feedback'),
          ),

          const _SectionHeader('Sync'),
          ListTile(
            leading: Icon(
              pendingCount > 0 ? Icons.schedule_rounded : Icons.check_rounded,
              color: pendingCount > 0
                  ? context.chatTheme.warning
                  : context.chatTheme.success,
            ),
            title: Text(
              pendingCount > 0
                  ? '$pendingCount message${pendingCount == 1 ? '' : 's'} queued'
                  : 'Everything is sent',
            ),
            subtitle: const Text(
              'Queued messages are stored on this device and retried '
              'automatically.',
            ),
            trailing: pendingCount > 0
                ? TextButton(
                    onPressed: () =>
                        ref.read(chatRepositoryProvider).flushOutbox(),
                    child: const Text('Retry now'),
                  )
                : null,
          ),

          if (config.showDiagnostics) ...[
            const _SectionHeader('Developer'),
            ListTile(
              leading: const Icon(Icons.terminal_rounded),
              title: const Text('Log console'),
              subtitle: const Text('In-app structured logs for this session'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => context.push(AppRoutes.logs),
            ),
            ListTile(
              leading: const Icon(Icons.dns_outlined),
              title: const Text('API base URL'),
              subtitle: Text(config.apiBaseUrl),
            ),
          ],

          const _SectionHeader('Account'),
          ListTile(
            leading: Icon(
              Icons.logout_rounded,
              color: context.chatTheme.danger,
            ),
            title: Text(
              'Sign out',
              style: TextStyle(color: context.chatTheme.danger),
            ),
            subtitle: const Text(
              'Removes conversations stored on this device.',
            ),
            onTap: () => _confirmSignOut(context, ref),
          ),
          const SizedBox(height: AppSpacing.xxl),
        ],
      ),
    );
  }

  Future<void> _confirmSignOut(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text(
          'Your conversations are stored locally and will be removed from this '
          'device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    // The router's guard sends the user to sign-in once the session clears.
    await ref.read(authControllerProvider.notifier).signOut();
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      AppSpacing.gutter,
      AppSpacing.xl,
      AppSpacing.gutter,
      AppSpacing.sm,
    ),
    child: Text(
      title.toUpperCase(),
      style: context.texts.labelSmall?.copyWith(
        color: context.colors.primary,
        fontWeight: FontWeight.w700,
        letterSpacing: 1,
      ),
    ),
  );
}
