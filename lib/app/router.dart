import '../auth/auth_scope.dart';
import 'l10n/app_localizations.dart';
import '../auth/server_selection_page.dart';
import '../auth/tv_server_selection_page.dart';
import '../auth/server_content_entry.dart';

import 'package:rillight/app/ui/ui.dart';
import 'package:rillight/library/detail_source_scope.dart';
import 'package:rillight/player/player_host_command.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/app_shell.dart';
import 'package:rillight/app/desktop_scroll.dart';
import 'package:rillight/app/mobile_motion.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/presentation_environment.dart';
import 'package:rillight/auth/android_connect_page.dart';
import 'package:rillight/app/settings/settings_page.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/connect_page.dart';
import 'package:rillight/home/catalog_shell.dart';
import 'package:rillight/home/home_page.dart';
import 'package:rillight/library/item_detail_page.dart';
import 'package:rillight/library/library_page.dart';
import 'package:rillight/library/mobile_library_page.dart';
import 'package:rillight/library/tv_library_page.dart';
import 'package:rillight/library/server_library_page.dart';
import 'package:rillight/library/person_works_page.dart';
import 'package:rillight/library/shelf_grid_page.dart';
import 'package:rillight/home/phone_shelf_page.dart';
import 'package:rillight/home/tv_shelf_page.dart';

import 'package:rillight/home/phone_home_edit_page.dart';

import 'package:rillight/library/aggregation_page.dart';

import 'package:rillight/app/mobile_shell.dart';
import 'package:rillight/app/phone_mine_page.dart';
import 'package:rillight/library/mobile_detail_page.dart';

import 'package:rillight/player/mobile_player_page.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/player/player_window_host.dart';

import 'source_route_extra_codec.dart';

import 'package:rillight/app/tv_shell.dart';
import 'package:rillight/auth/tv_connect_page.dart';
import 'package:rillight/library/tv_detail_page.dart';

import 'package:rillight/player/tv_player_page.dart';

export 'package:rillight/app/routes.dart';

/// Only navigation authorization changes need GoRouter reparsing. Catalog
/// counts, token renewal and same-account playback line projections rebuild
/// their own consumers. Reparsing those notifications in go_router 16 loses
/// the completer of an imperative push, leaving callers waiting after pop.
class _AuthRouteRefresh implements Listenable {
  _AuthRouteRefresh(this.auth);
  final AuthController auth;
  final Map<VoidCallback, VoidCallback> _listeners = {};

  Object get _state => (
    auth.isLoggedIn,
    auth.session?.server.id,
    auth.session?.userId,
    auth.presentingAuthorization,
    auth.savedServers.isEmpty,
  );

  @override
  void addListener(VoidCallback listener) {
    var previous = _state;
    void changed() {
      final current = _state;
      if (current == previous) return;
      previous = current;
      listener();
    }

    _listeners[listener] = changed;
    auth.addListener(changed);
  }

  @override
  void removeListener(VoidCallback listener) {
    final changed = _listeners.remove(listener);
    if (changed != null) auth.removeListener(changed);
  }
}

GoRouter createAppRouter({
  required AuthController auth,
  PresentationEnvironment environment = PresentationEnvironment.desktop,
}) {
  late final GoRouter router;
  router = GoRouter(
    initialLocation: AppRoutes.home,
    errorPageBuilder: (context, state) => _routePage(
      context,
      state,
      (context, state) => CupertinoPageScaffold(
        navigationBar: const CupertinoNavigationBar(middle: Text('页面不可用')),
        child: Center(
          child: AppButton(
            onPressed: () => context.go(AppRoutes.home),
            child: const Text('返回首页'),
          ),
        ),
      ),
      environment,
    ),
    extraCodec: const SourceRouteExtraCodec(),
    observers: [_ConnectFlowObserver(auth)],
    refreshListenable: Listenable.merge([
      _AuthRouteRefresh(auth),
      auth.serverAccess,
    ]),
    redirect: (context, state) {
      if (state.uri.path == '/private') return '/servers';
      if (!environment.isDesktop &&
          !environment.isTv &&
          state.uri.path == '/library') {
        return AppRoutes.home;
      }
      final loggedIn = auth.isLoggedIn;
      final onConnect = state.matchedLocation == AppRoutes.connect;
      var authorizedPlayer = false;
      var playerState = state;
      final committed = router.routerDelegate.currentConfiguration;
      if (committed.isNotEmpty &&
          committed.uri == state.uri &&
          router.state.uri.path.startsWith('/play/')) {
        // A pushed player has its own match/extra. Refreshing selected Auth
        // reparses the base detail URI, not that independent top route.
        playerState = router.state;
      }
      final request = playerState.extra;
      final runtime = context
          .getInheritedWidgetOfExactType<PlayerScope>()
          ?.bindings
          .runtime;
      final mountedPlayer =
          runtime?.hasMountedPlayer(playerState.pageKey) == true;
      if (playerState.uri.path.startsWith('/play/') && mountedPlayer) {
        // Immutable extra is startup intent, not ownership after switching.
        // Only this mounted controller's actual runtime lease counts.
        authorizedPlayer =
            runtime!.mountedPlayerOrigin(playerState.pageKey)?.permit.isValid ==
            true;
      } else if (playerState.uri.path.startsWith('/play/') &&
          request is PlayerOpenRequest &&
          request.source != null &&
          request.source!.itemId == request.itemId) {
        // Selected Auth owns catalog chrome, not an independent player.
        // A live local session is enough; an unchecked parent folder must
        // not bounce playback home. Runtime still proves item ancestry.
        authorizedPlayer = localSessionAllowsRoute(
          auth.sources,
          request.source!.account,
          libraryId: request.libraryId,
          accessGeneration: request.accessGeneration,
        );
      }
      if (playerState.uri.path.startsWith('/play/') &&
          request is PlayerOpenRequest &&
          request.source != null &&
          !authorizedPlayer &&
          !localSessionAllowsRoute(
            auth.sources,
            request.source!.account,
            libraryId: request.libraryId,
            accessGeneration: request.accessGeneration,
          )) {
        // An explicit source extra carries an existing lease. Reject stale or
        // forged intent before mounting; a fresh unsourced link uses entry UI.
        return environment.isDesktop ? AppRoutes.aggregation : AppRoutes.home;
      }
      if (!loggedIn &&
          !onConnect &&
          !authorizedPlayer &&
          !auth.presentingAuthorization &&
          auth.savedServers.isEmpty &&
          state.uri.path != '/servers') {
        return AppRoutes.connect;
      }
      if (loggedIn && onConnect && state.uri.queryParameters['add'] != '1') {
        return AppRoutes.home;
      }
      return null;
    },
    routes: [
      if (!environment.isDesktop && !environment.isTv) ...[
        GoRoute(
          path: AppRoutes.connect,
          name: AppRoutes.connect,
          pageBuilder: (context, state) => PhoneMotion.fadeThroughPage(
            context: context,
            state: state,
            child: AndroidConnectPage(
              addingAnother: state.uri.queryParameters['add'] == '1',
            ),
          ),
        ),
        ShellRoute(
          routes: [
            GoRoute(
              path: '/play/:itemId',
              pageBuilder: (context, state) {
                return PhoneMotion.fadeThroughPage(
                  context: context,
                  state: state,
                  child: AppUiTheme(
                    data: AppUiTheme.dark(),
                    child: _gatedPlayer(auth, state, environment),
                  ),
                );
              },
            ),
            GoRoute(
              path: AppRoutes.home,
              pageBuilder: (context, state) => PhoneMotion.fadeThroughPage(
                context: context,
                state: state,
                child: const MobileShell(),
              ),
            ),
            GoRoute(
              path: '/servers',
              pageBuilder: (context, state) => _routePage(
                context,
                state,
                (context, state) => ServerSelectionPage(
                  auth: auth,
                  routePage: true,
                  phone: !environment.isDesktop,
                ),
                environment,
              ),
            ),
            GoRoute(
              path: AppRoutes.mine,
              pageBuilder: (context, state) => PhoneMotion.sharedAxisPage(
                context: context,
                state: state,
                child: const PhoneMinePage(),
              ),
            ),
            GoRoute(
              path: AppRoutes.homeEdit,
              pageBuilder: (context, state) => PhoneMotion.sharedAxisPage(
                context: context,
                state: state,
                child: const PhoneHomeEditPage(),
              ),
            ),
            GoRoute(
              path: '/library/:viewId',
              pageBuilder: (context, state) => PhoneMotion.sharedAxisPage(
                context: context,
                state: state,
                child: MobileLibraryPage(
                  viewId: state.pathParameters['viewId']!,
                ),
              ),
            ),
            GoRoute(
              path: '/server/:serverId/library/:viewId',
              pageBuilder: (context, state) => PhoneMotion.sharedAxisPage(
                context: context,
                state: state,
                child: ServerLibraryPage(
                  serverId: state.pathParameters['serverId']!,
                  viewId: state.pathParameters['viewId']!,
                ),
              ),
            ),
            GoRoute(
              path: '/server/:serverId/resume',
              pageBuilder: (context, state) => PhoneMotion.sharedAxisPage(
                context: context,
                state: state,
                child: ServerResumePage(
                  serverId: state.pathParameters['serverId']!,
                  source: state.uri.queryParameters['section'] == 'favorites'
                      ? 'favorites'
                      : 'resume',
                ),
              ),
            ),
            GoRoute(
              path: '/item/:itemId',
              pageBuilder: (context, state) => PhoneMotion.detailPage(
                context: context,
                state: state,
                child: _sourceDetail(
                  auth,
                  state,
                  MobileDetailPage(
                    key: ValueKey(state.uri.toString()),
                    itemId: state.pathParameters['itemId']!,
                    initialSeasonId: state.uri.queryParameters['season'],
                    initialEpisodeId: state.uri.queryParameters['episode'],
                  ),
                ),
              ),
            ),
            GoRoute(
              path: '/shelf/:source',
              pageBuilder: (context, state) => PhoneMotion.sharedAxisPage(
                context: context,
                state: state,
                child: _shelfPage(auth, state, environment),
              ),
            ),
            GoRoute(
              path: '/person/:personId',
              pageBuilder: (context, state) => PhoneMotion.sharedAxisPage(
                context: context,
                state: state,
                child: _personWorks(state),
              ),
            ),
          ],
          pageBuilder: (context, state, child) => _shellPage(
            context,
            state,
            child,
            (context, state, child) => CatalogShell(auth: auth, child: child),
          ),
        ),
      ],
      if (environment.isTv) ...[
        GoRoute(
          path: AppRoutes.connect,
          name: AppRoutes.connect,
          pageBuilder: (context, state) => _routePage(
            context,
            state,
            (context, state) => TvConnectPage(
              addingAnother: state.uri.queryParameters['add'] == '1',
            ),
            environment,
          ),
        ),
        ShellRoute(
          routes: [
            GoRoute(
              path: AppRoutes.home,
              pageBuilder: (context, state) => _routePage(
                context,
                state,
                (context, state) => const TvShell(),
                environment,
              ),
            ),
            GoRoute(
              path: '/servers',
              pageBuilder: (context, state) => _routePage(
                context,
                state,
                (context, state) =>
                    TvServerSelectionPage(auth: auth, routePage: true),
                environment,
              ),
            ),
            GoRoute(
              path: '/library/:viewId',
              pageBuilder: (context, state) => _routePage(
                context,
                state,
                (context, state) =>
                    TvLibraryPage(viewId: state.pathParameters['viewId']!),
                environment,
              ),
            ),
            GoRoute(
              path: '/server/:serverId/library/:viewId',
              pageBuilder: (context, state) => _routePage(
                context,
                state,
                (context, state) => ServerLibraryPage(
                  serverId: state.pathParameters['serverId']!,
                  viewId: state.pathParameters['viewId']!,
                ),
                environment,
              ),
            ),
            GoRoute(
              path: '/server/:serverId/resume',
              pageBuilder: (context, state) => _routePage(
                context,
                state,
                (context, state) => ServerResumePage(
                  serverId: state.pathParameters['serverId']!,
                  source: state.uri.queryParameters['section'] == 'favorites'
                      ? 'favorites'
                      : 'resume',
                ),
                environment,
              ),
            ),
            GoRoute(
              path: '/shelf/:source',
              pageBuilder: (context, state) => _routePage(
                context,
                state,
                (context, state) => _shelfPage(auth, state, environment),
                environment,
              ),
            ),
            GoRoute(
              path: '/person/:personId',
              pageBuilder: (context, state) => _routePage(
                context,
                state,
                (context, state) => _personWorks(state),
                environment,
              ),
            ),
            GoRoute(
              path: '/item/:itemId',
              pageBuilder: (context, state) => _routePage(
                context,
                state,
                (context, state) => _sourceDetail(
                  auth,
                  state,
                  TvDetailPage(
                    key: ValueKey(state.uri.toString()),
                    itemId: state.pathParameters['itemId']!,
                    initialSeasonId: state.uri.queryParameters['season'],
                    initialEpisodeId: state.uri.queryParameters['episode'],
                  ),
                ),
                environment,
              ),
            ),
            GoRoute(
              path: '/play/:itemId',
              pageBuilder: (context, state) =>
                  _routePage(context, state, (context, state) {
                    return _gatedPlayer(auth, state, environment);
                  }, environment),
            ),
          ],
          pageBuilder: (context, state, child) => _shellPage(
            context,
            state,
            child,
            (context, state, child) => CatalogShell(auth: auth, child: child),
          ),
        ),
      ],
      if (environment.isDesktop)
        ShellRoute(
          observers: [_ConnectFlowObserver(auth)],
          routes: [
            GoRoute(
              path: AppRoutes.connect,
              pageBuilder: (context, state) =>
                  _desktopPage(state, const ConnectPage()),
            ),
            GoRoute(
              path: AppRoutes.home,
              pageBuilder: (context, state) =>
                  _desktopPage(state, const HomePage()),
            ),
            GoRoute(
              path: '/servers',
              pageBuilder: (context, state) => _desktopPage(
                state,
                ServerSelectionPage(
                  auth: auth,
                  routePage: true,
                  phone: !environment.isDesktop,
                ),
              ),
            ),
            GoRoute(
              path: '/library/:viewId',
              pageBuilder: (context, state) => _desktopPage(
                state,
                LibraryPage(viewId: state.pathParameters['viewId'] ?? ''),
              ),
            ),
            GoRoute(
              path: '/server/:serverId/library/:viewId',
              pageBuilder: (context, state) => _desktopPage(
                state,
                ServerLibraryPage(
                  serverId: state.pathParameters['serverId']!,
                  viewId: state.pathParameters['viewId']!,
                ),
              ),
            ),
            GoRoute(
              path: '/server/:serverId/resume',
              pageBuilder: (context, state) => _desktopPage(
                state,
                ServerResumePage(
                  serverId: state.pathParameters['serverId']!,
                  source: state.uri.queryParameters['section'] == 'favorites'
                      ? 'favorites'
                      : 'resume',
                ),
              ),
            ),
            GoRoute(
              path: '/shelf/:source',
              pageBuilder: (context, state) =>
                  _desktopPage(state, _shelfPage(auth, state, environment)),
            ),
            GoRoute(
              path: '/person/:personId',
              pageBuilder: (context, state) =>
                  _desktopPage(state, _personWorks(state)),
            ),
            GoRoute(
              path: '/item/:itemId',
              pageBuilder: (context, state) => _desktopPage(
                state,
                _sourceDetail(
                  auth,
                  state,
                  ItemDetailPage(
                    itemId: state.pathParameters['itemId'] ?? '',
                    initialSeasonId: state.uri.queryParameters['season'],
                  ),
                ),
              ),
            ),
            GoRoute(
              path: AppRoutes.aggregation,
              pageBuilder: (context, state) =>
                  _desktopPage(state, const AggregationPage()),
            ),
            GoRoute(
              path: AppRoutes.search,
              pageBuilder: (context, state) =>
                  _desktopPage(state, const AggregationPage(search: true)),
            ),
            GoRoute(
              path: AppRoutes.settings,
              pageBuilder: (context, state) => _desktopPage(
                state,
                SettingsPage(
                  settingsStore: PlayerScope.of(context).settingsStore,
                ),
              ),
            ),
          ],
          pageBuilder: (context, state, child) =>
              _shellPage(context, state, child, (context, state, child) {
                return CatalogShell(
                  auth: auth,
                  child: AppShell(child: child),
                );
              }),
        ),
    ],
  );
  return router;
}

Widget _shelfPage(
  AuthController auth,
  GoRouterState state,
  PresentationEnvironment environment,
) {
  final command = state.extra is PlayerHostOpenItemCommand
      ? state.extra as PlayerHostOpenItemCommand
      : null;
  if (command == null || command.source == null) {
    if (!environment.isDesktop && !environment.isTv) {
      return PhoneShelfPage.fromState(state);
    }
    if (environment.isTv) {
      final source = state.pathParameters['source'] ?? '';
      if (TvShelfPage.handles(source)) return TvShelfPage.fromState(state);
      return TvLibraryPage(
        viewId: state.uri.queryParameters['parentId'] ?? '',
        initialGenre: state.uri.queryParameters['genre'],
        initialType: state.uri.queryParameters['includeItemTypes'],
      );
    }
    return ShelfGridPage.fromState(state);
  }
  final child = Builder(
    builder: (context) {
      final origin = DetailSourceScope.maybeOf(context)!;
      return ShelfClientOverride(
        client: origin.client,
        child: ShelfItemOpen(
          onOpen: (item) => openServerItem(
            context,
            account: origin.source.account,
            item: item,
          ),
          child: environment.isTv
              ? TvShelfPage.fromState(
                  state,
                  client: origin.client,
                  onOpen: (item) => openServerItem(
                    context,
                    account: origin.source.account,
                    item: item,
                  ),
                )
              : environment.isDesktop
              ? ShelfGridPage.fromState(state)
              : PhoneShelfPage.fromState(state),
        ),
      );
    },
  );
  return SourceDetailGate(
    key: ValueKey((
      state.uri.toString(),
      command.source,
      command.accessGeneration,
    )),
    auth: auth,
    itemId: command.itemId,
    command: command,
    showComparison: false,
    child: child,
  );
}

Widget _personWorks(GoRouterState state) {
  final personId = state.pathParameters['personId'] ?? '';
  final name = state.uri.queryParameters['name'] ?? '';
  final page = PersonWorksPage(
    key: ValueKey(state.uri.toString()),
    personId: personId,
    name: name,
  );
  final command = state.extra is PlayerHostOpenItemCommand
      ? state.extra as PlayerHostOpenItemCommand
      : null;
  final source = command?.source;
  if (source == null) return page;
  return Builder(
    builder: (context) => SourceDetailGate(
      key: ValueKey((state.uri.toString(), source, command?.accessGeneration)),
      auth: AuthScope.of(context),
      itemId: command!.itemId,
      command: command,
      showComparison: false,
      child: page,
    ),
  );
}

Widget _gatedPlayer(
  AuthController auth,
  GoRouterState state,
  PresentationEnvironment environment,
) {
  final initial = state.extra is PlayerOpenRequest
      ? state.extra as PlayerOpenRequest
      : null;
  final serverId =
      initial?.source?.account.configuredServerId ?? auth.session?.server.id;
  if (serverId == null) {
    return ServerSelectionPage(
      auth: auth,
      routePage: true,
      phone: !environment.isDesktop,
    );
  }
  return Builder(
    builder: (context) {
      final runtime = PlayerScope.of(context).runtime;
      final router = GoRouter.of(context);
      bool activeContentAllowed() =>
          runtime?.mountedPlayerOrigin(state.pageKey)?.permit.isValid == true;
      void exitRevokedPlayer() {
        if (router.state.pageKey == state.pageKey &&
            router.state.uri.path.startsWith('/play/') &&
            !activeContentAllowed()) {
          router.go(AppRoutes.home, extra: null);
        }
      }

      // Once mounted, a confirmed manual source switch owns the player's
      // authority. Its immutable startup extra must not evict that new lease.
      if (!activeContentAllowed() &&
          (initial?.source != null || initial?.accessGeneration != null) &&
          auth.serverAccess.isProtected(serverId) &&
          initial?.accessGeneration != auth.serverAccess.generation(serverId)) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => exitRevokedPlayer(),
        );
        return Center(
          child: Text(
            AppLocalizations.of(context).aggregationUnavailableDetail,
          ),
        );
      }
      return ServerContentGate(
        auth: auth,
        serverId: serverId,
        activeContentAllowed: activeContentAllowed,
        onAccessRevoked: exitRevokedPlayer,
        builder: (generation) {
          final request = initial?.source != null
              ? initial
              : (initial ??
                        PlayerOpenRequest(
                          itemId: state.pathParameters['itemId']!,
                        ))
                    .withAccessGeneration(generation);
          if (environment.isTv) {
            return TvPlayerPage(
              routeLeaseKey: state.pageKey,
              sourceRequest: request,
              itemId: state.pathParameters['itemId']!,
              mediaSourceId: request?.mediaSourceId,
              autoResume: request?.autoResume ?? true,
            );
          }
          return MobilePlayerPage(
            routeLeaseKey: state.pageKey,
            sourceRequest: request,
            itemId: state.pathParameters['itemId']!,
            mediaSourceId: request?.mediaSourceId,
            autoResume: request?.autoResume ?? true,
            audioStreamIndex: request?.audioStreamIndex,
            subtitleStreamIndex: request?.subtitleStreamIndex,
            secondarySubtitleStreamIndex: request?.secondarySubtitleStreamIndex,
          );
        },
      );
    },
  );
}

Widget _sourceDetail(AuthController auth, GoRouterState state, Widget child) {
  final command = state.extra is PlayerHostOpenItemCommand
      ? state.extra as PlayerHostOpenItemCommand
      : null;
  return SourceDetailGate(
    key: ValueKey((
      state.uri.toString(),
      command?.source,
      command?.accessGeneration,
    )),
    auth: auth,
    itemId: state.pathParameters['itemId']!,
    command: command,
    showComparison: state.uri.queryParameters['showComparison'] != '0',
    child: child,
  );
}

// Desktop navigation replaces the page directly. Mobile-style full-page
// fade/zoom transitions composite two poster trees on every animation frame,
// competing with scrolling and image uploads on shared-memory GPUs.
NoTransitionPage<void> _desktopPage(GoRouterState state, Widget child) =>
    NoTransitionPage<void>(
      key: state.pageKey,
      name: state.name ?? state.matchedLocation,
      arguments: state.extra,
      child: DesktopScrollScope(child: child),
    );

/// Navigator removals end a connection flow; refreshes and widget rebuilds do not.
class _ConnectFlowObserver extends NavigatorObserver {
  _ConnectFlowObserver(this.auth);

  final AuthController auth;

  void _endFlow(Route<dynamic> route) {
    if (route.settings.name == AppRoutes.connect) {
      auth.connectDraft = null;
    }
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _endFlow(route);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _endFlow(route);
  }
}

// go_router 16 detects the bundled CupertinoApp by exact type. Explicit pages
// retain route identity and transitions with the standalone design library.
Page<void> _routePage(
  BuildContext context,
  GoRouterState state,
  Widget Function(BuildContext, GoRouterState) builder,
  PresentationEnvironment environment,
) => environment.isDesktop || environment.isTv
    ? _desktopPage(state, builder(context, state))
    : PhoneMotion.fadeThroughPage(
        context: context,
        state: state,
        child: builder(context, state),
      );
Page<void> _shellPage(
  BuildContext context,
  GoRouterState state,
  Widget child,
  Widget Function(BuildContext, GoRouterState, Widget) builder,
) => NoTransitionPage<void>(
  key: state.pageKey,
  name: state.name,
  child: builder(context, state, child),
);
