import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/product.dart';
import 'package:rillight/app/router.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/player/player_page.dart';
import 'package:rillight/player/player_window_host.dart';
import 'package:window_manager/window_manager.dart';

class RillightApp extends StatelessWidget {
  RillightApp({
    super.key,
    AuthController? auth,
    GoRouter? router,
    this.playerBindings = const PlayerBindings(),
  }) : auth = auth ?? AuthController.memory(),
       windowHost = playerBindings.windowHost ?? OverlayPlayerWindowHost() {
    this.router = router ?? createAppRouter(auth: this.auth);
  }

  final AuthController auth;
  final PlayerBindings playerBindings;
  final PlayerWindowHost windowHost;
  late final GoRouter router;

  @override
  Widget build(BuildContext context) {
    return AuthScope(
      controller: auth,
      child: PlayerScope(
        bindings: playerBindings,
        child: PlayerWindowScope(
          host: windowHost,
          child: MainWindowCloseGuard(
            host: windowHost,
            child: MaterialApp.router(
              title: kProductName,
              debugShowCheckedModeBanner: false,
              locale: const Locale('zh', 'CN'),
              supportedLocales: AppLocalizations.supportedLocales,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              theme: AppTheme.dark(),
              darkTheme: AppTheme.dark(),
              themeMode: ThemeMode.dark,
              routerConfig: router,
              builder: (context, child) {
                return PlayerScope(
                  bindings: playerBindings,
                  child: PlayerWindowScope(
                    host: windowHost,
                    child: _PlayerHostNoticeListener(
                      host: windowHost,
                      child: _PlayerWindowLayer(
                        host: windowHost,
                        router: router,
                        child: child ?? const SizedBox.shrink(),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// 主窗口关闭时先关闭播放窗口(含优雅关闭与代发 Stopped)再销毁窗口。
///
/// 依赖 `configureMainWindow` 已 `setPreventClose(true)`,否则系统直接
/// 销毁窗口,不会进入 [WindowListener.onWindowClose]。
class MainWindowCloseGuard extends StatefulWidget {
  const MainWindowCloseGuard({
    super.key,
    required this.host,
    required this.child,
    this.destroyWindow,
    this.closeTimeout = const Duration(seconds: 8),
  });

  final PlayerWindowHost host;
  final Widget child;

  /// 关闭播放窗口后销毁主窗口的动作;缺省走 window_manager。
  final Future<void> Function()? destroyWindow;

  /// 等待播放窗口关闭的总上限,超时也继续销毁主窗口。
  final Duration closeTimeout;

  @override
  State<MainWindowCloseGuard> createState() => _MainWindowCloseGuardState();
}

class _MainWindowCloseGuardState extends State<MainWindowCloseGuard>
    with WindowListener {
  var _closing = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowClose() {
    unawaited(_closeThenDestroy());
  }

  Future<void> _closeThenDestroy() async {
    if (_closing) {
      return;
    }
    _closing = true;
    try {
      await widget.host.close().timeout(widget.closeTimeout);
    } catch (_) {
      // 播放窗口关闭失败或超时不应阻止主窗口退出。
    }
    try {
      await (widget.destroyWindow ?? _destroyMainWindow)();
    } catch (_) {
      _closing = false;
    }
  }

  static Future<void> _destroyMainWindow() async {
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// 把宿主提示(如代发 Stopped 失败)以 SnackBar 呈现在主窗口。
class _PlayerHostNoticeListener extends StatefulWidget {
  const _PlayerHostNoticeListener({required this.host, required this.child});

  final PlayerWindowHost host;
  final Widget child;

  @override
  State<_PlayerHostNoticeListener> createState() =>
      _PlayerHostNoticeListenerState();
}

class _PlayerHostNoticeListenerState extends State<_PlayerHostNoticeListener> {
  StreamSubscription<PlayerHostNotice>? _subscription;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateWidget(covariant _PlayerHostNoticeListener oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.host != widget.host) {
      _subscription?.cancel();
      _subscribe();
    }
  }

  void _subscribe() {
    _subscription = widget.host.notices.listen(_onNotice);
  }

  void _onNotice(PlayerHostNotice notice) {
    if (!mounted) {
      return;
    }
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) {
      return;
    }
    final l10n = AppLocalizations.of(context);
    switch (notice) {
      case PlayerHostNotice.progressSyncFailed:
        messenger.showSnackBar(
          SnackBar(content: Text(l10n.progressSyncFailedMain)),
        );
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _PlayerWindowLayer extends StatelessWidget {
  const _PlayerWindowLayer({
    required this.host,
    required this.router,
    required this.child,
  });

  final PlayerWindowHost host;
  final GoRouter router;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: host,
      builder: (context, _) {
        final request = host.current;
        if (!host.embedsPlayerInCaller || request == null) {
          return child;
        }
        return Stack(
          fit: StackFit.expand,
          children: [
            child,
            Positioned.fill(
              child: FocusScope(
                autofocus: true,
                child: Navigator(
                  key: ObjectKey(request),
                  onGenerateRoute: (settings) {
                    return PageRouteBuilder<void>(
                      settings: settings,
                      pageBuilder: (context, animation, secondaryAnimation) {
                        return PlayerPage(
                          itemId: request.itemId,
                          autoResume: request.autoResume,
                          mediaSourceId: request.mediaSourceId,
                          audioStreamIndex: request.audioStreamIndex,
                          subtitleStreamIndex: request.subtitleStreamIndex,
                          startTimeTicks: request.startTimeTicks,
                          onOpenItemDetail: (itemId, {seasonId}) {
                            unawaited(() async {
                              await host.close();
                              router.push(
                                AppRoutes.item(itemId, seasonId: seasonId),
                              );
                            }());
                          },
                        );
                      },
                    );
                  },
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
