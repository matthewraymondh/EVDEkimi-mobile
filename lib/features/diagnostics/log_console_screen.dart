import 'package:evdekimi_ai/core/logging/log_record.dart';
import 'package:evdekimi_ai/design_system/app_theme.dart';
import 'package:evdekimi_ai/design_system/chat_theme.dart';
import 'package:evdekimi_ai/design_system/tokens.dart';
import 'package:evdekimi_ai/design_system/widgets/app_widgets.dart';
import 'package:evdekimi_ai/di/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// In-app view of this session's structured logs.
///
/// This is here because the most valuable logs are the ones from a real device
/// that is not plugged into a laptop — a failing SSE stream on someone's phone on
/// mobile data. `RingBufferLogSink` already has the records; this exposes and
/// exports them. Hidden in production builds via `AppConfig.showDiagnostics`.
class LogConsoleScreen extends ConsumerStatefulWidget {
  const LogConsoleScreen({super.key});

  @override
  ConsumerState<LogConsoleScreen> createState() => _LogConsoleScreenState();
}

class _LogConsoleScreenState extends ConsumerState<LogConsoleScreen> {
  LogLevel _minimumLevel = LogLevel.debug;

  @override
  Widget build(BuildContext context) {
    final sink = ref.watch(logBufferProvider);

    // The sink is a ChangeNotifier, so this rebuilds as records arrive.
    return ListenableBuilder(
      listenable: sink,
      builder: (context, _) {
        final records = sink.records
            .where((record) => record.level >= _minimumLevel)
            .toList(growable: false)
            .reversed
            .toList(growable: false);

        return Scaffold(
          appBar: AppBar(
            title: const Text('Log console'),
            actions: [
              IconButton(
                tooltip: 'Copy all',
                onPressed: records.isEmpty
                    ? null
                    : () {
                        Clipboard.setData(ClipboardData(text: sink.export()));
                        showAppSnackBar(context, 'Logs copied');
                      },
                icon: const Icon(Icons.copy_all_rounded),
              ),
              IconButton(
                tooltip: 'Clear',
                onPressed: sink.clear,
                icon: const Icon(Icons.delete_sweep_outlined),
              ),
            ],
          ),
          body: Column(
            children: [
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.gutter,
                  vertical: AppSpacing.sm,
                ),
                child: Row(
                  children: [
                    for (final level in LogLevel.values)
                      Padding(
                        padding: const EdgeInsets.only(right: AppSpacing.sm),
                        child: ChoiceChip(
                          label: Text(level.label),
                          selected: _minimumLevel == level,
                          onSelected: (_) =>
                              setState(() => _minimumLevel = level),
                        ),
                      ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: records.isEmpty
                    ? const EmptyStateView(
                        icon: Icons.receipt_long_outlined,
                        title: 'No logs at this level',
                        message: 'Lower the threshold or use the app a little.',
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.all(AppSpacing.md),
                        itemCount: records.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (context, index) =>
                            _LogRow(record: records[index]),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _LogRow extends StatelessWidget {
  const _LogRow({required this.record});

  final LogRecord record;

  @override
  Widget build(BuildContext context) {
    final chat = context.chatTheme;
    final color = switch (record.level) {
      LogLevel.error => chat.danger,
      LogLevel.warning => chat.warning,
      LogLevel.info => context.colors.primary,
      LogLevel.debug || LogLevel.trace => context.colors.onSurfaceVariant,
    };

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: SelectableText.rich(
        TextSpan(
          style: context.texts.bodySmall?.copyWith(
            fontFamily: AppTheme.monospaceFallback.first,
            fontFamilyFallback: AppTheme.monospaceFallback,
          ),
          children: [
            TextSpan(
              text: '${record.level.label} ',
              style: TextStyle(color: color, fontWeight: FontWeight.w700),
            ),
            TextSpan(
              text: '[${record.scope}] ',
              style: TextStyle(color: context.colors.onSurfaceVariant),
            ),
            TextSpan(text: record.message),
            if (record.fields.isNotEmpty)
              TextSpan(
                text:
                    '  ${record.fields.entries.map((entry) => '${entry.key}=${entry.value}').join(' ')}',
                style: TextStyle(color: context.colors.onSurfaceVariant),
              ),
            if (record.error != null)
              TextSpan(
                text: '\n${record.error}',
                style: TextStyle(color: chat.danger),
              ),
          ],
        ),
      ),
    );
  }
}
