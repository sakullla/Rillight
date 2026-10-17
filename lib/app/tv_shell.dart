import '../auth/tv_server_selection_page.dart';
import 'updates/update_check.dart';

import 'dart:async';

import 'package:rillight/app/ui/ui.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:rillight/app/app_shell.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/tv_top_nav.dart';

import 'package:rillight/app/tv_appearance_picker.dart';
import 'package:rillight/app/tv_widgets.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/home/catalog_scope.dart';

import 'package:rillight/home/tv_home_page.dart';
import 'package:rillight/player/android_session_recovery.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/library/aggregation_page.dart';
import 'package:rillight/app/ui/app_icons.dart';

class TvShell extends StatefulWidget {
  const TvShell({super.key});
  @override
  State<TvShell> createState() => _TvShellState();
}

class _TvShellState extends State<TvShell> with WidgetsBindingObserver {
  int _index = 0;
  int _paneSelectionRevision = 0;
  bool _initialized = false, _recovering = false, _failed = false;

  /// 只有真正退到后台(hidden/paused)再回来才刷新;系统浮层只经过 inactive。
  bool _backgrounded = false;

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
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      _backgrounded = true;
      return;
    }
    if (state == AppLifecycleState.resumed && _backgrounded && mounted) {
      _backgrounded = false;
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
          child: CupertinoPageScaffold(
            child: Stack(
              fit: StackFit.expand,
              children: [
                Positioned.fill(
                  child: _recovering
                      ? const Center(child: CupertinoActivityIndicator())
                      : _failed
                      ? TvEmptyState(
                          icon: AppIcons.cloud,
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

/// Appearance and application settings remain separate from server editing.
class _TvSession extends StatelessWidget {
  const _TvSession();
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return ListView(
      key: const PageStorageKey('tv-session'),
      padding: EdgeInsets.fromLTRB(
        tvSafeGutter(MediaQuery.sizeOf(context).width),
        TvTopNavBar.reserveOf(context) + 8,
        tvSafeGutter(MediaQuery.sizeOf(context).width),
        32,
      ),
      children: [
        TvNavTile(
          actionKey: const Key('tv-settings-servers'),
          icon: AppIcons.server,
          title: l.serversTitle,
          onPressed: () => showTvServerSelection(
            context,
            auth: AuthScope.of(context),
            onEntered: () async {
              CatalogScope.maybeOf(context)?.reload();
            },
            onLineChanged: () async {
              CatalogScope.maybeOf(context)?.reload();
            },
          ),
        ),
        const SizedBox(height: 28),
        TvSectionTitle(l.settingsAppearance),
        const SizedBox(height: 12),
        const TvAppearancePicker(),
        const SizedBox(height: 28),
        TvSectionTitle(l.mobileAboutGroup),
        const UpdateCheck(),
      ],
    );
  }
}
