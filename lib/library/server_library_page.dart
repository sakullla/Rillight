import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/aggregation/identity/media_identity.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/presentation_environment.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/tv_widgets.dart';
import 'package:rillight/app/widgets/app_error_view.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/auth/source_sessions.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_errors.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_failure.dart';
import 'package:rillight/home/tv_shelf_page.dart';
import 'package:rillight/library/detail_source_scope.dart';
import 'package:rillight/library/shelf_grid_page.dart';
import 'package:rillight/player/player_host_command.dart';
import 'package:rillight/search/search_action.dart';

/// 用海报所在服务器的已有会话打开详情，不切换首页当前服务器。
Future<void> openServerItem(
  BuildContext context, {
  required SourceAccount account,
  required EmbyItem item,
}) async {
  final overlay = SearchOverlayController.maybeOf(context);
  final registry = AuthScope.of(context).sources;
  final source = SourceReference(account: account, itemId: item.id);
  final location = _serverItemLocation(item.id);
  try {
    // Resume/search projections may carry a virtual or stale ParentId.
    final sessionPermit = registry.permit(account, sessionOnly: true);
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
        regionGeneration: permit.regionGeneration,
      ),
    );
  } catch (_) {
    if (!context.mounted) return;
    final router = GoRouter.of(context);
    overlay?.close();
    router.push(
      location,
      extra: PlayerHostOpenItemCommand(itemId: item.id, source: source),
    );
  }
}

/// 聚合和搜索打开的详情不进入同源比对。查询留在路由上，刷新后仍然生效。
String _serverItemLocation(String itemId) =>
    AppRoutes.item(itemId, showComparison: false);

OperationPermit _openPermit(
  SourceSessionRegistry registry,
  SourceAccount account,
  String libraryId,
) {
  try {
    return registry.permit(account, libraryId: libraryId);
  } on StateError {
    return registry.permit(account, libraryId: libraryId, sessionOnly: true);
  }
}

/// 其他服务器的电影/剧集库。沿用现有片库网格，会话来自该服务器本身。
class ServerLibraryPage extends StatefulWidget {
  const ServerLibraryPage({
    super.key,
    required this.serverId,
    required this.viewId,
  });

  final String serverId;
  final String viewId;

  @override
  State<ServerLibraryPage> createState() => _ServerLibraryPageState();
}

class _ServerLibraryPageState extends State<ServerLibraryPage> {
  EmbyClient? _client;
  SourceAccount? _account;
  String _title = '';
  String _includeItemTypes = 'Movie,Series';
  EmbyException? _error;
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
      final session = await AuthScope.of(
        context,
      ).sources.authenticate(serverId);
      if (!mounted || attempt != _attempt) return;
      final views = await session.client.getViews();
      if (!mounted || attempt != _attempt) return;
      EmbyItem? view;
      for (final item in views) {
        if (item.id == widget.viewId) {
          view = item;
          break;
        }
      }
      setState(() {
        _client = session.client;
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
        _error = error is EmbyException
            ? error
            : EmbyException(EmbyFailureKind.unknown, cause: error);
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
        return Scaffold(
          body: AppErrorView(
            message: catalogFailureMessage(
              AppLocalizations.of(context),
              _error!,
            ),
            onRetry: _load,
          ),
        );
      }
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (tv) {
      return scopeServerPosters(
        account: account,
        serverId: widget.serverId,
        libraryId: widget.viewId,
        child: TvShelfPage(
          key: ValueKey((widget.serverId, widget.viewId)),
          source: 'items',
          title: _title,
          client: client,
          parentId: widget.viewId,
          includeItemTypes: _includeItemTypes,
          onOpen: (item) =>
              openServerItem(context, account: account, item: item),
        ),
      );
    }
    return Scaffold(
      body: scopeServerPosters(
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
class ServerResumePage extends StatefulWidget {
  const ServerResumePage({super.key, required this.serverId});

  final String serverId;

  @override
  State<ServerResumePage> createState() => _ServerResumePageState();
}

class _ServerResumePageState extends State<ServerResumePage> {
  EmbyClient? _client;
  SourceAccount? _account;
  EmbyException? _error;
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
      final session = await AuthScope.of(
        context,
      ).sources.authenticate(widget.serverId);
      if (!mounted || attempt != _attempt) return;
      setState(() {
        _client = session.client;
        _account = session.account;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || attempt != _attempt) return;
      setState(() {
        _loading = false;
        _error = error is EmbyException
            ? error
            : EmbyException(EmbyFailureKind.unknown, cause: error);
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
          AppLocalizations.of(context).resumeRow,
          _error,
          _load,
        );
      }
      if (_error != null) {
        return Scaffold(
          body: AppErrorView(
            message: catalogFailureMessage(
              AppLocalizations.of(context),
              _error!,
            ),
            onRetry: _load,
          ),
        );
      }
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (tv) {
      return scopeServerPosters(
        account: account,
        serverId: widget.serverId,
        child: TvShelfPage(
          source: 'resume',
          client: client,
          onOpen: (item) =>
              openServerItem(context, account: account, item: item),
        ),
      );
    }
    return Scaffold(
      body: scopeServerPosters(
        account: account,
        serverId: widget.serverId,
        child: ShelfClientOverride(
          client: client,
          child: ShelfItemOpen(
            onOpen: (item) =>
                openServerItem(context, account: account, item: item),
            child: const ShelfGridPage(source: 'resume'),
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
  EmbyException? error,
  VoidCallback retry,
) {
  final padding = TvFrame.contentPadding(context);
  return TvFrame(
    title: title,
    child: error == null
        ? const Center(child: CircularProgressIndicator())
        : Padding(
            padding: EdgeInsets.symmetric(horizontal: padding.left),
            child: Align(
              alignment: Alignment.topLeft,
              child: TvFailure(error: error, retry: retry),
            ),
          ),
  );
}
