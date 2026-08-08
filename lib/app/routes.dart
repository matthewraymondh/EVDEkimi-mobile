/// Route paths, in one place.
///
/// Constants rather than string literals at call sites so a renamed route is a
/// compile error instead of a dead link discovered by a user.
abstract final class AppRoutes {
  static const String splash = '/';
  static const String signIn = '/sign-in';
  // --- Tabs, inside the navigation shell -----------------------------------
  static const String conversations = '/conversations';
  static const String search = '/search';
  static const String settings = '/settings';

  /// The chat thread deliberately sits *outside* the shell, so opening a
  /// conversation covers the navigation bar rather than sitting above it. A
  /// transcript is a focused, full-screen task; leaving tabs visible invites
  /// switching away mid-generation.
  ///
  /// It is also why the path is `/chat/...` rather than nested under
  /// `/conversations/...` — a top-level route that prefixed a shell branch would
  /// be ambiguous to match.
  static const String chat = '/chat/:conversationId';

  static const String logs = '/settings/logs';

  /// Path parameter name used by [chat].
  static const String conversationIdParam = 'conversationId';

  static String chatPath(String conversationId) => '/chat/$conversationId';

  /// Tab order, used by the shell and its navigation bar.
  static const List<String> tabs = [conversations, search, settings];
}
