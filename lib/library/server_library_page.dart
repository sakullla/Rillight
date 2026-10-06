import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/aggregation/identity/media_identity.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/widgets/app_error_view.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/auth/source_sessions.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_errors.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_failure.dart';
import 'package:rillight/library/shelf_grid_page.dart';
import 'package:rillight/player/player_host_command.dart';
import 'package:rillight/search/search_action.dart';

/// 用海报所在服务器的已有会话打开详情，不切换首页当前服务器。
void openServerItem(
  BuildContext context, {
  required SourceAccount account,
  required EmbyItem item,
}) {
  SearchOverlayController.maybeOf(context)?.close();
  final registry = AuthScope.of(context).sources;
  final libraryId = item.parentId != null && item.parentId!.isNotEmpty
      ? item.parentId!
      : item.id;
  final source = SourceReference(account: account, itemId: item.id);
  try {
    final permit = _openPermit(registry, account, libraryId);
    context.push(
      AppRoutes.item(item.id),
      extra: PlayerHostOpenItemCommand(
        itemId: item.id,
        source: source,
        libraryId: libraryId,
        regionGeneration: permit.regionGeneration,
      ),
    );
  } on StateError {
    context.push(
      AppRoutes.item(item.id),
      extra: PlayerHostOpenItemCommand(itemId: item.id, source: source),
    );
  }
}

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
    if (_loading || client == null || account == null) {
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
    return Scaffold(
      body: ShelfClientOverride(
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
    );
  }
}
