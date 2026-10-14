import '../helpers/cupertino_test_app.dart';

import 'dart:ui' show PointerDeviceKind;

import '../helpers/widget_harness.dart';
import '../helpers/settle.dart';

import 'package:rillight/app/ui/ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart' hide testWidgets;
import 'package:rillight/app/appearance_style.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/settings/settings_page.dart';
import 'package:rillight/app/ui/ui.dart' as ui;
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
  Widget cupertinoHost(Widget child, {ui.AppUiThemeData? theme}) =>
      ui.CupertinoApp(
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [Locale('zh', 'CN')],
        localizationsDelegates: ui.GlobalCupertinoLocalizations.delegates,
        theme: (theme ?? ui.AppUiTheme.dark()).cupertino,
        home: ui.AppUiTheme(
          data: theme ?? ui.AppUiTheme.dark(),
          child: ui.CupertinoPageScaffold(child: Center(child: child)),
        ),
      );

  for (final selected in [AppearanceStyle.dark, AppearanceStyle.light]) {
    testWidgets(
      'appearance menu respects $selected against opposite system brightness',
      (tester) async {
        final brightness = selected == AppearanceStyle.dark
            ? Brightness.dark
            : Brightness.light;
        tester.platformDispatcher.platformBrightnessTestValue =
            brightness == Brightness.dark ? Brightness.light : Brightness.dark;
        addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
        final store = MemoryPlayerSettingsStore(
          PlayerSettings(appearanceStyle: selected.name),
        );
        final controller = AppearanceController(store: store);
        addTearDown(controller.dispose);
        await controller.ready;
        await tester.pumpWidget(
          ListenableBuilder(
            listenable: controller,
            builder: (context, _) => CupertinoTestApp(
              locale: const Locale('zh', 'CN'),
              supportedLocales: AppLocalizations.supportedLocales,
              localizationsDelegates: [
                AppLocalizations.delegate,
                ...GlobalCupertinoLocalizations.delegates,
              ],
              theme: controller.brightness == Brightness.dark
                  ? AppUiTheme.dark()
                  : AppUiTheme.light(),
              home: AppearanceScope(
                controller: controller,
                child: const CupertinoPageScaffold(
                  child: AppearanceMenuButton(),
                ),
              ),
            ),
          ),
        );
        final menu = find.byType(ui.AppMenuButton<AppearanceStyle>);
        expect(ui.AppUiTheme.of(tester.element(menu)).brightness, brightness);
        expect(
          ui.CupertinoTheme.brightnessOf(tester.element(menu)),
          brightness,
        );
        await tester.tap(find.byKey(AppearanceMenuButton.menuKey));
        await settle(tester);
        final dialog = tester.element(
          find.byKey(const Key('app-menu-content')),
        );
        expect(ui.AppUiTheme.of(dialog).brightness, brightness);
        expect(ui.CupertinoTheme.brightnessOf(dialog), brightness);
        await tester.tap(find.text('取消'));
        await settle(tester);
        expect(controller.style, selected);
        expect((await store.read()).appearanceStyle, selected.name);
        await tester.tap(find.byKey(AppearanceMenuButton.menuKey));
        await settle(tester);
        await tester.tap(
          find.text(selected == AppearanceStyle.dark ? '浅色' : '深色'),
        );
        await settle(tester);
        expect(controller.brightness, isNot(brightness));
        expect(
          ui.AppUiTheme.of(tester.element(menu)).brightness,
          controller.brightness,
        );
      },
    );
  }

  testWidgets(
    'Cupertino tooltip remains inside the viewport at the right edge',
    (tester) async {
      await tester.pumpWidget(
        cupertinoHost(
          const Align(
            alignment: Alignment.topRight,
            child: ui.AppTooltip(message: '服务器连接与账户设置', child: Text('设置')),
          ),
        ),
      );
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(find.text('设置')));
      await tester.pump();
      final rect = tester.getRect(find.text('服务器连接与账户设置'));
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(tester.view.physicalSize.width));
      await mouse.removePointer();
      await tester.pump();
    },
  );

  testWidgets(
    'Cupertino form keeps initial, controller, validation and reset values',
    (tester) async {
      final form = GlobalKey<FormState>();
      final controller = TextEditingController(text: '服务器');
      addTearDown(controller.dispose);
      String? saved;
      Widget page({bool external = true}) => cupertinoHost(
        Form(
          key: form,
          child: ui.AppTextField(
            key: const Key('cupertino-field'),
            controller: external ? controller : null,
            initialValue: external ? null : '初始地址',
            validator: (value) => value!.isEmpty ? '请输入地址' : null,
            onSaved: (value) => saved = value,
          ),
        ),
      );
      await tester.pumpWidget(page());
      expect(find.text('服务器'), findsOneWidget);
      controller.text = '';
      expect(form.currentState!.validate(), isFalse);
      await tester.pump();
      expect(find.text('请输入地址'), findsOneWidget);
      controller.text = 'https://example.test';
      expect(form.currentState!.validate(), isTrue);
      form.currentState!.save();
      expect(saved, 'https://example.test');
      form.currentState!.reset();
      await tester.pump();
      expect(controller.text, '服务器');
      await tester.pumpWidget(page(external: false));
      expect(find.text('服务器'), findsOneWidget);
      await tester.enterText(find.byType(ui.CupertinoTextField), '新地址');
      form.currentState!.save();
      expect(saved, '新地址');
      form.currentState!.reset();
      await tester.pump();
      expect(find.text('初始地址'), findsOneWidget);
    },
  );

  testWidgets(
    'Cupertino actions activate from keyboard and remote but respect disabled',
    (tester) async {
      final focus = FocusNode();
      addTearDown(focus.dispose);
      var count = 0;
      Widget page(bool enabled) => cupertinoHost(
        ui.AppButton(
          focusNode: focus,
          onPressed: enabled ? () => count++ : null,
          child: const Text('播放'),
        ),
      );
      await tester.pumpWidget(page(true));
      focus.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      expect(count, 3);
      await tester.pumpWidget(page(false));
      await tester.tap(find.text('播放'));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(count, 3);
    },
  );

  testWidgets(
    'Cupertino dialog captures local theme and Escape cancels without commit',
    (tester) async {
      final root = ui.AppUiTheme.light();
      final local = ui.AppUiTheme.tvDark();
      ui.AppUiThemeData? inside;
      String? result = 'pending';
      await tester.pumpWidget(
        cupertinoHost(
          ui.AppUiTheme(
            data: local,
            child: Builder(
              builder: (context) => ui.AppButton(
                onPressed: () async {
                  result = await ui.showAppDialog<String>(
                    context: context,
                    builder: (context) {
                      inside = ui.AppUiTheme.of(context);
                      return ui.AppDialog(
                        title: const Text('确认'),
                        content: const Text('保持当前设置'),
                        actions: [
                          ui.AppButton(
                            autofocus: true,
                            onPressed: () => Navigator.of(context).pop('saved'),
                            child: const Text('保存'),
                          ),
                        ],
                      );
                    },
                  );
                },
                child: const Text('打开'),
              ),
            ),
          ),
          theme: root,
        ),
      );
      await tester.tap(find.text('打开'));
      await settle(tester);
      expect(inside, same(local));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      expect(result, isNull);
      expect(find.text('保存'), findsNothing);
    },
  );

  test('light theme keeps AA contrast for body text and controls', () {
    final scheme = AppUiTheme.light().colorScheme;

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
    final dark = AppUiTheme.dark();
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
    expect(AppUiTheme.light().colorScheme.scrim, const Color(0xff000000));
    expect(dark.colorScheme.scrim, const Color(0xff000000));
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
    expect(controller.brightness, Brightness.dark);
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
    expect(controller.brightness, Brightness.dark);

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
      CupertinoTestApp(
        locale: const Locale('zh', 'CN'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: [
          AppLocalizations.delegate,
          ...GlobalCupertinoLocalizations.delegates,
        ],
        home: AppearanceScope(
          controller: controller,
          child: const CupertinoPageScaffold(child: SettingsPage()),
        ),
      ),
    );
    await settle(tester);

    await tester.tap(find.byKey(const ValueKey('settings-section-外观')));
    await settle(tester);
    expect(
      tester
          .widget<PlayerRateCell>(
            find.byKey(const ValueKey('settings-appearance-dark')),
          )
          .selected,
      isTrue,
    );

    await tester.tap(find.byKey(const ValueKey('settings-appearance-light')));
    await settle(tester);

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
    await settle(tester);

    expect(find.byKey(ConnectFormKeys.connectAppearanceKey), findsOneWidget);
    // 未保存过外观时默认深色。
    expect(controller.style, AppearanceStyle.dark);
    expect(
      tester.widget<CupertinoApp>(find.byType(CupertinoApp)).theme!.brightness,
      Brightness.dark,
    );

    await tester.tap(find.byKey(ConnectFormKeys.connectAppearanceKey));
    await settle(tester);
    await tester.tap(find.text('浅色').last);
    await settle(tester);

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
        CupertinoTestApp(
          locale: const Locale('zh', 'CN'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: [
            AppLocalizations.delegate,
            ...GlobalCupertinoLocalizations.delegates,
          ],
          home: AppearanceScope(
            controller: controller,
            child: AuthScope(
              controller: AuthController.memory(),
              child: const TvConnectPage(),
            ),
          ),
        ),
      );
      await settle(tester);

      final lightOption = find.byKey(const Key('tv-appearance-light'));
      final darkOption = find.byKey(const Key('tv-appearance-dark'));
      expect(find.byKey(const Key('tv-appearance-system')), findsOneWidget);
      expect(lightOption, findsOneWidget);
      expect(darkOption, findsOneWidget);

      // 选中浅色:按钮标记 selected,偏好即时生效并持久化。
      await tester.tap(lightOption);
      await settle(tester);
      expect(controller.style, AppearanceStyle.light);
      expect(tester.widget<TvAction>(lightOption).selected, isTrue);
      expect((await store.read()).appearanceStyle, 'light');

      // 方向键在选项间移动:焦点从浅色移到深色后按 SELECT 生效。
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await settle(tester);
      final focused = FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<TvAction>();
      expect(focused?.key, const Key('tv-appearance-dark'));

      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await settle(tester);
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
      CupertinoTestApp(
        locale: const Locale('zh', 'CN'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: [
          AppLocalizations.delegate,
          ...GlobalCupertinoLocalizations.delegates,
        ],
        home: AppearanceScope(
          controller: controller,
          child: const CupertinoPageScaffold(child: TvAppearancePicker()),
        ),
      ),
    );
    await settle(tester);

    final lightOption = find.byKey(const Key('tv-appearance-light'));
    final darkOption = find.byKey(const Key('tv-appearance-dark'));
    expect(find.byKey(const Key('tv-appearance-system')), findsOneWidget);
    expect(lightOption, findsOneWidget);
    expect(darkOption, findsOneWidget);
    expect(controller.style, AppearanceStyle.dark);
    expect(tester.widget<TvAction>(darkOption).selected, isTrue);

    await tester.tap(lightOption);
    await settle(tester);
    expect(controller.style, AppearanceStyle.light);
    expect(tester.widget<TvAction>(lightOption).selected, isTrue);
    expect(tester.widget<TvAction>(darkOption).selected, isFalse);
    expect((await store.read()).appearanceStyle, 'light');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await settle(tester);
    final focused = FocusManager.instance.primaryFocus?.context
        ?.findAncestorWidgetOfExactType<TvAction>();
    expect(focused?.key, const Key('tv-appearance-dark'));

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await settle(tester);
    expect(controller.style, AppearanceStyle.dark);
    expect(tester.widget<TvAction>(darkOption).selected, isTrue);
    expect((await store.read()).appearanceStyle, 'dark');
  });

  testWidgets('window caption buttons follow the theme brightness', (
    tester,
  ) async {
    await tester.pumpWidget(
      CupertinoTestApp(
        theme: AppUiTheme.light(),
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

  testWidgets('window caption colors follow the page theme', (tester) async {
    const channel = MethodChannel('com.rillight/window');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    int byteOf(Color color, int shift) => (color.toARGB32() >> shift) & 0xFF;

    void expectTone(MethodCall call, Tones tones, {required bool dark}) {
      expect(call.method, 'setCaptionColors');
      final args = call.arguments as Map;
      expect(args['dark'], dark);
      expect(args['captionRed'], byteOf(tones.base, 16));
      expect(args['captionGreen'], byteOf(tones.base, 8));
      expect(args['captionBlue'], byteOf(tones.base, 0));
      expect(args['symbolRed'], byteOf(tones.onSurface, 16));
      expect(args['symbolGreen'], byteOf(tones.onSurface, 8));
      expect(args['symbolBlue'], byteOf(tones.onSurface, 0));
    }

    await tester.pumpWidget(
      const CupertinoTestApp(
        home: WindowChromeHost(
          brightness: Brightness.light,
          child: SizedBox.expand(),
        ),
      ),
    );
    await tester.pump();
    expect(calls, hasLength(1));
    expectTone(calls.single, AppUiTheme.lightTones, dark: false);

    await tester.pumpWidget(
      const CupertinoTestApp(
        home: WindowChromeHost(
          brightness: Brightness.dark,
          child: SizedBox.expand(),
        ),
      ),
    );
    await tester.pump();
    expect(calls, hasLength(2));
    expectTone(calls.last, AppUiTheme.darkTones, dark: true);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}
