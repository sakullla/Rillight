import 'dart:async';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/tv_top_nav.dart';
import 'package:rillight/app/widgets/skeleton.dart';
import 'package:rillight/app/tv_appearance_picker.dart';
import 'package:rillight/app/tv_widgets.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/auth/change_password_dialog.dart';
import 'package:rillight/auth/line_address_dialog.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/home/library_tiles.dart';
import 'package:rillight/home/tv_home_page.dart';
import 'package:rillight/player/android_session_recovery.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/search/tv_search_page.dart';

class TvShell extends StatefulWidget {
  const TvShell({super.key});
  @override
  State<TvShell> createState() => _TvShellState();
}

class _TvShellState extends State<TvShell> with WidgetsBindingObserver {
  int _index = 0;
  int _paneSelectionRevision = 0;
  bool _initialized = false, _recovering = false, _failed = false;
  final _home = FocusNode();
  final _recoveryRetry = FocusNode();
  final _navScope = FocusScopeNode(
    traversalEdgeBehavior: TraversalEdgeBehavior.parentScope,
    directionalTraversalEdgeBehavior: TraversalEdgeBehavior.parentScope,
  );
  final _panes = List.generate(
    4,
    (_) => FocusScopeNode(
      traversalEdgeBehavior: TraversalEdgeBehavior.parentScope,
      directionalTraversalEdgeBehavior: TraversalEdgeBehavior.parentScope,
    ),
  );
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_initialized) {
      _initialized = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _recover();
      });
    }
  }

  Future<void> _recover() async {
    final store = PlayerScope.of(context).snapshotStore;
    if (store == null || _recovering) return;
    final retrying = _failed;
    setState(() {
      _recovering = true;
      _failed = false;
    });
    try {
      await recoverAndroidSession(
        AuthScope.of(context).client,
        store,
        runtime: PlayerScope.of(context).runtime,
      );
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) {
        setState(() => _recovering = false);
        if (_failed || retrying) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && ModalRoute.of(context)?.isCurrent == true) {
              _enterPane(_index);
            }
          });
        }
      }
    }
  }

  void _enterPane(int index) {
    if (_recovering) return;
    // Recovery replaces the destination panes, so only target mounted content.
    if (_failed) {
      if (_recoveryRetry.context != null && _recoveryRetry.canRequestFocus) {
        _recoveryRetry.requestFocus();
      }
    } else if (_panes[index].context != null) {
      // 面板 scope 记住的上次焦点子节点优先,否则落到阅读序首个目标。
      final remembered = _panes[index].focusedChild;
      if (remembered != null &&
          remembered.context != null &&
          remembered.canRequestFocus) {
        remembered.requestFocus();
      } else {
        ReadingOrderTraversalPolicy()
            .findFirstFocus(_panes[index])
            ?.requestFocus();
      }
    }
  }

  void _selectPane(int index, {bool enter = false}) {
    final revision = ++_paneSelectionRevision;
    final changed = _index != index;
    if (changed) setState(() => _index = index);
    if (!enter) return;
    if (!changed) {
      _enterPane(index);
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          _index == index &&
          revision == _paneSelectionRevision &&
          ModalRoute.of(context)?.isCurrent == true) {
        _enterPane(index);
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      final auth = AuthScope.of(context), catalog = CatalogScope.of(context);
      unawaited(() async {
        try {
          await auth.client.getUser();
        } catch (_) {
          /* Catalog shows recovery. */
        }
        if (mounted && auth.isLoggedIn) await catalog.reload();
      }());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _home.dispose();
    _recoveryRetry.dispose();
    _navScope.dispose();
    for (final pane in _panes) {
      pane.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final auth = AuthScope.of(context);
    final horizontal = tvSafeGutter(MediaQuery.sizeOf(context).width);
    // 首页面板 hero 出血到导航栏后,不加预留;其余面板避开叠层导航。
    Widget padded(Widget pane) => Padding(
      padding: EdgeInsets.only(
        top: TvTopNavBar.reserveHeight,
        left: horizontal,
        right: horizontal,
      ),
      child: pane,
    );
    return PopScope(
      canPop: _index == 0,
      onPopInvokedWithResult: (popped, _) {
        if (!popped) {
          _selectPane(0);
          _home.requestFocus();
        }
      },
      child: TvStageTheme(
        child: TvFocusRegion(
          child: Scaffold(
            body: Stack(
              fit: StackFit.expand,
              children: [
                Positioned.fill(
                  child: SafeArea(
                    child: _recovering
                        ? const Center(child: CircularProgressIndicator())
                        : _failed
                        ? Padding(
                            padding: EdgeInsets.only(
                              top: TvTopNavBar.reserveHeight,
                              left: horizontal,
                              right: horizontal,
                            ),
                            child: Column(
                              children: [
                                Text(l.mobileRecoveryFailed),
                                TvAction(
                                  autofocus: true,
                                  focusNode: _recoveryRetry,
                                  onPressed: _recover,
                                  child: Text(l.retry),
                                ),
                                TvAction(
                                  onPressed: AuthScope.of(context).logout,
                                  child: Text(l.connect),
                                ),
                              ],
                            ),
                          )
                        : IndexedStack(
                            index: _index,
                            children: [
                              for (var i = 0; i < 4; i++)
                                ExcludeFocus(
                                  excluding: i != _index,
                                  child: TickerMode(
                                    enabled: i == _index,
                                    child: FocusScope(
                                      node: _panes[i],
                                      child: [
                                        const TvHomePage(),
                                        padded(const _TvLibraries()),
                                        padded(const TvSearchPage()),
                                        padded(const _TvSession()),
                                      ][i],
                                    ),
                                  ),
                                ),
                            ],
                          ),
                  ),
                ),
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: FocusScope(
                    node: _navScope,
                    child: TvTopNavBar(
                      index: _index,
                      onSelect: (i) => _selectPane(i),
                      onEnter: (i) => _selectPane(i, enter: true),
                      homeNode: _home,
                      username: auth.session?.username,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TvLibraries extends StatelessWidget {
  const _TvLibraries();
  @override
  Widget build(BuildContext context) {
    final c = CatalogScope.of(context), l = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) => LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth.isFinite
              ? constraints.maxWidth
              : MediaQuery.sizeOf(context).width;
          final columns = (width / 320).floor().clamp(2, 4);
          final cell = width / columns;
          // 卡片内边距(TvAction margin+padding)之外的 16:9 图区。
          const chrome = 32.0;
          final imageHeight = (cell - chrome) * 9 / 16;
          final aspect = cell / (imageHeight + chrome);
          return CustomScrollView(
            key: const PageStorageKey('tv-libraries'),
            slivers: [
              if (c.librariesLoading && c.libraries.isEmpty)
                const SliverToBoxAdapter(child: _TvLibrarySkeleton()),
              if (c.librariesError != null || c.librariesNotice != null)
                SliverToBoxAdapter(
                  child: TvFailure(
                    error: (c.librariesError ?? c.librariesNotice)!,
                    retry: c.reload,
                  ),
                ),
              if (!c.librariesLoading && c.libraries.isEmpty)
                SliverToBoxAdapter(child: Text(l.mobileEmpty)),
              SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  childAspectRatio: aspect,
                ),
                delegate: SliverChildBuilderDelegate((context, index) {
                  final library = c.libraries[index];
                  return TvAction(
                    key: ValueKey(library.id),
                    onPressed: () =>
                        context.push(AppRoutes.library(library.id)),
                    child: LayoutBuilder(
                      builder: (context, card) => LibraryCardFace(
                        library: library,
                        width: card.maxWidth,
                        height: card.maxHeight,
                      ),
                    ),
                  );
                }, childCount: c.libraries.length),
              ),
              SliverToBoxAdapter(
                child: TvAction(
                  onPressed: c.reload,
                  child: Text(l.mobileRefresh),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _TvSession extends StatelessWidget {
  const _TvSession();

  static Key serverDeleteKey(String serverId) =>
      ValueKey('tv-server-delete-$serverId');

  static const serverDeleteConfirmKey = Key('tv-server-delete-confirm');

  static const serverDeleteCancelKey = Key('tv-server-delete-cancel');

  static const changePasswordKey = Key('tv-change-password');

  /// 线路切换失败时的原因行;成功或开始新的切换后随控制器清空。
  static const lineSwitchFailureKey = Key('tv-line-switch-failure');

  static Key lineAddKey(String serverId) => ValueKey('tv-line-add-$serverId');

  static Key lineEditKey(String serverId, String lineId) =>
      ValueKey('tv-line-edit-$serverId-$lineId');

  static Key lineDeleteKey(String serverId, String lineId) =>
      ValueKey('tv-line-delete-$serverId-$lineId');

  @override
  Widget build(BuildContext context) {
    final auth = AuthScope.of(context), l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    Widget header(String title) => Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 4),
      child: Text(
        title,
        style: theme.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w700,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
    return ListenableBuilder(
      listenable: auth,
      builder: (context, _) => ListView(
        key: const PageStorageKey('tv-session'),
        children: [
          header(l.mobileAccountServerGroup),
          Text(
            '${auth.session?.server.name ?? ''} · ${auth.session?.username ?? ''}',
          ),
          // TvAppearancePicker 自带「外观」标签,作本节标题。
          const SizedBox(height: 20),
          const TvAppearancePicker(),
          header(l.mobileLine),
          if (auth.lineSwitchFailure != null) ...[
            const SizedBox(height: 8),
            Text(
              l.lineSwitchFailed(auth.lineSwitchFailure!.detail),
              key: _TvSession.lineSwitchFailureKey,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          for (final server in auth.savedServers) ...[
            for (final line in server.lines) ...[
              TvAction(
                key: ValueKey('${server.id}-${line.id}'),
                selected:
                    auth.session?.server.id == server.id &&
                    auth.session?.server.activeLine?.id == line.id,
                onPressed: auth.isBusy
                    ? null
                    : () => auth.switchTo(server.id, lineId: line.id),
                child: Text('${server.name} · ${line.hostLabel}'),
              ),
              TvAction(
                key: lineEditKey(server.id, line.id),
                onPressed: auth.isBusy
                    ? null
                    : () => _editLine(context, auth, server, line),
                child: Text('${l.editLine} · ${line.hostLabel}'),
              ),
              TvAction(
                key: lineDeleteKey(server.id, line.id),
                onPressed: auth.isBusy || server.lines.length <= 1
                    ? null
                    : () => _deleteLine(context, auth, server, line),
                child: Text('${l.deleteLine} · ${line.hostLabel}'),
              ),
            ],
            TvAction(
              key: lineAddKey(server.id),
              onPressed: auth.isBusy
                  ? null
                  : () => _addLine(context, auth, server.id),
              child: Text('${l.addLine} · ${server.name}'),
            ),
            TvAction(
              key: serverDeleteKey(server.id),
              onPressed: auth.isBusy
                  ? null
                  : () => _confirmDelete(context, auth, server),
              child: Text('${l.deleteServer} · ${server.name}'),
            ),
          ],
          header(l.tvSettingsOther),
          TvAction(
            onPressed: () => context.push('${AppRoutes.connect}?add=1'),
            child: Text(l.mobileAddServer),
          ),
          TvAction(
            key: changePasswordKey,
            onPressed: auth.isBusy
                ? null
                : () => showDialog<void>(
                    context: context,
                    builder: (dialogContext) =>
                        ChangePasswordDialog(auth: auth),
                  ),
            child: Text(l.changePassword),
          ),
          TvAction(
            onPressed: auth.isBusy ? null : auth.logout,
            child: Text(l.logout),
          ),
        ],
      ),
    );
  }

  /// 添加线路:只录地址,不改变当前线路。
  Future<void> _addLine(
    BuildContext context,
    AuthController auth,
    String serverId,
  ) async {
    final address = await showLineAddressDialog(context);
    if (address == null) {
      return;
    }
    await auth.addLine(serverId, address);
  }

  /// 修改线路地址:仅地址变化,无 UA 输入项;改的是当前线路时,
  /// 之后浏览与播放走新地址并刷新目录。
  Future<void> _editLine(
    BuildContext context,
    AuthController auth,
    SavedServer server,
    ServerLine line,
  ) async {
    final catalog = CatalogScope.maybeOf(context);
    final address = await showLineAddressDialog(
      context,
      initialAddress: line.address,
    );
    if (address == null) {
      return;
    }
    final wasActive =
        auth.session?.server.id == server.id &&
        auth.session?.server.activeLineId == line.id;
    final changed = await auth.updateLineAddress(server.id, line.id, address);
    if (changed && wasActive) {
      catalog?.reload();
    }
  }

  /// 删除线路:只剩一条时入口不可用,控制器同样兜底保留最后一条;
  /// 删除当前线路后客户端挂到剩余线路并刷新目录。
  Future<void> _deleteLine(
    BuildContext context,
    AuthController auth,
    SavedServer server,
    ServerLine line,
  ) async {
    final catalog = CatalogScope.maybeOf(context);
    final wasActive =
        auth.session?.server.id == server.id &&
        auth.session?.server.activeLineId == line.id;
    await auth.deleteLine(server.id, line.id);
    if (wasActive) {
      catalog?.reload();
    }
  }

  /// 先确认再删除;取消不改动任何内容。删除当前服务器时路由会回登录页。
  Future<void> _confirmDelete(
    BuildContext context,
    AuthController auth,
    SavedServer server,
  ) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return SimpleDialog(
          title: Text(l10n.deleteServer),
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(l10n.deleteServerConfirmMessage(server.name)),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TvAction(
                  key: serverDeleteCancelKey,
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: Text(l10n.cancelAction),
                ),
                const SizedBox(width: 12),
                TvAction(
                  key: serverDeleteConfirmKey,
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                  child: Text(l10n.deleteServerConfirm),
                ),
                const SizedBox(width: 24),
              ],
            ),
          ],
        );
      },
    );
    if (confirmed == true) {
      await auth.deleteServer(server.id);
    }
  }
}

class _TvLibrarySkeleton extends StatelessWidget {
  const _TvLibrarySkeleton();

  @override
  Widget build(BuildContext context) {
    final animate = !MediaQuery.disableAnimationsOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < 6; i++) ...[
          const SizedBox(height: 8),
          SkeletonBlock(width: 280, height: 36, animated: animate),
        ],
      ],
    );
  }
}
