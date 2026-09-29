import 'dart:async';

import 'package:flutter/material.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/player/player_settings.dart';

/// 外观三态:跟随系统(默认)、浅色、深色。
enum AppearanceStyle { system, light, dark }

extension AppearanceStyleThemeMode on AppearanceStyle {
  ThemeMode get themeMode {
    switch (this) {
      case AppearanceStyle.system:
        return ThemeMode.system;
      case AppearanceStyle.light:
        return ThemeMode.light;
      case AppearanceStyle.dark:
        return ThemeMode.dark;
    }
  }

  static AppearanceStyle? fromStorage(String? raw) {
    if (raw == null) {
      return null;
    }
    for (final value in AppearanceStyle.values) {
      if (value.name == raw) {
        return value;
      }
    }
    return null;
  }

  String label(AppLocalizations l10n) {
    switch (this) {
      case AppearanceStyle.system:
        return l10n.appearanceSystem;
      case AppearanceStyle.light:
        return l10n.appearanceLight;
      case AppearanceStyle.dark:
        return l10n.appearanceDark;
    }
  }
}

/// 外观偏好:未选择过时跟随系统,选择后立即生效并持久化。
///
/// 持久化复用 [PlayerSettingsStore] 通道(与播放器设置同一 JSON 文件,
/// 合并写互不清除);读取失败/无偏好时保持 [AppearanceStyle.system]。
class AppearanceController extends ChangeNotifier {
  AppearanceController({PlayerSettingsStore? store}) : _store = store {
    if (_store != null) {
      unawaited(_load());
    }
    // 缺省存储不在这里打开:等 [ready]/[setStyle] 首次需要时再开,
    // 避免只构建应用的场合(如测试)留下定时器或未完成的平台调用。
  }

  /// 存储访问上限:平台通道无响应(如测试环境未 mock path_provider)或
  /// 磁盘极慢时,外观不能拖住启动或交互。
  static const _ioTimeout = Duration(seconds: 2);

  final PlayerSettingsStore? _store;
  Future<PlayerSettingsStore>? _ready;

  AppearanceStyle _style = AppearanceStyle.system;

  AppearanceStyle get style => _style;

  ThemeMode get themeMode => _style.themeMode;

  /// 外观就绪:默认构造后等待持久化偏好加载完成(桌面/Android 启动前
  /// await,避免先闪一种亮度再切换);失败/超时静默保持跟随系统。
  Future<void> get ready {
    if (_store != null) {
      return Future<void>.value();
    }
    return _applyStored(_ready ??= _openDefault());
  }

  Future<void> _applyStored(Future<PlayerSettingsStore> opening) async {
    try {
      final store = await opening;
      final settings = await store.read().timeout(_ioTimeout);
      final stored = AppearanceStyleThemeMode.fromStorage(
        settings.appearanceStyle,
      );
      if (stored != null && stored != _style) {
        _style = stored;
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<PlayerSettingsStore> _openDefault() async {
    try {
      return await openPlayerSettingsStore().timeout(_ioTimeout);
    } catch (_) {
      return MemoryPlayerSettingsStore();
    }
  }

  Future<void> _load() async {
    try {
      final settings = await _store!.read().timeout(_ioTimeout);
      final stored = AppearanceStyleThemeMode.fromStorage(
        settings.appearanceStyle,
      );
      if (stored != null && stored != _style) {
        _style = stored;
        notifyListeners();
      }
    } catch (_) {}
  }

  /// 切换外观:先即时生效,再合并写入存储;写失败不回滚(下次启动回落)。
  Future<void> setStyle(AppearanceStyle style) async {
    if (style == _style) {
      return;
    }
    _style = style;
    notifyListeners();
    try {
      final store = _store ?? await (_ready ??= _openDefault());
      await store
          .write(PlayerSettings(appearanceStyle: style.name))
          .timeout(_ioTimeout);
    } catch (_) {}
  }
}

/// 把 [AppearanceController] 提供给页面;外观变化时依赖处自动重建。
class AppearanceScope extends InheritedNotifier<AppearanceController> {
  const AppearanceScope({
    super.key,
    required AppearanceController controller,
    required super.child,
  }) : super(notifier: controller);

  static AppearanceController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppearanceScope>();
    return scope!.notifier!;
  }

  static AppearanceController? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<AppearanceScope>()
        ?.notifier;
  }
}

/// 登录页右上角的外观入口:弹出三态菜单,当前项打勾。
///
/// 桌面与手机登录页共用;TV 布局不用本组件,走可聚焦的三态按钮。
class AppearanceMenuButton extends StatelessWidget {
  const AppearanceMenuButton({super.key, this.buttonKey});

  final Key? buttonKey;

  static const Key menuKey = Key('appearance-menu');

  @override
  Widget build(BuildContext context) {
    final controller = AppearanceScope.maybeOf(context);
    final l10n = AppLocalizations.of(context);
    final style = controller?.style ?? AppearanceStyle.system;
    return PopupMenuButton<AppearanceStyle>(
      key: buttonKey ?? menuKey,
      tooltip: l10n.settingsAppearance,
      icon: const Icon(Icons.brightness_6_outlined),
      enabled: controller != null,
      initialValue: style,
      onSelected: controller?.setStyle,
      itemBuilder: (context) => [
        for (final value in AppearanceStyle.values)
          PopupMenuItem(value: value, child: Text(value.label(l10n))),
      ],
    );
  }
}
