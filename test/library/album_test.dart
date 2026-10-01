import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/library/detail_extras.dart';

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==',
);

class _AlbumClient extends EmbyClient {
  _AlbumClient()
    : super(
        device: const EmbyDeviceInfo(
          clientName: 'Rillight',
          deviceName: 'test',
          deviceId: 'album-test',
          version: '0.1.0',
        ),
      );

  final originalRequests = <int>[];
  bool failOnce = false;
  List<int> original = _png;

  @override
  Future<List<int>> getItemImage(
    String itemId, {
    String type = 'Primary',
    String? tag,
    int? index,
    int maxWidth = 280,
    CancelToken? cancelToken,
  }) async => _png;

  @override
  Future<List<int>> getOriginalItemImage(
    String itemId, {
    String type = 'Backdrop',
    String? tag,
    int? index,
    CancelToken? cancelToken,
  }) async {
    originalRequests.add(index!);
    if (failOnce) {
      failOnce = false;
      throw const SocketException('Synthetic image failure');
    }
    return original;
  }
}

void main() {
  const item = EmbyItem(
    id: 'album',
    name: 'Album',
    type: 'Movie',
    backdropImageTags: ['a', 'b'],
  );
  const channel = MethodChannel('plugins.flutter.io/file_selector');

  Future<void> pumpAlbum(WidgetTester tester, _AlbumClient client) async {
    final auth = AuthController.memory(client: client);
    addTearDown(auth.dispose);
    await tester.pumpWidget(
      AuthScope(
        controller: auth,
        child: MaterialApp(
          locale: const Locale('zh', 'CN'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: const Scaffold(body: DetailAlbumStrip(item: item)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(InkWell).first);
    await tester.pumpAndSettle();
  }

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('album entry requires at least two images', () {
    for (final tags in <List<String>>[
      [],
      ['one'],
    ]) {
      expect(
        detailAlbumOf(
          EmbyItem(
            id: 'single',
            name: 'Single',
            type: 'Movie',
            backdropImageTags: tags,
          ),
        ),
        isNull,
      );
      expect(
        detailAlbumOf(
          EmbyItem(
            id: 'episode',
            name: 'Episode',
            type: 'Episode',
            parentBackdropItemId: 'series',
            parentBackdropImageTags: tags,
          ),
        ),
        isNull,
      );
    }
    expect(detailAlbumOf(item)?.tags, ['a', 'b']);
    expect(
      detailAlbumOf(
        const EmbyItem(
          id: 'episode',
          name: 'Episode',
          type: 'Episode',
          backdropImageTags: ['one'],
          parentBackdropItemId: 'series',
          parentBackdropImageTags: ['a', 'b'],
        ),
      )?.itemId,
      'series',
    );
  });

  testWidgets('enlargement supports zoom and keyboard paging', (tester) async {
    final client = _AlbumClient();
    await pumpAlbum(tester, client);
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.byType(InteractiveViewer), findsWidgets);
    expect(find.text('1 / 2'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(find.text('2 / 2'), findsOneWidget);
    expect(client.originalRequests, containsAll([0, 1]));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'download saves original bytes and reuses the displayed request',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync('rillight-album-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final output = File('${directory.path}/original.png');
      Map<dynamic, dynamic>? arguments;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'getSavePath');
            arguments = call.arguments as Map<dynamic, dynamic>;
            return output.path;
          });
      final client = _AlbumClient();
      await pumpAlbum(tester, client);
      await tester.tap(find.text('下载原图'));
      for (var i = 0; i < 100; i++) {
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        if (output.existsSync() &&
            output.lengthSync() == client.original.length &&
            tester
                    .widget<TextButton>(
                      find.ancestor(
                        of: find.text('下载原图'),
                        matching: find.byType(TextButton),
                      ),
                    )
                    .onPressed !=
                null) {
          break;
        }
      }
      await tester.pump();
      expect(output.readAsBytesSync(), client.original);
      await tester.pumpAndSettle();
      expect(arguments?['suggestedName'], 'rillight-album-1.png');
      expect(client.originalRequests.where((i) => i == 0), hasLength(1));
      expect(find.text('图片已保存'), findsOneWidget);
    },
  );

  testWidgets('cancel download keeps the viewer usable', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => null);
    await pumpAlbum(tester, _AlbumClient());
    await tester.tap(find.text('下载原图'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.text('图片已保存'), findsNothing);
    expect(find.text('图片保存失败，请重试'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('original request failure can retry', (tester) async {
    final client = _AlbumClient()..failOnce = true;
    await pumpAlbum(tester, client);
    expect(find.textContaining('重试'), findsOneWidget);
    await tester.tap(find.textContaining('重试'));
    await tester.pumpAndSettle();
    expect(find.textContaining('重试'), findsNothing);
    expect(client.originalRequests.where((i) => i == 0), hasLength(2));
    expect(tester.takeException(), isNull);
  });
}
