import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/tv_widgets.dart';
import 'package:rillight/app/ui/ui.dart';
import 'package:rillight/app/widgets/app_empty_view.dart';
import 'package:rillight/app/widgets/app_error_view.dart';
import 'package:rillight/home/catalog_failure.dart';
import 'package:rillight/media_server/errors.dart';

import '../helpers/cupertino_test_app.dart';

void main() {
  group('homeFailureKind', () {
    test('treats network-down socket codes as device offline', () {
      for (final code in const [
        100,
        101,
        112,
        113, // Linux/Android
        50,
        51,
        64,
        65, // macOS/iOS
        10050,
        10051,
        10064,
        10065, // Windows
      ]) {
        final error = MediaServerException(
          MediaServerFailureKind.unreachable,
          cause: _socket(code),
        );
        expect(
          homeFailureKind(error, hasLibraries: false),
          HomeFailureKind.deviceOffline,
          reason: 'errno $code should mean the device has no network',
        );
        expect(
          homeFailureKind(error, hasLibraries: true),
          HomeFailureKind.deviceOffline,
          reason: 'library presence must not change the classification',
        );
      }
    });

    test('treats refused connections and timeouts as server offline', () {
      for (final code in const [111, 61, 10061]) {
        final error = MediaServerException(
          MediaServerFailureKind.unreachable,
          cause: _socket(code),
        );
        expect(
          homeFailureKind(error, hasLibraries: false),
          HomeFailureKind.serverOffline,
          reason: 'refused errno $code keeps the network, server is down',
        );
      }
      expect(
        homeFailureKind(
          const MediaServerException(MediaServerFailureKind.timeout),
          hasLibraries: false,
        ),
        HomeFailureKind.serverOffline,
      );
      expect(
        homeFailureKind(
          const MediaServerException(MediaServerFailureKind.unreachable),
          hasLibraries: false,
        ),
        HomeFailureKind.serverOffline,
      );
    });

    test('walks a Dio cause chain to the socket error code', () {
      final error = MediaServerException(
        MediaServerFailureKind.unreachable,
        cause: DioException(
          requestOptions: RequestOptions(path: '/Users'),
          type: DioExceptionType.connectionError,
          error: _socket(10051),
        ),
      );
      expect(
        homeFailureKind(error, hasLibraries: false),
        HomeFailureKind.deviceOffline,
      );
    });

    test('classifies a missing error as an empty library', () {
      expect(homeFailureKind(null, hasLibraries: false), HomeFailureKind.empty);
      expect(homeFailureKind(null, hasLibraries: true), HomeFailureKind.empty);
    });
  });

  group('homeFailureCopy', () {
    testWidgets(
      'gives empty, device-offline and server-offline distinct copy',
      (tester) async {
        late HomeFailureCopy empty;
        late HomeFailureCopy emptyWithoutLibraries;
        late HomeFailureCopy device;
        late HomeFailureCopy server;
        late HomeFailureCopy serverWithLine;
        await tester.pumpWidget(
          _app(
            Builder(
              builder: (context) {
                final l10n = AppLocalizations.of(context);
                empty = homeFailureCopy(
                  l10n,
                  HomeFailureKind.empty,
                  hasLibraries: true,
                );
                emptyWithoutLibraries = homeFailureCopy(
                  l10n,
                  HomeFailureKind.empty,
                  hasLibraries: false,
                );
                device = homeFailureCopy(
                  l10n,
                  HomeFailureKind.deviceOffline,
                  hasLibraries: false,
                );
                server = homeFailureCopy(
                  l10n,
                  HomeFailureKind.serverOffline,
                  hasLibraries: false,
                );
                serverWithLine = homeFailureCopy(
                  l10n,
                  HomeFailureKind.serverOffline,
                  hasLibraries: false,
                  hasAlternateLine: true,
                );
                return const SizedBox.shrink();
              },
            ),
          ),
        );

        expect({empty.title, device.title, server.title}, hasLength(3));
        expect(empty.primaryLabel, '去媒体库');
        expect(empty.secondaryLabel, '刷新');
        expect(empty.message, contains('媒体库'));
        expect(emptyWithoutLibraries.primaryLabel, '切换服务器');
        expect(device.primaryLabel, '重试');
        expect(device.secondaryLabel, '切换服务器');
        expect(server.primaryLabel, '重试');
        expect(server.secondaryLabel, '切换服务器');
        expect(serverWithLine.secondaryLabel, '更换线路');
      },
    );
  });

  testWidgets('AppErrorView exposes primary and secondary actions', (
    tester,
  ) async {
    var primary = 0;
    var secondary = 0;
    await tester.pumpWidget(
      _app(
        AppErrorView(
          title: '设备未联网',
          message: '当前设备没有可用的网络连接，请检查 Wi-Fi 或网线后重试。',
          primaryLabel: '重试',
          onPrimary: () => primary++,
          secondaryLabel: '切换服务器',
          onSecondary: () => secondary++,
        ),
      ),
    );

    expect(find.text('设备未联网'), findsOneWidget);
    expect(find.textContaining('网络连接'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pump();
    expect(primary, 1);
    await tester.tap(find.text('切换服务器'));
    await tester.pump();
    expect(secondary, 1);
  });

  testWidgets('AppEmptyView exposes primary and secondary actions', (
    tester,
  ) async {
    var primary = 0;
    var secondary = 0;
    await tester.pumpWidget(
      _app(
        AppEmptyView(
          title: '这个服务器还没有内容',
          message: '媒体库里还没有可显示的影片或剧集。',
          primaryLabel: '去媒体库',
          onPrimary: () => primary++,
          secondaryLabel: '刷新',
          onSecondary: () => secondary++,
        ),
      ),
    );

    expect(find.text('这个服务器还没有内容'), findsOneWidget);
    await tester.tap(find.text('去媒体库'));
    await tester.pump();
    expect(primary, 1);
    await tester.tap(find.text('刷新'));
    await tester.pump();
    expect(secondary, 1);
  });

  testWidgets('TvEmptyState accepts the same title and action set', (
    tester,
  ) async {
    var primary = 0;
    var secondary = 0;
    await tester.pumpWidget(
      _app(
        TvEmptyState(
          title: '无法连接服务器',
          message: '服务器没有响应，请确认服务器已启动。',
          primaryLabel: '重试',
          onPrimary: () => primary++,
          secondaryLabel: '切换服务器',
          onSecondary: () => secondary++,
        ),
      ),
    );

    expect(find.text('无法连接服务器'), findsOneWidget);
    expect(find.text('服务器没有响应，请确认服务器已启动。'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pump();
    expect(primary, 1);
    await tester.tap(find.text('切换服务器'));
    await tester.pump();
    expect(secondary, 1);
  });
}

SocketException _socket(int code) {
  return SocketException('net', osError: OSError('errno $code', code));
}

Widget _app(Widget child) {
  return CupertinoTestApp(
    theme: AppUiTheme.dark(),
    home: CupertinoPageScaffold(child: child),
  );
}
