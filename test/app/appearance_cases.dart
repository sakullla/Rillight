import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/appearance_style.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/settings/settings_page.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/app/tv_appearance_picker.dart';
import 'package:rillight/app/tv_widgets.dart';
import 'package:rillight/app/window_chrome.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/auth/connect_page.dart';
import 'package:rillight/auth/tv_connect_page.dart';
import 'package:rillight/player/player_setting_choices.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:window_manager/window_manager.dart';

/// WCAG 对比度:正文与控件配对不低于 AA(4.5:1)。
double _contrast(Color a, Color b) {
  final first = a.computeLuminance();
  final second = b.computeLuminance();
  final lighter = first > second ? first : second;
  final darker = first > second ? second : first;
  return (lighter + 0.05) / (darker + 0.05);
}

void main() {
  test('light theme keeps AA contrast for body text and controls', () {
    final scheme = AppTheme.light().colorScheme;

    expect(scheme.brightness, Brightness.light);
    expect(
      _contrast(scheme.onSurface, scheme.surfaceContainer),
      greaterThan(4.5),
    );
    expect(_contrast(scheme.onSurface, scheme.surface), greaterThan(4.5));
    expect(
      _contrast(scheme.onSurfaceVariant, scheme.surface),
      greaterThan(4.5),
    );
    expect(_contrast(scheme.onPrimary, scheme.primary), greaterThan(4.5));
    expect(_contrast(scheme.onError, scheme.error), greaterThan(4.5));

    // 深色分层与操作在新的冷调表面上同样保持对比。
    final dark = AppTheme.dark();
    expect(dark.colorScheme.brightness, Brightness.dark);
    expect(
      _contrast(
        dark.colorScheme.onSurfaceVariant,
        dark.colorScheme.surfaceContainer,
      ),
      greaterThan(4.5),
    );
    expect(
      _contrast(dark.colorScheme.onPrimary, dark.colorScheme.primary),
      greaterThan(4.5),
    );
    expect(
      dark.colorScheme.surfaceContainer.computeLuminance(),
      greaterThan(dark.scaffoldBackgroundColor.computeLuminance()),
    );
    // 遮罩底色两种亮度下都是黑色:海报/画面上的渐变不受外观影响。
    expect(AppTheme.light().colorScheme.scrim, Colors.black);
    expect(dark.colorScheme.scrim, Colors.black);
  });

  test('system choice falls back to dark unless light is confirmed', () {
    // 引擎报告深色:所有平台的深色报告都来自真实设置,直接落深色。
    expect(
      resolveSystemChoice(
        engineBrightness: Brightness.dark,
        isAndroid: true,
        isLinux: false,
        androidNightMode: null,
      ),
      SystemBrightnessChoice.dark,
    );
    // Android:仅 NIGHT_NO 确认浅色;NIGHT_UNDEFINED(API 24–27 无系统
    // 深色设置)与通道无响应都无法确认,回落深色。
    expect(
      resolveSystemChoice(
        engineBrightness: Brightness.light,
        isAndroid: true,
        isLinux: false,
        androidNightMode: 'no',
      ),
      SystemBrightnessChoice.light,
    );
    for (final nightMode in ['undefined', null, 'nonsense']) {
      expect(
        resolveSystemChoice(
          engineBrightness: Brightness.light,
          isAndroid: true,
          isLinux: false,
          androidNightMode: nightMode,
        ),
        SystemBrightnessChoice.unknown,
        reason: 'nightMode=$nightMode',
      );
    }
    expect(
      resolveSystemChoice(
        engineBrightness: Brightness.light,
        isAndroid: true,
        isLinux: false,
        androidNightMode: 'yes',
      ),
      SystemBrightnessChoice.dark,
    );
    // Linux:GTK color-scheme 未配置时引擎恒报浅色,无法确认。
    expect(
      resolveSystemChoice(
        engineBrightness: Brightness.light,
        isAndroid: false,
        isLinux: true,
        androidNightMode: null,
      ),
      SystemBrightnessChoice.unknown,
    );
    // Windows/macOS:系统外观设置总可判定,引擎浅色可信。
    expect(
      resolveSystemChoice(
        engineBrightness: Brightness.light,
        isAndroid: false,
        isLinux: false,
        androidNightMode: null,
      ),
      SystemBrightnessChoice.light,
    );
  });

  test('without a stored preference the appearance defaults to dark', () async {
    final controller = AppearanceController(store: MemoryPlayerSettingsStore());
    await Future<void>.delayed(Duration.zero);

    expect(controller.style, AppearanceStyle.dark);
    expect(controller.themeMode, ThemeMode.dark);
  });

  test('a stored preference loads and setStyle persists without clearing '
      'other settings', () async {
    final store = MemoryPlayerSettingsStore(
      const PlayerSettings(volume: 40, appearanceStyle: 'dark'),
    );
    final controller = AppearanceController(store: store);
    await Future<void>.delayed(Duration.zero);

    // 重启后保持上次选择。
    expect(controller.style, AppearanceStyle.dark);
    expect(controller.themeMode, ThemeMode.dark);

    await controller.setStyle(AppearanceStyle.light);

    expect(controller.style, AppearanceStyle.light);
    final saved = await store.read();
    expect(saved.appearanceStyle, 'light');
  });

  testWidgets('the settings page appearance dropdown echoes and persists', (
    tester,
  ) async {
    final store = MemoryPlayerSettingsStore();
    final controller = AppearanceController(store: store);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh', 'CN'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: AppearanceScope(
          controller: controller,
          child: const Scaffold(body: SettingsPage()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('settings-section-外观')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<PlayerRateCell>(
            find.byKey(const ValueKey('settings-appearance-dark')),
          )
          .selected,
      isTrue,
    );

    await tester.tap(find.byKey(const ValueKey('settings-appearance-light')));
    await tester.pumpAndSettle();

    expect(controller.style, AppearanceStyle.light);
    expect((await store.read()).appearanceStyle, 'light');
  }, tags: ['integration']);

  testWidgets('the desktop login page appearance menu persists the choice', (
    tester,
  ) async {
    final store = MemoryPlayerSettingsStore();
    final controller = AppearanceController(store: store);
    await tester.pumpWidget(
      RillightApp(auth: AuthController.memory(), appearance: controller),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(ConnectFormKeys.connectAppearanceKey), findsOneWidget);
    // 未保存过外观时默认深色。
    expect(controller.style, AppearanceStyle.dark);
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.dark,
    );

    await tester.tap(find.byKey(ConnectFormKeys.connectAppearanceKey));
    await tester.pumpAndSettle();
    await tester.tap(find.text('浅色').last);
    await tester.pumpAndSettle();

    expect(controller.style, AppearanceStyle.light);
    expect((await store.read()).appearanceStyle, 'light');
  }, tags: ['integration']);

  testWidgets(
    'the TV login page exposes remote-selectable appearance choices',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = MemoryPlayerSettingsStore();
      final controller = AppearanceController(store: store);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh', 'CN'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: AppearanceScope(
            controller: controller,
            child: AuthScope(
              controller: AuthController.memory(),
              child: const TvConnectPage(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final lightOption = find.byKey(const Key('tv-appearance-light'));
      final darkOption = find.byKey(const Key('tv-appearance-dark'));
      expect(find.byKey(const Key('tv-appearance-system')), findsOneWidget);
      expect(lightOption, findsOneWidget);
      expect(darkOption, findsOneWidget);

      // 选中浅色:按钮标记 selected,偏好即时生效并持久化。
      await tester.tap(lightOption);
      await tester.pumpAndSettle();
      expect(controller.style, AppearanceStyle.light);
      expect(tester.widget<TvAction>(lightOption).selected, isTrue);
      expect((await store.read()).appearanceStyle, 'light');

      // 方向键在选项间移动:焦点从浅色移到深色后按 SELECT 生效。
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      final focused = FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<TvAction>();
      expect(focused?.key, const Key('tv-appearance-dark'));

      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(controller.style, AppearanceStyle.dark);
      expect((await store.read()).appearanceStyle, 'dark');
    },
    tags: ['integration'],
  );

  testWidgets('the TV appearance picker writes the existing controller', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = MemoryPlayerSettingsStore();
    final controller = AppearanceController(store: store);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh', 'CN'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: AppearanceScope(
          controller: controller,
          child: const Scaffold(body: TvAppearancePicker()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final lightOption = find.byKey(const Key('tv-appearance-light'));
    final darkOption = find.byKey(const Key('tv-appearance-dark'));
    expect(find.byKey(const Key('tv-appearance-system')), findsOneWidget);
    expect(lightOption, findsOneWidget);
    expect(darkOption, findsOneWidget);
    expect(controller.style, AppearanceStyle.dark);
    expect(tester.widget<TvAction>(darkOption).selected, isTrue);

    await tester.tap(lightOption);
    await tester.pumpAndSettle();
    expect(controller.style, AppearanceStyle.light);
    expect(tester.widget<TvAction>(lightOption).selected, isTrue);
    expect(tester.widget<TvAction>(darkOption).selected, isFalse);
    expect((await store.read()).appearanceStyle, 'light');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    final focused = FocusManager.instance.primaryFocus?.context
        ?.findAncestorWidgetOfExactType<TvAction>();
    expect(focused?.key, const Key('tv-appearance-dark'));

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(controller.style, AppearanceStyle.dark);
    expect(tester.widget<TvAction>(darkOption).selected, isTrue);
    expect((await store.read()).appearanceStyle, 'dark');
  });

  testWidgets('window caption buttons follow the theme brightness', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: const WindowChromeHost(child: SizedBox.expand()),
      ),
    );
    await tester.pump();

    expect(find.byType(WindowCaption), findsOneWidget);
    expect(
      tester.widget<WindowCaption>(find.byType(WindowCaption)).brightness,
      Brightness.light,
    );
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}
