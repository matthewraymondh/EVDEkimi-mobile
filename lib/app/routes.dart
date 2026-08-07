/// Route paths, in one place.
///
/// Constants rather than string literals at call sites so a renamed route is a
/// compile error instead of a dead link discovered by a user.
abstract final class AppRoutes {
  static const String splash = '/';
  static const String signIn = '/sign-in';
  static const String conversations = '/conversations';
  static const String chat = '/conversations/:conversationId';
  static const String settings = '/settings';
  static const String search = '/search';
  static const String logs = '/settings/logs';

  /// Path parameter name used by [chat].
  static const String conversationIdParam = 'conversationId';

  static String chatPath(String conversationId) =>
      '/conversations/$conversationId';
}
