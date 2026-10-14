import 'dart:async';

import 'package:rillight/app/ui/ui.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/app_shell.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/mobile_motion.dart';
import 'package:rillight/app/phone_bottom_nav.dart';
import 'package:rillight/library/aggregation_page.dart';
import 'package:rillight/app/phone_nav_style.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/home/phone_home.dart';
import 'package:rillight/player/android_session_recovery.dart';
import 'package:rillight/player/player_bindings.dart';

class MobileShell extends StatefulWidget {
  const MobileShell({super.key});
  @override
  State<MobileShell> createState() => _MobileShellState();
}

class _MobileShellState extends State<MobileShell> with WidgetsBindingObserver {
  int _index = 0;
  bool _homeCovered = false;
  bool? _pendingHomeCovered;
  bool _homeCoverScheduled = false;
  bool _recovering = false, _recoveryFailed = false, _initialized = false;

  /// 只有真正退到后台(hidden/paused)再回来才刷新。下拉通知栏、系统弹窗、
  /// 分屏切换焦点只经过 inactive,不值得为此重新拉取用户与整个首页。
  bool _backgrounded = false;
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
    setState(() {
      _recovering = true;
      _recoveryFailed = false;
    });
    try {
      final recovered = await recoverAndroidSession(
        AuthScope.of(context).client,
        store,
        runtime: PlayerScope.of(context).runtime,
      );
      if (mounted && recovered) {
        AppNoticeHost.of(context)
            .show(AppLocalizations.of(context).mobilePreviousSession);
      }
    } catch (_) {
      if (mounted) setState(() => _recoveryFailed = true);
    } finally {
      if (mounted) setState(() => _recovering = false);
    }
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
      if (auth.isLoggedIn) {
        unawaited(() async {
          try {
            await auth.client.getUser();
          } catch (_) {
            /* Catalog displays retry or auth redirects. */
          }
          if (mounted && auth.isLoggedIn) await catalog.reload();
        }());
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context), auth = AuthScope.of(context);
    final titles = [l.home, l.aggregation, l.search];
    final floating = PhoneNavStyle.floatingOf(context);
    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    final immersive = _index == 0 && !_homeCovered;
    const hit = Size(AppSpacing.huge, AppSpacing.huge);
    return PopScope(
      canPop: _index == 0,
      onPopInvokedWithResult: (popped, _) {
        if (!popped) setState(() => _index = 0);
      },
      child: CupertinoPageScaffold(
        navigationBar: CupertinoNavigationBar(
          backgroundColor: immersive ? const Color(0x00000000) : null,
          middle: Text(titles[_index]),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_index == 0)
                AppIconButton(
                  key: const Key('phone-home-edit'),
                  tooltip: l.phoneHomeEdit,
                  icon: const Icon(CupertinoIcons.slider_horizontal_3),
                  onPressed: () => context.push(AppRoutes.homeEdit),
                ),
              AppIconButton(
                key: const Key('mobile-shell-mine-entry'),
                tooltip: l.mobileMine,
                icon: const Icon(CupertinoIcons.person_crop_circle),
                onPressed: () => context.push(AppRoutes.mine),
              ),
            ],
          ),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Padding(
              padding: EdgeInsets.only(
                bottom: !floating && !keyboardOpen
                    ? 72 + MediaQuery.viewPaddingOf(context).bottom
                    : 0,
              ),
              child: NotificationListener<ScrollNotification>(
                onNotification: (notification) {
                  if (_index != 0 ||
                      notification.metrics.axis != Axis.vertical ||
                      notification.context
                              ?.findAncestorWidgetOfExactType<PhoneHome>() ==
                          null) {
                    return false;
                  }
                  final covered = notification.metrics.pixels > 24;

                  _pendingHomeCovered = covered;
                  if (!_homeCoverScheduled) {
                    _homeCoverScheduled = true;

                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      _homeCoverScheduled = false;
                      final latest = _pendingHomeCovered;
                      _pendingHomeCovered = null;
                      if (mounted &&
                          _index == 0 &&
                          latest != null &&
                          latest != _homeCovered) {
                        setState(() => _homeCovered = latest);
                      }
                    });
                  }
                  return false;
                },
                child: SafeArea(
                  top: _index != 0,
                  bottom: !floating,
                  child: Column(
                    children: [
                      if (_recovering) const AppLoadingBar(),
                      if (_recoveryFailed)
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            children: [
                              Text(l.mobileRecoveryFailed),
                              AppButton(
                                style: AppButtonStyle(minimumSize: hit),
                                onPressed: _recover,
                                variant: AppButtonVariant.filled,
                                child: Text(l.retry),
                              ),
                              AppButton(
                                style: AppButtonStyle(minimumSize: hit),
                                onPressed: auth.logout,
                                variant: AppButtonVariant.plain,
                                child: Text(l.connect),
                              ),
                            ],
                          ),
                        ),
                      Expanded(
                        child: IgnorePointer(
                          ignoring: _recovering || _recoveryFailed,
                          child: PhoneTabTransition(
                            index: _index,
                            child: IndexedStack(
                              index: _index,
                              children: [
                                TickerMode(
                                  enabled: _index == 0,
                                  child: const PhoneHome(),
                                ),
                                TickerMode(
                                  enabled: _index == 1,
                                  child: const AggregationPage(),
                                ),
                                TickerMode(
                                  enabled: _index == 2,
                                  child: SearchRouteGuard(
                                    canPop: true,
                                    onPop: () {
                                      FocusScope.of(context).unfocus();
                                      setState(() => _index = 0);
                                    },
                                    child: const AggregationPage(search: true),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (!keyboardOpen)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: PhoneBottomNav(
                  index: _index,
                  floating: floating,
                  onSelected: (index) {
                    FocusScope.of(context).unfocus();
                    setState(() => _index = index);
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}
