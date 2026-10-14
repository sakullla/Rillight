import 'package:rillight/app/ui/ui.dart' as ui;

import '../helpers/widget_harness.dart';

import 'package:rillight/emby/emby_codec.dart';

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart' hide testWidgets;
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/catalog_cache.dart';
import 'package:rillight/media_server/media_server_client.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/media_server/device.dart';
import 'package:rillight/home/hero_logo.dart';
import 'package:rillight/media_image/media_image.dart';

import '../helpers/image_cache_fixture.dart';
import '../emby/fake_emby_server.dart';

void main() {
  const fallback = Text('Text title', key: Key('fallback'));
  const item = MediaItem(
    id: 'movie',
    name: 'Movie',
    type: 'Movie',
    logoImageTag: 'logo-tag',
  );

  test('the model reads ImageTags.Logo', () {
    final parsed = decodeEmbyMediaItem({
      'Id': 'movie',
      'Name': 'Movie',
      'Type': 'Movie',
      'ImageTags': {'Primary': 'p', 'Logo': 'l'},
    });
    expect(parsed.logoImageTag, 'l');
    expect(parsed.copyWith().logoImageTag, 'l');
    expect(HeroLogo.available(parsed), isTrue);
    expect(
      HeroLogo.available(const MediaItem(id: 'x', name: '', type: 'Movie')),
      isFalse,
    );
  });

  test('only carousel feeds ask the server for logos', () async {
    final plain = catalogItemsRequest(userId: 'u');
    final featured = catalogItemsRequest(
      userId: 'u',
      imageTypes: MediaServerClient.featuredImageTypes,
    );
    expect(plain.query!['enableImageTypes'], MediaServerClient.imageTypes);
    expect(
      featured.query!['enableImageTypes'],
      MediaServerClient.featuredImageTypes,
    );

    final server = FakeEmbyServer();
    final client = EmbyClient(
      device: const ClientDeviceInfo(
        clientName: 'test',
        deviceName: 'test',
        deviceId: 'logo-projection',
        version: '1',
      ),
      dio: dioForFakeEmby(FakeEmbyAdapter([server])),
    );
    final session = await client.authenticateByName(
      baseUrl: server.baseUrl,
      username: 'alice',
      password: 'correct-horse',
      serverId: server.serverId,
    );
    client.attachSession(
      baseUrl: server.baseUrl,
      accessToken: session.accessToken,
      userId: session.user.id,
    );
    addTearDown(client.clearSession);
    for (final request in [plain, featured]) {
      await executeCatalogRequest(client, request);
      final query = Uri.parse(server.requests.last.split(' ').last)
          .queryParameters;
      final imageTypes = query['EnableImageTypes']!.split(',');
      expect(imageTypes, containsAll(['Primary', 'Backdrop', 'Thumb']));
      expect(imageTypes.contains('Logo'), identical(request, featured));
    }
  });

  testWidgets('without a session or a logo tag the text title shows', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: HeroLogo(
          item: item,
          fallback: fallback,
          maxWidth: 400,
          maxHeight: 120,
        ),
        localizationsDelegates: ui.GlobalCupertinoLocalizations.delegates,
        builder: (context, child) => ui.AppUiTheme(
          data: Theme.of(context).brightness == Brightness.dark
              ? ui.AppUiTheme.dark()
              : ui.AppUiTheme.light(),
          child: child ?? const SizedBox.shrink(),
        ),
      ),
    );
    expect(find.byKey(const Key('fallback')), findsOneWidget);
  });

  Future<(AuthController, _LogoClient)> session(Uint8List logo) async {
    final client = _LogoClient(logo);
    final auth = AuthController.memory(client: client);
    addTearDown(auth.dispose);
    return (auth, client);
  }

  Widget subject(AuthController auth, {bool prefetch = false}) => MaterialApp(
    home: AuthScope(
      controller: auth,
      child: Align(
        alignment: Alignment.topLeft,
        child: HeroLogo(
          item: item,
          fallback: fallback,
          maxWidth: 400,
          maxHeight: 120,
          prefetch: prefetch,
        ),
      ),
    ),
    localizationsDelegates: ui.GlobalCupertinoLocalizations.delegates,
    builder: (context, child) => ui.AppUiTheme(
      data: Theme.of(context).brightness == Brightness.dark
          ? ui.AppUiTheme.dark()
          : ui.AppUiTheme.light(),
      child: child ?? const SizedBox.shrink(),
    ),
  );

  testWidgets('a wide logo fits the width budget at its own aspect', (
    tester,
  ) async {
    isolateImageCache();
    addTearDown(MediaImage.debugClearCache);
    addTearDown(MediaImage.debugResetCacheConfiguration);
    final bytes = (await tester.runAsync(() => _png(800, 200)))!;
    final (auth, client) = await session(bytes);
    await tester.pumpWidget(subject(auth));
    // While loading, the slot reserves space instead of flashing the text.
    expect(find.byKey(const Key('fallback')), findsNothing);
    await _pumpUntil(tester, () => find.byType(Image).evaluate().isNotEmpty);
    final size = tester.getSize(find.byType(Image));
    expect(size.width, closeTo(400, .5));
    expect(size.height, closeTo(100, .5));
    expect(client.requests.single.$1, 'Logo');

    // Coming back to the slide hits the cache on the first frame.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(subject(auth));
    expect(find.byType(Image), findsOneWidget);
    expect(client.requests, hasLength(1));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a tall logo is capped by height', (tester) async {
    isolateImageCache();
    addTearDown(MediaImage.debugClearCache);
    addTearDown(MediaImage.debugResetCacheConfiguration);
    final bytes = (await tester.runAsync(() => _png(300, 300)))!;
    final (auth, _) = await session(bytes);
    await tester.pumpWidget(subject(auth));
    await _pumpUntil(tester, () => find.byType(Image).evaluate().isNotEmpty);
    expect(tester.getSize(find.byType(Image)), const Size(120, 120));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('broken or sliver-shaped logos fall back to text', (
    tester,
  ) async {
    isolateImageCache();
    addTearDown(MediaImage.debugClearCache);
    addTearDown(MediaImage.debugResetCacheConfiguration);
    final (auth, _) = await session(Uint8List.fromList([1, 2, 3]));
    await tester.pumpWidget(subject(auth));
    await _pumpUntil(
      tester,
      () => find.byKey(const Key('fallback')).evaluate().isNotEmpty,
    );
    await tester.pumpWidget(const SizedBox());

    MediaImage.debugClearCache();
    final sliver = (await tester.runAsync(() => _png(40, 400)))!;
    final (tall, _) = await session(sliver);
    await tester.pumpWidget(subject(tall));
    await _pumpUntil(
      tester,
      () => find.byKey(const Key('fallback')).evaluate().isNotEmpty,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('prefetch paints nothing', (tester) async {
    isolateImageCache();
    addTearDown(MediaImage.debugClearCache);
    addTearDown(MediaImage.debugResetCacheConfiguration);
    final bytes = (await tester.runAsync(() => _png(800, 200)))!;
    final (auth, client) = await session(bytes);
    await tester.pumpWidget(subject(auth, prefetch: true));
    await _pumpUntil(tester, () => client.requests.isNotEmpty);
    await tester.pump();
    expect(find.byType(Image), findsNothing);
    expect(find.byKey(const Key('fallback')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}

Future<Uint8List> _png(int width, int height) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawColor(Colors.white, BlendMode.src);
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return bytes!.buffer.asUint8List();
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() ready) async {
  for (var attempt = 0; attempt < 50 && !ready(); attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  expect(ready(), isTrue);
}

class _LogoClient extends EmbyClient {
  _LogoClient(this.logo)
    : super(
        device: const ClientDeviceInfo(
          clientName: 'test',
          deviceName: 'test',
          deviceId: 'hero-logo',
          version: '1',
        ),
      ) {
    attachSession(
      baseUrl: Uri.parse('https://logo.example/emby'),
      accessToken: 'synthetic',
      userId: 'test',
    );
  }

  final Uint8List logo;
  final requests = <(String, int)>[];

  @override
  Future<List<int>> getItemImage(
    String itemId, {
    String type = 'Primary',
    int? index,
    String? tag,
    int maxWidth = 280,
    CancelToken? cancelToken,
  }) async {
    requests.add((type, maxWidth));
    return logo;
  }
}
