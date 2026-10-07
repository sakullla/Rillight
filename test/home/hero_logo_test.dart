import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/catalog_cache.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/hero_logo.dart';
import 'package:rillight/media_image/media_image.dart';

import '../helpers/image_cache_fixture.dart';

void main() {
  const fallback = Text('Text title', key: Key('fallback'));
  const item = EmbyItem(
    id: 'movie',
    name: 'Movie',
    type: 'Movie',
    logoImageTag: 'logo-tag',
  );

  test('the model reads ImageTags.Logo', () {
    final parsed = EmbyItem.fromJson({
      'Id': 'movie',
      'Name': 'Movie',
      'Type': 'Movie',
      'ImageTags': {'Primary': 'p', 'Logo': 'l'},
    });
    expect(parsed.logoImageTag, 'l');
    expect(parsed.copyWith().logoImageTag, 'l');
    expect(HeroLogo.available(parsed), isTrue);
    expect(
      HeroLogo.available(const EmbyItem(id: 'x', name: '', type: 'Movie')),
      isFalse,
    );
  });

  test('only carousel feeds ask the server for logos', () {
    final plain = catalogItemsRequest(userId: 'u');
    final featured = catalogItemsRequest(
      userId: 'u',
      imageTypes: EmbyClient.featuredImageTypes,
    );
    expect(plain.query!['EnableImageTypes'], EmbyClient.imageTypes);
    expect(plain.query!['EnableImageTypes'], isNot(contains('Logo')));
    expect(featured.query!['EnableImageTypes'], contains('Logo'));
  });

  testWidgets('without a session or a logo tag the text title shows', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: HeroLogo(
          item: item,
          fallback: fallback,
          maxWidth: 400,
          maxHeight: 120,
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
        device: const EmbyDeviceInfo(
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
