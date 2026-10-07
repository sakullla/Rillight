import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/appearance_style.dart';
import 'package:rillight/app/desktop_performance_host.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/mobile_chrome.dart';
import 'package:rillight/app/phone_nav_style.dart';
import 'package:rillight/app/product.dart';
import 'package:rillight/app/presentation_environment.dart';
import 'package:rillight/app/router.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/app/tv_widgets.dart';
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
    this.environment = PresentationEnvironment.desktop,
    this.playerBindings = const PlayerBindings(),
    AppearanceController? appearance,
  }) : auth = auth ?? AuthController.memory(),
       appearance = appearance ?? AppearanceController(),
       windowHost = playerBindings.windowHost ?? OverlayPlayerWindowHost() {
    this.router =
        router ?? createAppRouter(auth: this.auth, environment: environment);
  }

  final AuthController auth;
  final PresentationEnvironment environment;
  final PlayerBindings playerBindings;
  final AppearanceController appearance;
  final PlayerWindowHost windowHost;
  late final GoRouter router;

  @override
  Widget build(BuildContext context) {
    return AppearanceScope(
      controller: appearance,
      child: _SystemBrightnessObserver(
        controller: appearance,
        child: ListenableBuilder(
          listenable: appearance,
          builder: (context, _) {
            // themeMode 已含「跟随系统且平台无偏好时深色」的判定:
            // 引擎亮度变化由 _SystemBrightnessObserver 触发重判。
            final mode = appearance.themeMode;
            if (!environment.isDesktop) {
              final app = PresentationScope(
                environment: environment,
                child: AuthScope(
                  controller: auth,
                  child: PlayerScope(
                    bindings: playerBindings,
                    child: MaterialApp.router(
                      title: kProductName,
                      debugShowCheckedModeBanner: false,
                      locale: const Locale('zh', 'CN'),
                      supportedLocales: AppLocalizations.supportedLocales,
                      localizationsDelegates:
                          AppLocalizations.localizationsDelegates,
                      theme: environment.isTv
                          ? AppTheme.tvLight()
                          : AppTheme.phoneLight(),
                      darkTheme: environment.isTv
                          ? AppTheme.tvDark()
                          : AppTheme.phoneDark(),
                      // TV 每条路由(含弹窗)共用按画布换算的字号与弹窗样式。
                      builder: environment.isTv
                          ? (context, child) => TvStageTheme(
                              child: child ?? const SizedBox.shrink(),
                            )
                          : null,
                      themeMode: mode,
                      scrollBehavior: environment.isTv
                          ? null
                          : const PhoneScrollBehavior(),
                      routerConfig: router,
                    ),
                  ),
                ),
              );
              if (environment.isTv) {
                return app;
              }
              return PhoneNavStyleHost(child: app);
            }
            return PresentationScope(
              environment: environment,
              child: _buildDesktop(context, mode),
            );
          },
        ),
      ),
    );
  }

  Widget _buildDesktop(BuildContext context, ThemeMode mode) {
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
              theme: AppTheme.light(),
              darkTheme: AppTheme.dark(),
              themeMode: mode,
              routerConfig: router,
              builder: (context, child) {
                return DesktopPerformanceHost(
                  child: PlayerScope(
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

/// 系统亮度变化时重判「跟随系统」的落点。
///
/// 引擎 platformBrightness 变化不代表偏好已确认(Android 无深色设置的
/// 设备恒报 light),交给 [AppearanceController.refreshSystemChoice] 按
/// 平台重新确认;无法确认保持深色。
class _SystemBrightnessObserver extends StatefulWidget {
  const _SystemBrightnessObserver({
    required this.controller,
    required this.child,
  });

  final AppearanceController controller;
  final Widget child;

  @override
  State<_SystemBrightnessObserver> createState() =>
      _SystemBrightnessObserverState();
}

class _SystemBrightnessObserverState extends State<_SystemBrightnessObserver>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangePlatformBrightness() {
    unawaited(widget.controller.refreshSystemChoice());
  }

  @override
  Widget build(BuildContext context) => widget.child;
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
    this.closeTimeout = const Duration(seconds: 2),
    this.forceCloseTimeout = const Duration(seconds: 1),
    this.idleCloseTimeout = const Duration(milliseconds: 400),
  });

  final PlayerWindowHost host;
  final Widget child;

  /// 关闭播放窗口后销毁主窗口的动作;缺省走 window_manager。
  final Future<void> Function()? destroyWindow;

  /// 有播放窗口时等待其关闭的上限,超时后 forceClose,再销毁主窗口。
  final Duration closeTimeout;

  /// 优雅关闭超时后,强制结束播放进程的上限。
  final Duration forceCloseTimeout;

  /// 没有播放窗口时仍调用 close() 以取消在途 spawn,但很快放弃等待。
  final Duration idleCloseTimeout;

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
    final wait = widget.host.current == null
        ? widget.idleCloseTimeout
        : widget.closeTimeout;
    try {
      await widget.host.close().timeout(wait);
    } catch (_) {
      // Do not abandon a player that is still starting or closing.
      try {
        await widget.host.forceClose().timeout(widget.forceCloseTimeout);
      } catch (_) {}
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
          if (host.switchFailure == null) return child;
          final l10n = AppLocalizations.of(context);
          return Stack(
            fit: StackFit.expand,
            children: [
              child,
              Align(
                alignment: Alignment.bottomCenter,
                child: SafeArea(
                  child: Material(
                    elevation: 8,
                    color: Theme.of(context).colorScheme.errorContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(l10n.desktopSourceSwitchFailed),
                          if (!host.canRestoreOriginal)
                            Text(l10n.desktopSourceRestoreUnavailable),
                          FilledButton(
                            key: const Key('desktop-restore-original'),
                            onPressed: !host.canRestoreOriginal
                                ? null
                                : () async {
                                    try {
                                      await host.restoreOriginalSource();
                                    } catch (_) {
                                      if (!context.mounted) return;
                                      ScaffoldMessenger.maybeOf(
                                        context,
                                      )?.showSnackBar(
                                        SnackBar(
                                          content: Text(
                                            l10n.desktopSourceRestoreFailed,
                                          ),
                                        ),
                                      );
                                    }
                                  },
                            child: Text(l10n.switchRestore),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        }
        return Stack(
          fit: StackFit.expand,
          children: [
            child,
            Positioned.fill(
              child: FocusScope(
                autofocus: true,
                child: Theme(
                  data: AppTheme.dark(),
                  child: Navigator(
                    key: ObjectKey(request),
                    onGenerateRoute: (settings) {
                      return PageRouteBuilder<void>(
                        settings: settings,
                        pageBuilder: (context, animation, secondaryAnimation) {
                          return PlayerPage(
                            itemId: request.itemId,
                            sourceRequest: request,
                            autoResume: request.autoResume,
                            mediaSourceId: request.mediaSourceId,
                            audioStreamIndex: request.audioStreamIndex,
                            subtitleStreamIndex: request.subtitleStreamIndex,
                            startTimeTicks: request.startTimeTicks,
                            onOpenItemDetail: (itemId, {seasonId, command}) {
                              final permit = command?.source == null
                                  ? null
                                  : AuthScope.of(context).sources.permit(
                                      command!.source!.account,
                                      libraryId: command.libraryId,
                                    );
                              unawaited(() async {
                                await host.close();
                                if (command != null &&
                                    (permit?.isValid != true ||
                                        permit?.regionGeneration !=
                                            command.regionGeneration)) {
                                  return;
                                }
                                if (request.source != null && command == null) {
                                  return;
                                }
                                router.push(
                                  AppRoutes.item(itemId, seasonId: seasonId),
                                  extra: command,
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
            ),
          ],
        );
      },
    );
  }
}
