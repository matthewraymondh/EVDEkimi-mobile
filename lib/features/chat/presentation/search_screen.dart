import 'dart:async';

import 'package:evdekimi_ai/app/routes.dart';
import 'package:evdekimi_ai/design_system/chat_theme.dart';
import 'package:evdekimi_ai/design_system/glass.dart';
import 'package:evdekimi_ai/design_system/tokens.dart';
import 'package:evdekimi_ai/design_system/widgets/app_widgets.dart';
import 'package:evdekimi_ai/di/providers.dart';
import 'package:evdekimi_ai/features/chat/domain/repositories/chat_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// Semantic search over stored messages, running entirely on-device.
///
/// This is the on-device model doing something genuinely useful rather than
/// demonstrative: the query is embedded locally, compared against locally-stored
/// message embeddings, and ranked — with no network involved at any point. It is
/// the one screen that works identically in airplane mode.
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _controller = TextEditingController();

  Timer? _debounce;
  List<MessageSearchHit> _hits = const [];
  bool _isSearching = false;
  bool _hasSearched = false;

  @override
  void initState() {
    super.initState();
    // Index anything that predates the embedding feature, so search is useful on
    // a history created before it existed.
    unawaited(ref.read(chatRepositoryProvider).backfillEmbeddings());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onQueryChanged(String query) {
    // Debounce: each keystroke would otherwise run an ONNX pass plus a full
    // similarity scan.
    _debounce?.cancel();
    if (query.trim().length < 2) {
      setState(() {
        _hits = const [];
        _hasSearched = false;
      });
      return;
    }
    _debounce = Timer(
      const Duration(milliseconds: 280),
      () => unawaited(_search(query)),
    );
  }

  Future<void> _search(String query) async {
    setState(() => _isSearching = true);
    final result = await ref.read(chatRepositoryProvider).search(query);
    if (!mounted) return;
    setState(() {
      _isSearching = false;
      _hasSearched = true;
      _hits = result.valueOrNull ?? const [];
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassAppBar(
        title: const Text('Search history'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: _isSearching
              ? const LinearProgressIndicator(minHeight: 1)
              : const SizedBox(height: 1),
        ),
      ),
      body: AppBackdrop(
        child: Column(
          children: [
            // Clears the glass bar above.
            SizedBox(
              height: MediaQuery.paddingOf(context).top + kToolbarHeight,
            ),
            Padding(
              padding: const EdgeInsets.all(AppSpacing.gutter),
              child: TextField(
                controller: _controller,
                autofocus: true,
                textInputAction: TextInputAction.search,
                decoration: const InputDecoration(
                  hintText: 'What did I ask about…',
                  prefixIcon: Icon(Icons.search_rounded),
                ),
                onChanged: _onQueryChanged,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.gutter,
              ),
              child: Row(
                children: [
                  AppBadge(
                    label: 'On-device · no network',
                    icon: Icons.memory_rounded,
                    color: context.chatTheme.onDeviceAccent,
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Expanded(child: _buildResults()),
          ],
        ),
      ),
    );
  }

  Widget _buildResults() {
    if (!_hasSearched) {
      return const EmptyStateView(
        icon: Icons.travel_explore_rounded,
        title: 'Search by meaning',
        message:
            'Your messages are embedded locally by the bundled ONNX model, so '
            'search finds related wording — not just exact matches.',
      );
    }
    if (_hits.isEmpty) {
      return const EmptyStateView(
        icon: Icons.search_off_rounded,
        title: 'No matches',
        message:
            'Nothing similar found on this device. Search improves as you chat '
            'more, since every completed message gets indexed.',
      );
    }

    return ListView.separated(
      // Pushed over the shell, so the navigation bar is not visible here and no
      // extra bottom room is needed for it.
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.gutter,
        0,
        AppSpacing.gutter,
        AppSpacing.xl,
      ),
      itemCount: _hits.length,
      separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm),
      itemBuilder: (context, index) {
        final hit = _hits[index];
        return Card(
          child: ListTile(
            onTap: () =>
                context.go(AppRoutes.chatPath(hit.message.conversationId)),
            title: Text(
              hit.conversationTitle.isEmpty
                  ? 'Untitled'
                  : hit.conversationTitle,
              style: context.texts.labelLarge,
            ),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xs),
              child: Text(
                hit.message.searchableText,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            trailing: AppBadge(
              // Similarity is shown because it is the honest signal for why a
              // result ranked where it did.
              label: '${(hit.score * 100).round()}%',
              color: hit.score > 0.6
                  ? context.chatTheme.success
                  : context.colors.onSurfaceVariant,
            ),
          ),
        );
      },
    );
  }
}
