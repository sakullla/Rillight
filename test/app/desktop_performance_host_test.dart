import 'dart:ui' show FrameTiming;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/app_shell.dart';
import 'package:rillight/app/desktop_performance_host.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/app/widgets/backdrop_scrim.dart';
import 'package:rillight/app/widgets/liquid_glass.dart';

FrameTiming _frame({int buildUs = 1000, int rasterUs = 1000, int start = 0}) =>
    FrameTiming(
      vsyncStart: start,
      buildStart: start,
      buildFinish: start + buildUs,
      rasterStart: start + buildUs,
      rasterFinish: start + buildUs + rasterUs,
      rasterFinishWallTime: start + buildUs + rasterUs,
    );

void _report(WidgetTester tester, List<FrameTiming> frames) =>
    tester.binding.platformDispatcher.onReportTimings!(frames);

Widget _subject({bool monitor = true, bool reduced = false}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: reduced),
    child: DesktopPerformanceHost(
      monitorTimings: monitor,
      child: const Center(child: LiquidGlass(child: Text('操作仍可用'))),
    ),
  ),
);

void main() {
  testWidgets('automatic reduction preserves immersive bar and backdrop', (
    tester,
  ) async {
    final router = GoRouter(
      initialLocation: '/item/test',
      routes: [
        ShellRoute(
          builder: (context, state, child) => AppShell(child: child),
          routes: [
            GoRoute(
              path: '/item/:id',
              builder: (context, state) =>
                  const BackdropScrim(backdrop: ColoredBox(color: Colors.blue)),
            ),
          ],
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      MaterialApp.router(
        theme: AppTheme.dark(),
        locale: const Locale('zh', 'CN'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        routerConfig: router,
        builder: (context, child) =>
            DesktopPerformanceHost(monitorTimings: true, child: child!),
      ),
    );
    await tester.pumpAndSettle();
    List<Gradient> gradients() => [
      for (final box in tester.widgetList<DecoratedBox>(
        find.byType(DecoratedBox),
      ))
        if (box.decoration is BoxDecoration &&
            (box.decoration as BoxDecoration).gradient != null)
          (box.decoration as BoxDecoration).gradient!,
    ];
    final before = gradients();
    expect(before, hasLength(4));
    _report(tester, [for (var i = 0; i < 12; i++) _frame(rasterUs: 100000)]);
    await tester.pump();
    expect(
      MediaQuery.disableAnimationsOf(
        tester.element(find.byKey(AppShell.topBarKey)),
      ),
      isTrue,
    );
    expect(gradients(), before);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sustained raster overruns reduce effects and stay reduced', (
    tester,
  ) async {
    await tester.pumpWidget(_subject());
    final glassElement = tester.element(find.byType(LiquidGlass));
    expect(find.byType(BackdropFilter), findsOneWidget);
    _report(tester, [
      for (var i = 0; i < 4; i++) _frame(),
      for (var i = 0; i < 7; i++) _frame(rasterUs: 100000),
    ]);
    await tester.pump();
    expect(find.byType(BackdropFilter), findsOneWidget);
    _report(tester, [_frame(rasterUs: 100000)]);
    await tester.pump();
    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.text('操作仍可用'), findsOneWidget);
    expect(
      identical(tester.element(find.byType(LiquidGlass)), glassElement),
      isTrue,
    );
    _report(tester, [for (var i = 0; i < 30; i++) _frame()]);
    await tester.pump();
    expect(find.byType(BackdropFilter), findsNothing);
    await tester.pumpWidget(const SizedBox());
    _report(tester, [_frame(rasterUs: 100000)]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('build delays and isolated raster spikes do not reduce effects', (
    tester,
  ) async {
    await tester.pumpWidget(_subject());
    _report(tester, [for (var i = 0; i < 30; i++) _frame(buildUs: 100000)]);
    _report(tester, [_frame(rasterUs: 100000)]);
    _report(tester, [for (var i = 0; i < 30; i++) _frame()]);
    await tester.pump();
    expect(find.byType(BackdropFilter), findsOneWidget);
  });

  testWidgets(
    'monitoring can stop and restart without retaining slow samples',
    (tester) async {
      await tester.pumpWidget(_subject());
      _report(tester, [for (var i = 0; i < 7; i++) _frame(rasterUs: 100000)]);
      await tester.pumpWidget(_subject(monitor: false));
      _report(tester, [for (var i = 0; i < 12; i++) _frame(rasterUs: 100000)]);
      await tester.pump();
      expect(find.byType(BackdropFilter), findsOneWidget);
      await tester.pumpWidget(_subject());
      _report(tester, [
        for (var i = 0; i < 7; i++) _frame(rasterUs: 100000),
        for (var i = 0; i < 5; i++) _frame(),
      ]);
      await tester.pump();
      expect(find.byType(BackdropFilter), findsOneWidget);
    },
  );

  testWidgets('system reduced motion is preserved without raster pressure', (
    tester,
  ) async {
    await tester.pumpWidget(_subject(reduced: true));
    expect(find.byType(BackdropFilter), findsNothing);
  });

  testWidgets('slow frames separated by idle periods do not reduce effects', (
    tester,
  ) async {
    await tester.pumpWidget(_subject());
    _report(tester, [
      for (var i = 0; i < 30; i++) _frame(rasterUs: 100000, start: i * 1000000),
    ]);
    await tester.pump();
    expect(find.byType(BackdropFilter), findsOneWidget);
  });
}
