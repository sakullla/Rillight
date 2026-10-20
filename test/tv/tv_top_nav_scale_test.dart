import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/tv_top_nav.dart';
import 'package:rillight/app/ui/ui.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';

import '../helpers/cupertino_test_app.dart';

/// TV 顶栏在 200% 文字放大下仍要一行放下四个入口,不产生横向溢出。
void main() {
  Widget host({required int index, required String? username}) {
    final home = FocusNode();
    final auth = AuthController.memory();
    addTearDown(home.dispose);
    addTearDown(auth.dispose);
    return CupertinoTestApp(
      theme: AppUiTheme.tvDark(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: const TextScaler.linear(2)),
        child: AuthScope(controller: auth, child: child!),
      ),
      home: CupertinoPageScaffold(
        child: Align(
          alignment: Alignment.topLeft,
          child: TvTopNavBar(
            index: index,
            username: username,
            homeNode: home,
            onSelect: (_) {},
            onEnter: (_) {},
          ),
        ),
      ),
    );
  }

  Future<void> pumpNav(
    WidgetTester tester, {
    required int index,
    required String? username,
  }) async {
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(host(index: index, username: username));
    await tester.pump();
  }

  void expectNoOverflow(WidgetTester tester) {
    // 溢出会以 FlutterError 冒到测试里;先取走再断言,失败时带上原始信息。
    final error = tester.takeException();
    expect(error, isNull, reason: 'TV 顶栏在 200% 文字下不应溢出: $error');
  }

  testWidgets('960×540 画布、200% 文字、带用户名片时不横向溢出', (tester) async {
    await pumpNav(tester, index: 0, username: '长名字的客厅电视服务器');
    expectNoOverflow(tester);

    for (var i = 0; i < 4; i++) {
      expect(
        find.byKey(ValueKey('tv-nav-$i')),
        findsOneWidget,
        reason: '四个导航入口必须全部保留',
      );
    }
    expect(find.byKey(const ValueKey('tv-nav-4')), findsNothing);
  });

  testWidgets('200% 文字下品牌字标让位,只保留品牌图形', (tester) async {
    await pumpNav(tester, index: 0, username: null);
    expectNoOverflow(tester);

    expect(find.text('灯川 Rillight'), findsNothing);
    expect(find.bySemanticsLabel('灯川 Rillight'), findsOneWidget);
  });
}
