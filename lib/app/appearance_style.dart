import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/player/player_settings.dart';

/// 外观三态:跟随系统、浅色、深色。未选择过时默认深色。
enum AppearanceStyle { system, light, dark }

/// 「跟随系统」的落点亮度确认结果。
///
/// 引擎的 platformBrightness 把「平台无偏好」与「浅色」混同为 light,
/// 因此浅色报告需逐平台确认;[unknown] 表示无法确认,呈现深色。
enum SystemBrightnessChoice { light, dark, unknown }

/// 判定「跟随系统」的落点亮度(R12:平台无偏好时呈深色)。
///
/// - 引擎报告深色:可信,直接落深色(所有平台深色报告都来自真实设置)。
/// - 引擎报告浅色:逐平台确认。
///   - Android 读 uiMode 的 NIGHT 掩码(`com.rillight/environment` 的
///     `nightMode`,返回 yes/no/undefined):NIGHT_NO 才确认浅色;
///     NIGHT_UNDEFINED(API 24–27 无系统深色设置)与读取失败无法确认。
///   - Linux 的 GTK color-scheme 未配置时引擎恒报浅色,无法确认。
///   - Windows/macOS 的系统外观设置总可判定,引擎值可信。
@visibleForTesting
SystemBrightnessChoice resolveSystemChoice({
  required Brightness engineBrightness,
  required bool isAndroid,
  required bool isLinux,
  required String? androidNightMode,
}) {
  if (engineBrightness == Brightness.dark) {
    return SystemBrightnessChoice.dark;
  }
  if (isAndroid) {
    switch (androidNightMode) {
      case 'no':
        return SystemBrightnessChoice.light;
      case 'yes':
        return SystemBrightnessChoice.dark;
      default:
        return SystemBrightnessChoice.unknown;
    }
  }
  if (isLinux) {
    return SystemBrightnessChoice.unknown;
  }
  return SystemBrightnessChoice.light;
}

extension AppearanceStyleThemeMode on AppearanceStyle {
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

/// 外观偏好:未选择过时使用深色,选择后立即生效并持久化。
///
/// 持久化复用 [PlayerSettingsStore] 通道(与播放器设置同一 JSON 文件,
/// 合并写互不清除);读取失败/无偏好时保持 [AppearanceStyle.dark]。
class AppearanceController extends ChangeNotifier {
  AppearanceController({PlayerSettingsStore? store}) : _store = store {
    final injected = _store;
    if (injected != null) {
      _initialLoad = _applyStored(Future.value(injected));
    }
    // 缺省存储不在这里打开:等 [ready]/[setStyle] 首次需要时再开,
    // 避免只构建应用的场合(如测试)留下定时器或未完成的平台调用。
  }

  /// 存储访问上限:平台通道无响应(如测试环境未 mock path_provider)或
  /// 磁盘极慢时,外观不能拖住启动或交互。
  static const _ioTimeout = Duration(seconds: 2);

  final PlayerSettingsStore? _store;
  Future<PlayerSettingsStore>? _ready;
  Future<void>? _initialLoad;

  AppearanceStyle _style = AppearanceStyle.dark;

  /// 「跟随系统」的落点亮度。未确认前是 [SystemBrightnessChoice.unknown],
  /// 即 R12 要求的「平台无偏好时呈深色」;ready/系统亮度变化时刷新。
  SystemBrightnessChoice _systemChoice = SystemBrightnessChoice.unknown;

  AppearanceStyle get style => _style;

  SystemBrightnessChoice get systemChoice => _systemChoice;

  /// 生效主题:浅色/深色直接落;跟随系统时只有确认了浅色偏好才用浅色,
  /// 深色与「无法确认」都落深色。
  ThemeMode get themeMode {
    switch (_style) {
      case AppearanceStyle.light:
        return ThemeMode.light;
      case AppearanceStyle.dark:
        return ThemeMode.dark;
      case AppearanceStyle.system:
        return _systemChoice == SystemBrightnessChoice.light
            ? ThemeMode.light
            : ThemeMode.dark;
    }
  }

  /// 外观就绪:默认构造后等待持久化偏好与系统亮度判定完成(桌面/Android
  /// 启动前 await,避免先闪一种亮度再切换);失败/超时静默保持深色回落。
  Future<void> get ready {
    final initial = _initialLoad;
    if (initial != null) {
      return initial.then((_) => refreshSystemChoice());
    }
    return _applyStored(
      _ready ??= _openDefault(),
    ).then((_) => refreshSystemChoice());
  }

  /// 重新判定「跟随系统」的落点亮度;引擎亮度变化时由外壳调用。
  Future<void> refreshSystemChoice() async {
    final choice = await _readSystemChoice();
    if (choice != _systemChoice) {
      _systemChoice = choice;
      notifyListeners();
    }
  }

  Future<SystemBrightnessChoice> _readSystemChoice() async {
    String? nightMode;
    if (Platform.isAndroid) {
      try {
        nightMode = await const MethodChannel(
          'com.rillight/environment',
        ).invokeMethod<String>('nightMode').timeout(_ioTimeout);
      } catch (_) {}
    }
    return resolveSystemChoice(
      engineBrightness:
          WidgetsBinding.instance.platformDispatcher.platformBrightness,
      isAndroid: Platform.isAndroid,
      isLinux: Platform.isLinux,
      androidNightMode: nightMode,
    );
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
