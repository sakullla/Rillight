import 'dart:async';
import 'dart:typed_data';

import 'package:rillight/app/ui/ui.dart';
import 'package:rillight/auth/login_widgets.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/jellyfin/jellyfin_client.dart';
import 'package:rillight/media_server/capabilities.dart';
import 'package:rillight/media_server/media_server_client.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/app_shell.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/mobile_chrome.dart';
import 'package:rillight/app/mobile_motion.dart';
import 'package:rillight/app/mobile_widgets.dart';
import 'package:rillight/app/phone_bottom_nav.dart';
import 'package:rillight/library/aggregation_page.dart';
import 'package:rillight/app/phone_nav_style.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/auth/phone_server_manager.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/home/phone_home.dart';
import 'package:rillight/player/android_session_recovery.dart';
import 'package:rillight/player/player_bindings.dart';

class MobileShell extends StatefulWidget {
  const MobileShell({super.key});
  static const serverPillKey = Key('mobile-shell-server-pill');
  static const topBarKey = Key('mobile-shell-top-bar');
  static const titleKey = Key('mobile-shell-title');

  /// 标签页顺序:首页、聚合、搜索。
  static const homeTab = 0;
  static const aggregationTab = 1;
  static const searchTab = 2;

  /// 首页顶栏高;其它标签页顶栏放大号页面名,更高一些。
  static const homeBarHeight = 44.0;
  static const titleBarHeight = 52.0;

  @override
  State<MobileShell> createState() => _MobileShellState();
}

class _MobileShellState extends State<MobileShell> with WidgetsBindingObserver {
  PhoneDestination _destination = PhoneDestination.home;
  int get _index => _destination.index;
  set _index(int value) {
    _destination = PhoneDestination.values[value];
    PageStorage.maybeOf(
      context,
    )?.writeState(context, _destination.name, identifier: 'phone-destination');
  }

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
      _destination = PhoneDestination.restore(
        PageStorage.maybeOf(context)
            ?.readState(context, identifier: 'phone-destination'),
      );
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
    final floating = PhoneNavStyle.floatingOf(context);
    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    const hit = Size(AppSpacing.huge, AppSpacing.huge);
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    final server = auth.session?.server;
    final serverName = server?.displayName.trim() ?? '';
    final pillLabel = server == null || serverName.isEmpty
        ? l.phoneServerManagement
        : serverName;
    final topInset = MediaQuery.paddingOf(context).top;
    final chrome = phoneChromeTheme(context);
    final barBody = _index == 0
        ? MobileShell.homeBarHeight
        : MobileShell.titleBarHeight;
    final homeImmersive = _index == 0 && !_homeCovered;
    final tabTitle = switch (_index) {
      MobileShell.aggregationTab => l.aggregation,
      MobileShell.searchTab => l.search,
      _ => '',
    };
    final onBar = homeImmersive && chrome.brightness == Brightness.dark
        ? const Color(0xFFFFFFFF)
        : chrome.colorScheme.onSurface;
    return PopScope(
      canPop: _index == 0,
      onPopInvokedWithResult: (popped, _) {
        if (!popped) setState(() => _index = 0);
      },
      child: CupertinoPageScaffold(
        child: Stack(
          fit: StackFit.expand,
          children: [
            Padding(
              padding: EdgeInsets.only(
                bottom: !floating && !keyboardOpen
                    ? AppMobileNav.dockedHeight +
                          MediaQuery.viewPaddingOf(context).bottom
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
                  top: false,
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
                        child: Padding(
                          padding: EdgeInsets.only(
                            top: _index == 0 ? 0 : topInset + barBody,
                          ),
                          child: PhoneShellContentInset(
                            cleared: _index != 0,
                            child: IgnorePointer(
                              ignoring: _recovering || _recoveryFailed,
                              child: PhoneTabTransition(
                                index: _index,
                                child: IndexedStack(
                                  index: _index,
                                  children: [
                                    TickerMode(
                                      enabled: _index == MobileShell.homeTab,
                                      child: const PhoneHome(),
                                    ),
                                    TickerMode(
                                      enabled:
                                          _index == MobileShell.aggregationTab,
                                      child: const AggregationPage(),
                                    ),
                                    TickerMode(
                                      enabled: _index == MobileShell.searchTab,
                                      child: SearchRouteGuard(
                                        canPop: true,
                                        onPop: () {
                                          FocusScope.of(context).unfocus();
                                          setState(() => _index = 0);
                                        },
                                        child: const AggregationPage(
                                          search: true,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
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
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: PhoneTopBar.shell(
                key: MobileShell.topBarKey,
                backgroundColor: homeImmersive
                    ? const Color(0x00000000)
                    : chrome.scaffoldBackgroundColor,
                foregroundColor: onBar,
                height: barBody,
                child: Row(
                  children: [
                    if (_index == 0) ...[
                      const SizedBox(width: AppSpacing.sm),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 220),
                          child: AppSurfaceAction(
                            key: MobileShell.serverPillKey,
                            borderRadius: BorderRadius.circular(999),
                            onTap: () =>
                                showPhoneServerManagerSheet(context, auth),
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: homeImmersive
                                    ? scheme.scrim.withValues(alpha: 0.36)
                                    : scheme.surfaceContainerHigh,
                                borderRadius: BorderRadius.circular(999),
                                border: Border.all(
                                  color: homeImmersive
                                      ? const Color(0x29FFFFFF)
                                      : scheme.outlineVariant,
                                  width: 0.8,
                                ),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 7,
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (server == null)
                                      Icon(
                                        CupertinoIcons.dot_radiowaves_right,
                                        size: 14,
                                        color: homeImmersive
                                            ? const Color(0xFFFFFFFF)
                                            : scheme.primary,
                                      )
                                    else
                                      PhoneServerBrandSlot(
                                        key: ValueKey(
                                          '${server.serviceType.name}|${server.id}|${server.baseUrl}',
                                        ),
                                        serviceType: server.serviceType,
                                        client: auth.client,
                                        identity:
                                            '${server.serviceType.name}|${server.id}|${server.baseUrl}',
                                      ),
                                    const SizedBox(width: 6),
                                    Flexible(
                                      child: Text(
                                        pillLabel,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.labelMedium
                                            ?.copyWith(
                                              color: homeImmersive
                                                  ? const Color(0xFFFFFFFF)
                                                  : scheme.onSurface,
                                              fontWeight: FontWeight.w600,
                                              height: 1.15,
                                            ),
                                      ),
                                    ),
                                    const SizedBox(width: 2),
                                    Icon(
                                      CupertinoIcons.chevron_down,
                                      size: 11,
                                      color: homeImmersive
                                          ? const Color(0xCCFFFFFF)
                                          : scheme.onSurfaceVariant,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ] else
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(left: AppSpacing.md),
                          // 大标题已经够大，系统放大字号时只跟到 1.3 倍，
                          // 不把固定高的顶栏撑破。
                          child: MediaQuery.withClampedTextScaling(
                            maxScaleFactor: 1.3,
                            child: Text(
                              tabTitle,
                              key: MobileShell.titleKey,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: phoneLargeTitleStyle(chrome),
                            ),
                          ),
                        ),
                      ),
                    if (_index == 0) const Spacer(),
                    if (_index == 0)
                      AppIconButton(
                        key: const Key('phone-home-edit'),
                        tooltip: l.phoneHomeEdit,
                        color: onBar,
                        icon: const Icon(CupertinoIcons.slider_horizontal_3),
                        onPressed: () => context.push(AppRoutes.homeEdit),
                      ),
                    AppIconButton(
                      key: const Key('mobile-shell-mine-entry'),
                      tooltip: l.mobileMine,
                      color: onBar,
                      icon: _MineAvatar(
                        name: auth.session?.username ?? '',
                        immersive: homeImmersive,
                      ),
                      onPressed: () => context.push(AppRoutes.mine),
                    ),
                    const SizedBox(width: AppSpacing.xxs),
                  ],
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

/// 顶栏右侧的账户头像:用户名首字的圆形头像。
class _MineAvatar extends StatelessWidget {
  const _MineAvatar({required this.name, required this.immersive});

  final String name;
  final bool immersive;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    final trimmed = name.trim();
    final initial = trimmed.isEmpty
        ? null
        : String.fromCharCode(trimmed.runes.first).toUpperCase();
    return SizedBox.square(
      dimension: 30,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [scheme.primary, scheme.secondary],
          ),
          border: Border.all(
            color: immersive
                ? const Color(0x66FFFFFF)
                : scheme.onSurface.withValues(alpha: .16),
          ),
        ),
        child: Center(
          child: initial == null
              ? Icon(
                  CupertinoIcons.person_fill,
                  size: 16,
                  color: scheme.onPrimary,
                )
              : Text(
                  initial,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: scheme.onPrimary,
                    fontWeight: FontWeight.w800,
                    height: 1,
                  ),
                ),
        ),
      ),
    );
  }
}

/// Phone home server mark. Emby and Jellyfin ask their own client once for a
/// branding image; Plex and a missing or failed image stay on that service's
/// existing mark. A later response cannot replace a settled choice or paint
/// another service's image.
class PhoneServerBrandSlot extends StatefulWidget {
  const PhoneServerBrandSlot({
    super.key,
    required this.serviceType,
    required this.client,
    required this.identity,
    this.size = 14,
  });

  final MediaServerType serviceType;
  final MediaServerClient client;
  final String identity;
  final double size;

  static Key markKeyFor(MediaServerType type) =>
      Key('phone-server-mark-${type.name}');

  static const logoKey = Key('phone-server-logo');

  @override
  State<PhoneServerBrandSlot> createState() => _PhoneServerBrandSlotState();
}

class _PhoneServerBrandSlotState extends State<PhoneServerBrandSlot> {
  int _token = 0;
  Uint8List? _logo;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(PhoneServerBrandSlot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.identity != widget.identity ||
        oldWidget.serviceType != widget.serviceType) {
      _logo = null;
      _load();
    }
  }

  @override
  void dispose() {
    _token++;
    super.dispose();
  }

  void _load() {
    final token = ++_token;
    final type = widget.serviceType;
    final client = widget.client;
    unawaited(() async {
      final accepted = _acceptedBrandingLogo(
        await _serverBrandingLogo(type, client),
      );
      if (!mounted || token != _token || accepted == null) return;
      setState(() => _logo = accepted);
    }());
  }

  @override
  Widget build(BuildContext context) {
    final logo = _logo;
    if (logo == null) {
      return ServerTypeMark(
        key: PhoneServerBrandSlot.markKeyFor(widget.serviceType),
        type: widget.serviceType,
        size: widget.size,
      );
    }
    final size = widget.size;
    return Semantics(
      label: widget.serviceType.label,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(size * 0.22),
        child: Image.memory(
          logo,
          key: PhoneServerBrandSlot.logoKey,
          width: size,
          height: size,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          excludeFromSemantics: true,
          frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
            if (wasSynchronouslyLoaded || frame != null) return child;
            return ServerTypeMark(type: widget.serviceType, size: size);
          },
          errorBuilder: (_, _, _) =>
              ServerTypeMark(type: widget.serviceType, size: size),
        ),
      ),
    );
  }
}

Future<Uint8List?> _serverBrandingLogo(
  MediaServerType type,
  MediaServerClient client,
) {
  if (type == MediaServerType.emby && client is EmbyClient) {
    return client.loadBrandingLogo();
  }
  if (type == MediaServerType.jellyfin && client is JellyfinClient) {
    return client.loadBrandingLogo();
  }
  return Future<Uint8List?>.value(null);
}

Uint8List? _acceptedBrandingLogo(Uint8List? bytes) {
  if (bytes == null || bytes.isEmpty || !_isBrandingImage(bytes)) return null;
  return Uint8List.fromList(bytes);
}

bool _isBrandingImage(Uint8List bytes) {
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47) {
    return true;
  }
  if (bytes.length >= 3 &&
      bytes[0] == 0xFF &&
      bytes[1] == 0xD8 &&
      bytes[2] == 0xFF) {
    return true;
  }
  if (bytes.length >= 6 &&
      bytes[0] == 0x47 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x38) {
    return true;
  }
  if (bytes.length >= 12 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return true;
  }
  return false;
}
