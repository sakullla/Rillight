import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/app/presentation_environment.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/library/detail_extras.dart';

import '../emby/fake_emby_server.dart';
import '../helpers/image_cache_fixture.dart';

void main() {
  for (final environment in [
    PresentationEnvironment.phone,
    PresentationEnvironment.tv,
  ]) {
    testWidgets(
      '${environment.presentation.name} direct detail navigation replaces the displayed item',
      (tester) async {
        isolateImageCache();
        tester.view.physicalSize = environment.isTv
            ? const Size(1920, 1080)
            : const Size(412, 915);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final server = FakeEmbyServer();
        final auth = AuthController.memory(
          client: EmbyClient(
            device: const EmbyDeviceInfo(
              clientName: 'test',
              deviceName: 'test',
              deviceId: 'route-identity',
              version: '1',
            ),
            dio: dioForFakeEmby(FakeEmbyAdapter([server])),
          ),
        );
        await tester.runAsync(
          () => auth.connect(
            address: server.baseUrl.toString(),
            username: 'alice',
            password: 'correct-horse',
          ),
        );
        final app = RillightApp(auth: auth, environment: environment);
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          app.router.dispose();
          auth.dispose();
        });
        await tester.pumpWidget(app);
        for (final id in ['movie-up', 'movie-inception']) {
          app.router.go('/item/$id');
          await tester.pumpAndSettle();
          expect(
            tester
                .widget<DetailAlbumStrip>(find.byType(DetailAlbumStrip))
                .item
                .id,
            id,
          );
        }
      },
      tags: ['integration'],
    );
  }
}
