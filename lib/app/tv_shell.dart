import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/app_shell.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/app/tv_top_nav.dart';

import 'package:rillight/app/tv_appearance_picker.dart';
import 'package:rillight/app/tv_widgets.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/auth/change_password_dialog.dart';
import 'package:rillight/auth/line_address_dialog.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/home/catalog_scope.dart';

import 'package:rillight/home/tv_home_page.dart';
import 'package:rillight/player/android_session_recovery.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/library/aggregation_page.dart';

class TvShell extends StatefulWidget {
  const TvShell({super.key});
  @override
  State<TvShell> createState() => _TvShellState();
}

class _TvShellState extends State<TvShell> with WidgetsBindingObserver {
  int _index = 0;
  int _paneSelectionRevision = 0;
  bool _initialized = false, _recovering = false, _failed = false;

  /// 面板内容向下滚动后收起导航;焦点回到导航时重新展开。
  bool _navHidden = false;

  /// 每个面板主滚动视图的上下文,导航重获焦点时把它滚回顶部。
  final _paneScroll = List<BuildContext?>.filled(4, null);

  /// 首页顶部是否是出血 hero(导航压在影像上)。
  final _heroVisible = ValueNotifier<bool>(true);
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
    _navScope.addListener(_navFocusChanged);
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

  void _navFocusChanged() {
    if (!_navScope.hasFocus || !mounted) return;
    if (_navHidden) setState(() => _navHidden = false);
    final scroll = _paneScroll[_index];
    if (scroll != null && scroll.mounted) {
      final position = Scrollable.maybeOf(scroll)?.position;
      if (position != null && position.pixels > 0) {
        unawaited(
          position.animateTo(
            0,
            duration: AppMotion.durationOf(context, AppMotion.slow),
            curve: AppMotion.standard,
          ),
        );
      }
    }
  }

  /// 面板内按上键已到顶(没有更上面的目标)时回到导航当前标签,
  /// 不依赖跨焦点域的方向搜索。
  KeyEventResult _paneKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey != LogicalKeyboardKey.arrowUp) {
      return KeyEventResult.ignored;
    }
    final primary = FocusManager.instance.primaryFocus;
    if (primary == null || _navScope.hasFocus) return KeyEventResult.ignored;
    if (primary.focusInDirection(TraversalDirection.up)) {
      return KeyEventResult.handled;
    }
    final remembered = _navScope.focusedChild;
    if (remembered != null && remembered.canRequestFocus) {
      remembered.requestFocus();
    } else {
      _home.requestFocus();
    }
    return KeyEventResult.handled;
  }

  bool _onPaneScroll(int pane, ScrollNotification notification) {
    if (notification.depth != 0 ||
        notification.metrics.axis != Axis.vertical ||
        pane != _index) {
      return false;
    }
    _paneScroll[pane] = notification.context;
    final hide = notification.metrics.pixels > 4 && !_navScope.hasFocus;
    if (hide != _navHidden) _setNavHidden(hide);
    return false;
  }

  /// Viewport layout can emit a scroll-start notification while applying new
  /// content dimensions. setState in that phase schedules a build mid-frame.
  void _setNavHidden(bool hide) {
    void apply() {
      if (mounted && hide != _navHidden) {
        setState(() => _navHidden = hide);
      }
    }

    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => apply());
      return;
    }
    apply();
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
        // Prefer registered remote controls rather than the scroll view's
        // generic focus node, which TvFocusRegion cannot retain as a target.
        final controls = _panes[index].traversalDescendants.where(
          (node) =>
              node.context?.findAncestorWidgetOfExactType<TvAction>() != null,
        );
        if (controls.isNotEmpty) {
          controls.first.requestFocus();
        } else {
          ReadingOrderTraversalPolicy()
              .findFirstFocus(_panes[index], ignoreCurrentFocus: true)
              ?.requestFocus();
        }
      }
    }
  }

  void _selectPane(int index, {bool enter = false}) {
    final revision = ++_paneSelectionRevision;
    final changed = _index != index;
    if (changed) {
      setState(() {
        _index = index;
        _navHidden = false;
      });
    }
    if (!enter) return;
    // Nav focus may have selected this index before its ExcludeFocus subtree
    // rebuilds. Enter only after that frame, including an unchanged index.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          _index == index &&
          revision == _paneSelectionRevision &&
          ModalRoute.of(context)?.isCurrent == true) {
        _enterPane(index);
      }
    });
    // Selecting the already focused tab need not rebuild. Its deferred enter
    // must still get a frame, including when called during another callback.
    WidgetsBinding.instance.ensureVisualUpdate();
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
    _navScope.removeListener(_navFocusChanged);
    _home.dispose();
    _recoveryRetry.dispose();
    _navScope.dispose();
    _heroVisible.dispose();
    for (final pane in _panes) {
      pane.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final auth = AuthScope.of(context);
    final s = TvDesign.scaleOf(context);
    final duration = AppMotion.durationOf(context, TvNavMotion.duration);
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
                  child: _recovering
                      ? const Center(child: CircularProgressIndicator())
                      : _failed
                      ? TvEmptyState(
                          icon: Icons.cloud_off_rounded,
                          message: l.mobileRecoveryFailed,
                          action: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              TvAction(
                                autofocus: true,
                                emphasized: true,
                                focusNode: _recoveryRetry,
                                onPressed: _recover,
                                child: Text(l.retry),
                              ),
                              SizedBox(width: 12 * s),
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
                                  child:
                                      NotificationListener<ScrollNotification>(
                                        onNotification: (n) =>
                                            _onPaneScroll(i, n),
                                        child: Focus(
                                          canRequestFocus: false,
                                          skipTraversal: true,
                                          onKeyEvent: _paneKey,
                                          child: FocusScope(
                                            node: _panes[i],
                                            child: [
                                              TvHomePage(
                                                heroVisible: _heroVisible,
                                              ),
                                              const _TvLibraries(),
                                              SearchRouteGuard(
                                                canPop: true,
                                                onPop: () {
                                                  _selectPane(0);
                                                  _home.requestFocus();
                                                },
                                                child: const AggregationPage(
                                                  search: true,
                                                ),
                                              ),
                                              const _TvSession(),
                                            ][i],
                                          ),
                                        ),
                                      ),
                                ),
                              ),
                          ],
                        ),
                ),
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: AnimatedSlide(
                    offset: Offset(0, _navHidden ? -1.2 : 0),
                    duration: duration,
                    curve: AppMotion.standard,
                    child: AnimatedOpacity(
                      opacity: _navHidden ? 0 : 1,
                      duration: duration,
                      child: FocusScope(
                        node: _navScope,
                        child: ValueListenableBuilder<bool>(
                          valueListenable: _heroVisible,
                          builder: (context, hero, _) {
                            final overImage = _index == 0 && hero;
                            final nav = TvTopNavBar(
                              index: _index,
                              onSelect: (i) => _selectPane(i),
                              onEnter: (i) => _selectPane(i, enter: true),
                              homeNode: _home,
                              username: auth.session?.username,
                              overImage: overImage,
                            );
                            return overImage ? TvDarkStage(child: nav) : nav;
                          },
                        ),
                      ),
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
    return const AggregationPage();
  }
}

/// 设置面板:左侧账户卡与账户操作,右侧外观与服务器线路。
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
    final s = TvDesign.scaleOf(context);
    final size = MediaQuery.sizeOf(context);
    final gutter = tvSafeGutter(size.width);
    return ListenableBuilder(
      listenable: auth,
      builder: (context, _) => ListView(
        key: const PageStorageKey('tv-session'),
        padding: EdgeInsets.fromLTRB(
          gutter,
          TvTopNavBar.reserveOf(context) + 8 * s,
          gutter,
          tvSafeVertical(size.height),
        ),
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 272 * s,
                child: _TvAccountCard(auth: auth),
              ),
              SizedBox(width: 36 * s),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TvSectionTitle(l.settingsAppearance),
                    SizedBox(height: 6 * s),
                    const TvAppearancePicker(),
                    SizedBox(height: TvDesign.sectionGap * s),
                    TvSectionTitle(l.mobileLine),
                    if (auth.lineSwitchFailure != null)
                      Padding(
                        padding: EdgeInsets.only(bottom: 8 * s),
                        child: Text(
                          l.lineSwitchFailed(auth.lineSwitchFailure!.detail),
                          key: _TvSession.lineSwitchFailureKey,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.error,
                          ),
                        ),
                      ),
                    for (final server in auth.savedServers) ...[
                      SizedBox(height: 6 * s),
                      _TvServerCard(auth: auth, server: server),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TvAccountCard extends StatelessWidget {
  const _TvAccountCard({required this.auth});
  final AuthController auth;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final s = TvDesign.scaleOf(context);
    final name = auth.session?.username ?? '';
    final server = auth.session?.server;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: EdgeInsets.all(18 * s),
          decoration: BoxDecoration(
            color: scheme.surfaceContainer,
            borderRadius: BorderRadius.circular(16 * s),
          ),
          child: Row(
            children: [
              CircleAvatar(
                radius: 22 * s,
                backgroundColor: scheme.primaryContainer,
                child: Text(
                  name.isEmpty ? '?' : name.characters.first.toUpperCase(),
                  style: theme.textTheme.titleLarge?.copyWith(
                    color: scheme.onPrimaryContainer,
                  ),
                ),
              ),
              SizedBox(width: 14 * s),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium,
                    ),
                    SizedBox(height: 2 * s),
                    Text(
                      [
                        server?.name ?? '',
                        server?.activeLine?.hostLabel ?? '',
                      ].where((v) => v.isNotEmpty).join(' · '),
                      key: const Key('tv-session-summary'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        SizedBox(height: 14 * s),
        TvNavTile(
          icon: Icons.add_rounded,
          title: l.mobileAddServer,
          onPressed: () => context.push('${AppRoutes.connect}?add=1'),
        ),
        SizedBox(height: 6 * s),
        TvNavTile(
          actionKey: _TvSession.changePasswordKey,
          icon: Icons.password_rounded,
          title: l.changePassword,
          onPressed: auth.isBusy
              ? null
              : () => showDialog<void>(
                  context: context,
                  builder: (dialogContext) => ChangePasswordDialog(auth: auth),
                ),
        ),
        SizedBox(height: 6 * s),
        TvNavTile(
          icon: Icons.logout_rounded,
          title: l.logout,
          destructive: true,
          chevron: false,
          onPressed: auth.isBusy ? null : auth.logout,
        ),
      ],
    );
  }
}

/// 一台服务器:标题行(名称 + 添加线路 / 删除服务器),下列每条线路。
/// 线路行本身选中即切换;右侧两个图标按钮编辑/删除,左右键可达。
class _TvServerCard extends StatelessWidget {
  const _TvServerCard({required this.auth, required this.server});
  final AuthController auth;
  final SavedServer server;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final s = TvDesign.scaleOf(context);
    final current = auth.session?.server.id == server.id;
    return Container(
      padding: EdgeInsets.fromLTRB(16 * s, 12 * s, 12 * s, 12 * s),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16 * s),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.dns_rounded, size: 20 * s, color: scheme.primary),
              SizedBox(width: 10 * s),
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        '${server.name} · ${server.username}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                    if (current) ...[
                      SizedBox(width: 8 * s),
                      _Tag(label: l.tvSettingsCurrent),
                    ],
                  ],
                ),
              ),
              SizedBox(width: 12 * s),
              TvAction(
                key: _TvSession.lineAddKey(server.id),
                variant: TvActionVariant.ghost,
                leading: const Icon(Icons.add_rounded),
                onPressed: auth.isBusy
                    ? null
                    : () => _addLine(context, auth, server.id),
                child: Text(l.addLine),
              ),
              SizedBox(width: 4 * s),
              TvAction(
                key: _TvSession.serverDeleteKey(server.id),
                variant: TvActionVariant.ghost,
                leading: const Icon(Icons.delete_outline_rounded),
                onPressed: auth.isBusy
                    ? null
                    : () => _confirmDelete(context, auth, server),
                child: Text(l.deleteServer),
              ),
            ],
          ),
          SizedBox(height: 10 * s),
          for (final line in server.lines) ...[
            Row(
              children: [
                Expanded(
                  child: TvChoiceTile(
                    actionKey: ValueKey('${server.id}-${line.id}'),
                    label: line.hostLabel,
                    subtitle: line.address == line.hostLabel
                        ? null
                        : line.address,
                    selected: current && server.activeLine?.id == line.id,
                    onPressed: auth.isBusy
                        ? null
                        : () => auth.switchTo(server.id, lineId: line.id),
                  ),
                ),
                SizedBox(width: 8 * s),
                TvAction(
                  key: _TvSession.lineEditKey(server.id, line.id),
                  variant: TvActionVariant.icon,
                  onPressed: auth.isBusy
                      ? null
                      : () => _editLine(context, auth, server, line),
                  child: Semantics(
                    label: l.editLine,
                    child: const Icon(Icons.edit_outlined),
                  ),
                ),
                SizedBox(width: 4 * s),
                TvAction(
                  key: _TvSession.lineDeleteKey(server.id, line.id),
                  variant: TvActionVariant.icon,
                  onPressed: auth.isBusy || server.lines.length <= 1
                      ? null
                      : () => _deleteLine(context, auth, server, line),
                  child: Semantics(
                    label: l.deleteLine,
                    child: const Icon(Icons.delete_outline_rounded),
                  ),
                ),
              ],
            ),
            SizedBox(height: 6 * s),
          ],
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
        final s = TvDesign.scaleOf(dialogContext);
        return AlertDialog(
          title: Text(l10n.deleteServer),
          content: SizedBox(
            width: 420 * s,
            child: Text(l10n.deleteServerConfirmMessage(server.name)),
          ),
          actions: [
            TvAction(
              key: _TvSession.serverDeleteCancelKey,
              autofocus: true,
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(l10n.cancelAction),
            ),
            TvAction(
              key: _TvSession.serverDeleteConfirmKey,
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(l10n.deleteServerConfirm),
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

class _Tag extends StatelessWidget {
  const _Tag({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = TvDesign.scaleOf(context);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 8 * s, vertical: 2 * s),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onPrimaryContainer,
        ),
      ),
    );
  }
}
