import 'package:go_router/go_router.dart';
import 'package:rillight/app/app_shell.dart';
import 'package:rillight/app/home_page.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/connect_page.dart';
import 'package:rillight/auth/session_actions.dart';

abstract final class AppRoutes {
  static const home = '/';
  static const connect = '/connect';
}

GoRouter createAppRouter({required AuthController auth}) {
  return GoRouter(
    initialLocation: AppRoutes.home,
    refreshListenable: auth,
    redirect: (context, state) {
      final loggedIn = auth.isLoggedIn;
      final onConnect = state.matchedLocation == AppRoutes.connect;
      if (!loggedIn && !onConnect) {
        return AppRoutes.connect;
      }
      if (loggedIn && onConnect) {
        return AppRoutes.home;
      }
      return null;
    },
    routes: [
      ShellRoute(
        builder: (context, state, child) =>
            AppShell(actions: const [SessionActions()], child: child),
        routes: [
          GoRoute(
            path: AppRoutes.connect,
            builder: (context, state) => const ConnectPage(),
          ),
          GoRoute(
            path: AppRoutes.home,
            builder: (context, state) => const AppHomePage(),
          ),
        ],
      ),
    ],
  );
}
