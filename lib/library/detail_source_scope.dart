import 'dart:async';

import 'package:rillight/app/ui/ui.dart';
import 'package:go_router/go_router.dart';

import '../app/presentation_environment.dart';
import '../app/routes.dart';
import 'aggregation_page.dart';
import '../app/l10n/app_localizations.dart';

import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/auth/source_sessions.dart';
import 'package:rillight/media_server/media_server_client.dart';
import 'package:rillight/emby/catalog_cache.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/media_image/media_image.dart';
import 'package:rillight/player/playback_runtime.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/player/player_host_command.dart';
import 'package:rillight/player/player_window_host.dart';
import 'package:rillight/aggregation/identity/media_identity.dart';

import 'local_session_permit.dart';

export 'local_session_permit.dart';

/// A detail subtree owns a source lease, never another authentication authority.
class DetailSourceScope extends InheritedWidget {
  const DetailSourceScope({
    super.key,
    required this.origin,
    required this.cache,
    required this.imagePolicy,
    this.hasLibraryBoundary = true,
    required super.child,
  });
  final PlaybackOrigin origin;
  final CatalogCache cache;
  final MediaImageSourcePolicy imagePolicy;
  final bool hasLibraryBoundary;
  static MediaImageSourcePolicy? imagePolicyOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<DetailSourceScope>()
      ?.imagePolicy;
  static CatalogCache cacheOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DetailSourceScope>()?.cache ??
      CatalogScope.of(context).cache;
  @override
  bool updateShouldNotify(DetailSourceScope oldWidget) =>
      origin != oldWidget.origin ||
      hasLibraryBoundary != oldWidget.hasLibraryBoundary;
  static PlaybackOrigin? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DetailSourceScope>()?.origin;
  static MediaServerClient clientOf(BuildContext context) {
    final origin = maybeOf(context);
    origin?.permit.requireValid();
    return origin?.client ?? AuthScope.of(context).client;
  }

  /// Image-only server shelves have no library boundary. Resolve the concrete
  /// item instead of treating their image-cache namespace as a library.
  static Future<PlayerOpenRequest> playbackRequest(
    BuildContext context,
    String itemId,
  ) async {
    final scope = context
        .dependOnInheritedWidgetOfExactType<DetailSourceScope>();
    if (scope == null) return PlayerOpenRequest(itemId: itemId);
    final origin = scope.origin;
    origin.permit.requireValid();
    var libraryId = origin.libraryId;
    // 更多类似、演职员作品等不是当前条目。用它们自己的父级，
    // 不要拿当前剧的库 id 去做成员校验。
    final otherItem =
        itemId != origin.source.itemId && itemId != origin.work.itemId;
    if (!scope.hasLibraryBoundary || otherItem) {
      final item = await origin.permit.dispatch((c) => c.getItem(itemId));
      if (item.id != itemId) {
        throw StateError('Source item mismatch');
      }
      libraryId = item.hierarchyParentId ?? item.id;
    }
    origin.permit.requireValid();
    return PlayerOpenRequest(
      itemId: itemId,
      source: SourceReference(account: origin.source.account, itemId: itemId),
      libraryId: libraryId,
      regionGeneration: origin.permit.regionGeneration,
    );
  }

  static PlayerHostOpenItemCommand? command(
    BuildContext context,
    String id, {
    String? seasonId,
  }) {
    final origin = maybeOf(context);
    if (origin == null) return null;
    origin.permit.requireValid();
    final sameWork = id == origin.source.itemId || id == origin.work.itemId;
    return PlayerHostOpenItemCommand(
      itemId: id,
      seasonId: seasonId,
      source: SourceReference(account: origin.source.account, itemId: id),
      libraryId: sameWork ? origin.libraryId : null,
      regionGeneration: origin.permit.regionGeneration,
    );
  }

  /// 聚合或搜索入口写入 showComparison=0 后，后续 /item 继续带上该查询。
  static String itemLocation(
    BuildContext context,
    String itemId, {
    String? seasonId,
    String? episodeId,
  }) {
    final hideComparison =
        GoRouterState.of(context).uri.queryParameters['showComparison'] == '0';
    return AppRoutes.item(
      itemId,
      seasonId: seasonId,
      episodeId: episodeId,
      showComparison: !hideComparison,
    );
  }
}

class SourceDetailGate extends StatefulWidget {
  const SourceDetailGate({
    super.key,
    required this.auth,
    required this.itemId,
    required this.command,
    required this.child,
    this.showComparison = true,
  });
  final bool showComparison;
  final AuthController auth;
  final String itemId;
  final PlayerHostOpenItemCommand? command;
  final Widget child;
  @override
  State<SourceDetailGate> createState() => _SourceDetailGateState();
}

class _SourceDetailGateState extends State<SourceDetailGate> {
  PlaybackOrigin? _origin;
  MediaImageSourcePolicy? _imagePolicy;
  bool _resolved = false;
  Object get _authIdentity => (
    widget.auth.session?.server.id,
    widget.auth.client.baseUrl,
    widget.auth.client.userId,
    widget.auth.client.accessToken,
  );
  bool get _selectedEntry => widget.command?.source == null;

  // Sessionless source-local cache: no writes into selected Auth's namespace,
  // and no persistent private detail projection surviving revocation.
  final _cache = CatalogCache();
  @override
  void initState() {
    super.initState();
    widget.auth.addListener(_changed);
    widget.auth.sources.addSourceRevocation(_revoked);
    widget.auth.regionAccess.addListener(_changed);
    _resolve();
  }

  Future<void> _resolve() async {
    final command = widget.command;
    try {
      if (_selectedEntry) {
        // Ordinary catalog navigation uses the selected login. Aggregation
        // participation is not permission to browse that server directly.
        return;
      }
      if (command == null ||
          command.source == null ||
          command.itemId != widget.itemId ||
          command.source!.itemId != widget.itemId) {
        return;
      }
      final account = command.source!.account;
      // 普通区只要求当前会话仍有效。私有区代数不对时停在这里，不取条目。
      if (!localSessionAllowsRoute(
        widget.auth.sources,
        account,
        libraryId: command.libraryId,
        regionGeneration: command.regionGeneration,
      )) {
        return;
      }
      final permit = _permitFor(command);
      if (permit == null) return;
      permit.requireValid();
      final item = await permit.dispatch((c) => c.getItem(widget.itemId));
      if (item.id != widget.itemId) return;
      final libraryId = await _libraryFor(permit, item, command.libraryId);
      if (libraryId == null) return;
      final client = await permit.dispatch(
        (c) async => c.withRequestGuard(permit.requireValid),
      );
      permit.requireValid();
      if (!mounted) return;
      _origin = PlaybackOrigin(
        source: command.source!,
        work: command.source!,
        libraryId: libraryId,
        permit: permit,
        client: client,
      );
      _imagePolicy = MediaImageSourcePolicy(_origin!);
    } catch (_) {
      // A denied or failed source never falls back to selected Auth.
    } finally {
      if (mounted) setState(() => _resolved = true);
    }
  }

  /// 当前剧的库 id 能沿父级走到时继续用它。更多类似往往不在那条链上，
  /// 这时改用本条自己的父级，仍然只走这台服务器的会话。
  Future<String?> _libraryFor(
    OperationPermit permit,
    MediaItem item,
    String? claimedLibraryId,
  ) async {
    Future<bool> reaches(String libraryId) async {
      var cursor = item;
      final visited = <String>{};
      while (cursor.id != libraryId) {
        if (!visited.add(cursor.id) ||
            cursor.hierarchyParentId == null ||
            visited.length > 32) {
          return false;
        }
        cursor = await permit.dispatch(
          (c) => c.getItem(cursor.hierarchyParentId!),
        );
      }
      return true;
    }

    final claimed = claimedLibraryId?.trim() ?? '';
    if (claimed.isNotEmpty && await reaches(claimed)) return claimed;
    final own = item.hierarchyParentId ?? item.id;
    if (await reaches(own)) return own;
    return null;
  }

  void _revoked(String serverId) {
    if (_origin?.source.account.configuredServerId == serverId) {
      _imagePolicy?.revoke();
      _origin = null;
      _changed();
    }
  }

  void _changed() {
    if (_imagePolicy?.isValid == false) _imagePolicy?.revoke();
    final command = widget.command;
    final account = command?.source?.account;
    if (mounted && command != null && account != null) {
      // 与 _resolve 相同：范围许可失败时，仍有效的 sessionOnly 许可继续视为有效。
      final valid = _permitStillAllows(command);
      if (!valid) {
        final desktop =
            context
                .getInheritedWidgetOfExactType<PresentationScope>()
                ?.environment
                .isDesktop ??
            true;
        // Replace the whole deep stack and clear route extras, not just pixels.
        final router = GoRouter.maybeOf(context);
        final revokedUri = router?.routerDelegate.currentConfiguration.uri;
        final runtime = context
            .getInheritedWidgetOfExactType<PlayerScope>()
            ?.bindings
            .runtime;
        // Redact the invalid lease immediately in build, then replace history
        // after that frame. Mutating the Navigator while source revocation
        // is notifying its mounted subtree races its render/semantics teardown.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          // Overlay revocation can pop this detail before the frame completes.
          // The invalid deep stack still must be replaced, even if its gate
          // has already unmounted; otherwise unlocking restores private data.
          if (router == null) return;
          final current = router.routerDelegate.currentConfiguration;
          // Imperative push keeps the base URI/extra on currentConfiguration;
          // the top player's lease lives in its own match instead.
          final topExtra = router.state.extra;
          if (router.state.uri.path.startsWith('/play/') &&
              topExtra is PlayerOpenRequest &&
              runtime
                      ?.mountedPlayerOrigin(router.state.pageKey)
                      ?.permit
                      .isValid ==
                  true) {
            // This covered detail's startup source can have been replaced by
            // an explicit manual switch. It cannot clear the actual lease.
            return;
          }
          final topSource = switch (topExtra) {
            PlayerHostOpenItemCommand(:final source) => source,
            PlayerOpenRequest(:final source) => source,
            _ => null,
          };
          if (topSource != null && topSource.account != account) {
            return;
          }
          // go() publishes intent before its async parser updates the delegate.
          // Protect that intent too, not only the previously committed stack.
          final information = router.routeInformationProvider.value;
          final informationState = information.state;
          final extra = informationState is RouteInformationState
              ? informationState.extra
              : current.extra;
          final currentSource = switch (extra) {
            PlayerHostOpenItemCommand(:final source) => source,
            PlayerOpenRequest(:final source) => source,
            _ => null,
          };
          // A covered detail owns only its revoked source, not a newer route
          // or an independently authorized player on top of it. An overlay
          // pop may already have returned to the anonymous private root;
          // that old deep stack still needs clearing after the gate unmounts.
          if (currentSource != null && currentSource.account != account) {
            return;
          }
          if (currentSource == null &&
              information.uri != revokedUri &&
              information.uri.path != '/private') {
            return;
          }
          router.go(desktop ? '/aggregation' : '/', extra: null);
        });
      }
    }
    if (mounted) setState(() {});
  }

  /// 范围未勾选时改用 sessionOnly。打开详情和之后的有效性检查都走这里。
  OperationPermit? _permitFor(PlayerHostOpenItemCommand command) {
    final account = command.source?.account;
    if (account == null) return null;
    return permitForAccount(
      widget.auth.sources,
      account,
      libraryId: command.libraryId,
    );
  }

  bool _permitStillAllows(PlayerHostOpenItemCommand command) {
    final account = command.source?.account;
    if (account == null) return false;
    return localSessionAllowsRoute(
      widget.auth.sources,
      account,
      libraryId: command.libraryId,
      regionGeneration: command.regionGeneration,
    );
  }

  @override
  void dispose() {
    // No gate may leave private bytes behind without a revocation listener.
    if (_imagePolicy?.allowsDisk == false) _imagePolicy?.revoke();
    widget.auth.removeListener(_changed);
    widget.auth.sources.removeSourceRevocation(_revoked);
    widget.auth.regionAccess.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final origin = _origin;
    if (_selectedEntry &&
        widget.auth.isLoggedIn &&
        widget.auth.session?.server.region == AccessRegion.ordinary &&
        (widget.command == null || widget.command!.itemId == widget.itemId)) {
      // Renewed credentials must recreate controllers holding the old client.
      // Ordinary navigation follows the selected session; explicit source
      // routes below still require their original, valid source permit.
      return KeyedSubtree(key: ValueKey(_authIdentity), child: widget.child);
    }
    if (origin == null || !origin.permit.isValid) {
      if (!_resolved) return const Center(child: CupertinoActivityIndicator());
      final l = AppLocalizations.of(context);
      return Center(
        child: Text(
          widget.command?.source?.account.region == AccessRegion.private &&
                  !widget.auth.regionAccess.allows(AccessRegion.private)
              ? l.aggregationPrivateLocked
              : l.aggregationUnavailableDetail,
        ),
      );
    }
    return DetailSourceScope(
      origin: origin,
      cache: _cache,
      imagePolicy: _imagePolicy!,
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.child,
          if (widget.showComparison)
            const Positioned(
              right: 16,
              bottom: 24,
              child: SourceComparisonAction(),
            ),
        ],
      ),
    );
  }
}

/// 在海报之前挂上该服务器会话。没有账号时保持原来的子树。
Widget scopeServerPosters({
  required SourceAccount? account,
  required String serverId,
  String? libraryId,
  required Widget child,
}) {
  if (account == null) return child;
  return ServerSessionImages(
    key: ValueKey((serverId, libraryId)),
    account: account,
    libraryId: libraryId,
    child: child,
  );
}

/// 横排和片库网格的海报请求走这台服务器的会话，缓存键带上该服务器。
class ServerSessionImages extends StatefulWidget {
  const ServerSessionImages({
    super.key,
    required this.account,
    required this.child,
    this.libraryId,
  });

  final SourceAccount account;
  final String? libraryId;
  final Widget child;

  @override
  State<ServerSessionImages> createState() => _ServerSessionImagesState();
}

class _ServerSessionImagesState extends State<ServerSessionImages> {
  final _cache = CatalogCache();
  PlaybackOrigin? _origin;
  MediaImageSourcePolicy? _imagePolicy;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _rebind(AuthScope.of(context).sources);
  }

  @override
  void didUpdateWidget(ServerSessionImages oldWidget) {
    super.didUpdateWidget(oldWidget);
    final auth = context.getInheritedWidgetOfExactType<AuthScope>()?.notifier;
    if (auth == null) return;
    _rebind(auth.sources);
  }

  void _rebind(SourceSessionRegistry registry) {
    if (_origin?.permit.isValid == true && _imagePolicy?.isValid == true) {
      return;
    }
    _bind(registry);
  }

  void _bind(SourceSessionRegistry registry) {
    final permit = permitForAccount(
      registry,
      widget.account,
      libraryId: widget.libraryId,
    );
    if (permit == null || !permit.isValid) return;
    MediaServerClient? client;
    final pending = permit.dispatch((raw) async {
      client = raw.withRequestGuard(permit.requireValid);
      return client!;
    });
    unawaited(pending.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
    if (client == null || !permit.isValid) return;
    final libraryId = widget.libraryId ?? widget.account.configuredServerId;
    final source = SourceReference(account: widget.account, itemId: libraryId);
    final origin = PlaybackOrigin(
      source: source,
      work: source,
      libraryId: libraryId,
      permit: permit,
      client: client!,
    );
    _origin = origin;
    _imagePolicy = MediaImageSourcePolicy(origin);
  }

  @override
  void dispose() {
    if (_imagePolicy?.allowsDisk == false) _imagePolicy?.revoke();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final origin = _origin;
    final policy = _imagePolicy;
    // 许可失效后仍留下范围，海报停在占位，横排标题和重试不被拆掉。
    if (origin != null && policy != null) {
      return DetailSourceScope(
        origin: origin,
        cache: _cache,
        imagePolicy: policy,
        hasLibraryBoundary: widget.libraryId != null,
        child: widget.child,
      );
    }
    // 当前首页服务器解析失败时仍用首页会话，其它服务器不回落到首页的图。
    final selected = AuthScope.maybeOf(context)?.session?.server.id;
    if (selected != null && selected == widget.account.configuredServerId) {
      return widget.child;
    }
    return const SizedBox.shrink();
  }
}
