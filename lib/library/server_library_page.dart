import '../auth/server_content_entry.dart';

import 'package:rillight/app/ui/ui.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/aggregation/identity/media_identity.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/presentation_environment.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/tv_widgets.dart';
import 'package:rillight/app/widgets/app_error_view.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/auth/source_sessions.dart';
import 'package:rillight/media_server/media_server_client.dart';
import 'package:rillight/media_server/errors.dart';
import 'package:rillight/home/catalog_failure.dart';
import 'package:rillight/home/tv_shelf_page.dart';
import 'package:rillight/library/detail_source_scope.dart';
import 'package:rillight/library/shelf_grid_page.dart';
import 'package:rillight/player/player_host_command.dart';
import 'package:rillight/search/search_action.dart';

/// 先进入海报所属服务器，再带着原账号身份打开详情。
Future<void> openServerItem(
  BuildContext context, {
  required SourceAccount account,
  required MediaItem item,
}) async {
  final auth = AuthScope.of(context);
  if (!await enterServerContent(context, auth, account.configuredServerId) ||
      !context.mounted) {
    return;
  }
  final overlay = SearchOverlayController.maybeOf(context);
  final registry = AuthScope.of(context).sources;
  final source = SourceReference(account: account, itemId: item.id);
  final location = _serverItemLocation(item.id);
  try {
    // Resume/search projections may carry a virtual or stale ParentId.
    final sessionPermit = registry.permit(account);
    final concrete = await sessionPermit.dispatch((c) => c.getItem(item.id));
    sessionPermit.requireValid();
    if (!context.mounted) return;
    if (concrete.id != item.id) throw StateError('Source item mismatch');
    final libraryId = concrete.hierarchyParentId ?? concrete.id;
    final permit = _openPermit(registry, account, libraryId);
    final router = GoRouter.of(context);
    overlay?.close();
    router.push(
      location,
      extra: PlayerHostOpenItemCommand(
        itemId: item.id,
        source: source,
        libraryId: libraryId,
        accessGeneration: permit.accessGeneration,
      ),
    );
  } catch (_) {
    if (!context.mounted) return;
    int? generation;
    try {
      generation = registry.permit(account).accessGeneration;
    } catch (_) {
      // No live session: the route gate keeps a sourced page from opening.
    }
    final router = GoRouter.of(context);
    overlay?.close();
    router.push(
      location,
      extra: PlayerHostOpenItemCommand(
        itemId: item.id,
        source: source,
        accessGeneration: generation,
      ),
    );
  }
}

/// 聚合和搜索进入实际来源的详情；详情提供独立的手动来源选择。
String _serverItemLocation(String itemId) => AppRoutes.item(itemId);

OperationPermit _openPermit(
  SourceSessionRegistry registry,
  SourceAccount account,
  String libraryId,
) {
  try {
    return registry.permit(account, libraryId: libraryId);
  } on StateError {
    return registry.permit(account, libraryId: libraryId);
  }
}

/// 其他服务器的电影/剧集库。沿用现有片库网格，会话来自该服务器本身。
class ServerLibraryPage extends StatelessWidget {
  const ServerLibraryPage({
    super.key,
    required this.serverId,
    required this.viewId,
  });
  final String serverId;
  final String viewId;
  @override
  Widget build(BuildContext context) => ServerContentGate(
    key: ValueKey((serverId, viewId)),
    auth: AuthScope.of(context),
    serverId: serverId,
    builder: (_) =>
        _AuthorizedServerLibraryPage(serverId: serverId, viewId: viewId),
  );
}

class _AuthorizedServerLibraryPage extends StatefulWidget {
  const _AuthorizedServerLibraryPage({
    required this.serverId,
    required this.viewId,
  });

  final String serverId;
  final String viewId;

  @override
  State<_AuthorizedServerLibraryPage> createState() =>
      _ServerLibraryPageState();
}

class _ServerLibraryPageState extends State<_AuthorizedServerLibraryPage> {
  MediaServerClient? _client;
  SourceAccount? _account;
  String _title = '';
  String _includeItemTypes = 'Movie,Series';
  MediaServerException? _error;
  bool _loading = true;
  bool _started = false;
  int _attempt = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _load();
  }

  Future<void> _load() async {
    final attempt = ++_attempt;
    final serverId = widget.serverId;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final session = await AuthScope.of(context).sources
          .authenticate(serverId);
      if (!mounted || attempt != _attempt) return;
      final permit = AuthScope.of(context).sources.permit(session.account);
      final views = await permit.dispatch((client) => client.getViews());
      if (!mounted || attempt != _attempt) return;
      MediaItem? view;
      for (final item in views) {
        if (item.id == widget.viewId) {
          view = item;
          break;
        }
      }
      setState(() {
        _client = session.client.withRequestGuard(permit.requireValid);
        _account = session.account;
        _title = view?.name ?? '';
        _includeItemTypes = switch (view?.collectionTypeNormalized) {
          'movies' => 'Movie',
          'tvshows' => 'Series',
          _ => 'Movie,Series',
        };
        _loading = false;
      });
    } catch (error) {
      if (!mounted || attempt != _attempt) return;
      setState(() {
        _loading = false;
        _error = error is MediaServerException
            ? error
            : MediaServerException(
                MediaServerFailureKind.unknown,
                cause: error,
              );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final client = _client;
    final account = _account;
    final tv = PresentationScope.of(context).isTv;
    if (_loading || client == null || account == null) {
      if (tv) return _tvPending(context, _title, _error, _load);
      if (_error != null) {
        return CupertinoPageScaffold(
          child: AppErrorView(
            message: catalogFailureMessage(
              AppLocalizations.of(context),
              _error!,
            ),
            onRetry: _load,
          ),
        );
      }
      return const CupertinoPageScaffold(
        child: Center(child: CupertinoActivityIndicator()),
      );
    }
    if (tv) {
      return scopeServerPosters(
        account: account,
        serverId: widget.serverId,
        libraryId: widget.viewId,
        child: TvShelfPage(
          key: ValueKey((widget.serverId, widget.viewId)),
          source: 'items',
          recursive: true,
          title: _title,
          client: client,
          parentId: widget.viewId,
          includeItemTypes: _includeItemTypes,
          onOpen: (item) =>
              openServerItem(context, account: account, item: item),
        ),
      );
    }
    return CupertinoPageScaffold(
      child: scopeServerPosters(
        account: account,
        serverId: widget.serverId,
        libraryId: widget.viewId,
        child: ShelfClientOverride(
          client: client,
          child: ShelfItemOpen(
            onOpen: (item) =>
                openServerItem(context, account: account, item: item),
            child: ShelfGridPage(
              key: ValueKey((widget.serverId, widget.viewId)),
              source: 'items',
              parentId: widget.viewId,
              includeItemTypes: _includeItemTypes,
              recursive: true,
              title: _title,
              showTitle: true,
            ),
          ),
        ),
      ),
    );
  }
}

/// 某一台服务器的继续观看。网格、排序和「更多」之后的加载与首页货架相同，
/// 会话用这台服务器自己的，不切换当前首页。
class ServerResumePage extends StatelessWidget {
  const ServerResumePage({
    super.key,
    required this.serverId,
    this.source = 'resume',
  });
  final String serverId;
  final String source;
  @override
  Widget build(BuildContext context) => ServerContentGate(
    key: ValueKey((serverId, source)),
    auth: AuthScope.of(context),
    serverId: serverId,
    builder: (_) =>
        _AuthorizedServerResumePage(serverId: serverId, source: source),
  );
}

class _AuthorizedServerResumePage extends StatefulWidget {
  const _AuthorizedServerResumePage({
    required this.serverId,
    required this.source,
  });

  final String serverId;
  final String source;

  @override
  State<_AuthorizedServerResumePage> createState() => _ServerResumePageState();
}

class _ServerResumePageState extends State<_AuthorizedServerResumePage> {
  MediaServerClient? _client;
  SourceAccount? _account;
  MediaServerException? _error;
  bool _loading = true;
  bool _started = false;
  int _attempt = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _load();
  }

  Future<void> _load() async {
    final attempt = ++_attempt;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final session = await AuthScope.of(context).sources
          .authenticate(widget.serverId);
      if (!mounted || attempt != _attempt) return;
      final permit = AuthScope.of(context).sources.permit(session.account);
      setState(() {
        _client = session.client.withRequestGuard(permit.requireValid);
        _account = session.account;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || attempt != _attempt) return;
      setState(() {
        _loading = false;
        _error = error is MediaServerException
            ? error
            : MediaServerException(
                MediaServerFailureKind.unknown,
                cause: error,
              );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final client = _client;
    final account = _account;
    final tv = PresentationScope.of(context).isTv;
    if (_loading || client == null || account == null) {
      if (tv) {
        return _tvPending(
          context,
          widget.source == 'favorites'
              ? AppLocalizations.of(context).filterFavorite
              : AppLocalizations.of(context).resumeRow,
          _error,
          _load,
        );
      }
      if (_error != null) {
        return CupertinoPageScaffold(
          child: AppErrorView(
            message: catalogFailureMessage(
              AppLocalizations.of(context),
              _error!,
            ),
            onRetry: _load,
          ),
        );
      }
      return const CupertinoPageScaffold(
        child: Center(child: CupertinoActivityIndicator()),
      );
    }
    if (tv) {
      return scopeServerPosters(
        account: account,
        serverId: widget.serverId,
        child: TvShelfPage(
          source: widget.source,
          client: client,
          onOpen: (item) =>
              openServerItem(context, account: account, item: item),
        ),
      );
    }
    return CupertinoPageScaffold(
      child: scopeServerPosters(
        account: account,
        serverId: widget.serverId,
        child: ShelfClientOverride(
          client: client,
          child: ShelfItemOpen(
            onOpen: (item) =>
                openServerItem(context, account: account, item: item),
            child: ShelfGridPage(source: widget.source),
          ),
        ),
      ),
    );
  }
}

/// 电视:会话建立前的等待与失败,同样用电视页框。
Widget _tvPending(
  BuildContext context,
  String title,
  MediaServerException? error,
  VoidCallback retry,
) {
  final padding = TvFrame.contentPadding(context);
  return TvFrame(
    title: title,
    child: error == null
        ? const Center(child: CupertinoActivityIndicator())
        : Padding(
            padding: EdgeInsets.symmetric(horizontal: padding.left),
            child: Align(
              alignment: Alignment.topLeft,
              child: TvFailure(error: error, retry: retry),
            ),
          ),
  );
}
