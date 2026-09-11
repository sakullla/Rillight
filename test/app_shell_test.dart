import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/product.dart';
import 'package:rillight/app/widgets/app_error_view.dart';
import 'package:rillight/app/widgets/poster_placeholder.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/auth/session_actions.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/home/catalog_keys.dart';

import 'emby/fake_emby_server.dart';

const _device = EmbyDeviceInfo(
  clientName: 'Rillight',
  deviceName: 'test',
  deviceId: 'device-app-shell',
  version: '0.1.0',
);

void main() {
  testWidgets('shell shows product name in Chinese locale', (tester) async {
    await tester.pumpWidget(RillightApp());
    await tester.pumpAndSettle();

    expect(find.text(kProductName), findsWidgets);
  });

  testWidgets('app forces cinematic dark ThemeMode', (tester) async {
    await tester.pumpWidget(RillightApp());
    await tester.pumpAndSettle();

    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.themeMode, ThemeMode.dark);
    expect(app.theme?.brightness, Brightness.dark);
    expect(app.darkTheme?.brightness, Brightness.dark);
    expect(
      Theme.of(tester.element(find.byType(Scaffold))).brightness,
      Brightness.dark,
    );
  });

  testWidgets('AppErrorView shows failure message and retry', (tester) async {
    var retried = false;

    await tester.pumpWidget(
      _l10nApp(AppErrorView(message: '无法连接服务器', onRetry: () => retried = true)),
    );

    expect(find.text('无法连接服务器'), findsOneWidget);
    await tester.tap(find.text('重试'));
    expect(retried, isTrue);
  });

  testWidgets('PosterPlaceholder remains available after image failure', (
    tester,
  ) async {
    await tester.pumpWidget(
      _l10nApp(
        const SizedBox(width: 120, height: 180, child: PosterPlaceholder()),
      ),
    );

    expect(find.byType(PosterPlaceholder), findsOneWidget);
    expect(find.byIcon(Icons.movie_outlined), findsOneWidget);
    expect(find.bySemanticsLabel('封面不可用'), findsOneWidget);
  });

  testWidgets(
    'logged-in shell is full-width and switching servers reloads home',
    (tester) async {
      final first = FakeEmbyServer();
      final second = FakeEmbyServer(
        serverId: 'server-id-2',
        serverName: '第二台',
        baseUrl: Uri.parse('http://emby-two.test:8096'),
        items: [
          FakeEmbyItem(
            id: 'movie-second',
            name: '第二台电影',
            type: 'Movie',
            parentId: 'view-movies',
            primaryImageTag: 'tag-second',
          ),
        ],
      );
      final adapter = FakeEmbyAdapter([first, second]);
      final auth = AuthController(
        client: EmbyClient(device: _device, dio: dioForFakeEmby(adapter)),
        credentials: MemoryCredentialStore(),
        servers: MemoryServerListStore(),
      );
      await tester.runAsync(() async {
        await auth.connect(
          address: first.baseUrl.toString(),
          username: 'alice',
          password: 'correct-horse',
        );
        await auth.connect(
          address: second.baseUrl.toString(),
          username: 'alice',
          password: 'correct-horse',
        );
      });
      expect(auth.session?.server.name, '第二台');

      await tester.pumpWidget(RillightApp(auth: auth));
      await tester.pumpAndSettle();

      expect(find.byType(NavigationRail), findsNothing);
      expect(find.byKey(SessionActions.serverMenuKey), findsOneWidget);
      expect(find.text('第二台'), findsOneWidget);
      expect(find.text('第二台电影'), findsWidgets);

      await tester.tap(find.byKey(CatalogKeys.librariesMenu));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(CatalogKeys.library('view-movies')));
      await tester.pumpAndSettle();

      bool isHomeCatalog(String request) {
        return request.contains('Items/Resume') ||
            request.contains('Items/Latest') ||
            request.contains('Views') ||
            request.contains('NextUp');
      }

      final firstHomeBefore = first.requests.where(isHomeCatalog).length;

      await tester.tap(find.byKey(SessionActions.serverMenuKey));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(PopupMenuItem<String>, '灯川测试'));
      await tester.pumpAndSettle();

      expect(auth.session?.server.name, '灯川测试');
      expect(find.text('灯川测试'), findsOneWidget);
      expect(find.text('Inception'), findsWidgets);
      expect(find.text('第二台电影'), findsNothing);
      expect(find.byType(NavigationRail), findsNothing);
      expect(
        first.requests.where(isHomeCatalog).length,
        greaterThan(firstHomeBefore),
      );
    },
  );
}

Widget _l10nApp(Widget home) {
  return MaterialApp(
    locale: const Locale('zh', 'CN'),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    home: home,
  );
}
