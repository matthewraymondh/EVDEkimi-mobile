import 'package:evdekimi_ai/app/floating_nav_bar.dart';
import 'package:evdekimi_ai/design_system/glass.dart';
import 'package:evdekimi_ai/features/chat/presentation/conversation_list_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// Scaffold shared by the three top-level tabs.
///
/// Backed by `StatefulShellRoute.indexedStack`, so each tab keeps its own
/// navigation stack and scroll position — returning to Chats lands where you
/// left it rather than rebuilt at the top.
class HomeShell extends ConsumerWidget {
  const HomeShell({required this.navigationShell, super.key});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      // The bar floats over the content rather than displacing it, so a list can
      // scroll beneath it. Screens add bottom padding for the overlap.
      extendBody: true,
      // The wash that gives the glass chrome something to refract. Without it a
      // refractive bar over a flat fill bends nothing and just looks murky.
      body: AppBackdrop(child: navigationShell),
      bottomNavigationBar: FloatingNavBar(
        currentIndex: navigationShell.currentIndex,
        onSelect: (index) => navigationShell.goBranch(
          index,
          // Tapping the tab you are already on pops that tab back to its root,
          // which is the behaviour users expect from every other app.
          initialLocation: index == navigationShell.currentIndex,
        ),
        onNewChat: () => startNewConversation(context, ref),
      ),
    );
  }
}
