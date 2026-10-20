import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:rillight/app/ui/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/cloud_credentials.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/provider_connect_dialog.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/jellyfin/jellyfin_client.dart';
import 'package:rillight/media_server/capabilities.dart';
import 'package:rillight/media_server/device.dart';
import 'package:rillight/media_server/media_server_client.dart';
import 'package:rillight/media_image/media_image.dart';
import 'package:rillight/plex/plex_authentication.dart';
import 'package:rillight/plex/plex_client.dart';
import 'package:rillight/player/player_keys.dart';
import 'package:rillight/player/mobile_player_page.dart';
import 'package:rillight/player/player_controller.dart';
import 'package:rillight/player/player_page.dart';
import 'package:rillight/player/tv_player_page.dart';
import 'package:rillight/player/playback_session_snapshot.dart';

import '../../test/emby/fake_emby_server.dart';
import '../../test/jellyfin/fake_jellyfin_server.dart';
import '../../test/plex/fake_plex.dart';
import 'capture.dart';
import 'fixtures.dart';
import 'pages.dart';

/// The same independent protocol fixtures used in acceptance, connected through
/// real loopback HTTP. Only the video backend remains a visual prototype.
class _RealHttpOverrides extends HttpOverrides {}

class CaptureProviders {
  CaptureProviders(this.embyAdapter, CredentialStore credentials) {
    plex.includeOwnedResource = true;
    final cloud = CloudCredentialStore(credentials);
    plexAuthentication = PlexAuthentication(
      device: device,
      dio: dio(),
      accountUrl: plex.url,
      homeUrl: plex.url,
      readCredential: cloud.readCredential,
      writeCredential: cloud.writeCredential,
      deleteCredential: cloud.deleteCredential,
    );
  }

  static JellyfinFakeServer jellyfin = JellyfinFakeServer();
  static FakePlex plex = FakePlex();
  static final _clients = <Dio>[];
  static void closeClients() {
    for (final client in _clients) {
      client.close(force: true);
    }
    _clients.clear();
  }

  static void reset() {
    jellyfin = JellyfinFakeServer();
    plex = FakePlex();
  }

  final CaptureAdapter embyAdapter;
  late final PlexAuthentication plexAuthentication;
  static const device = ClientDeviceInfo(
    clientName: 'Rillight',
    deviceName: 'UI capture',
    deviceId: 'test-device',
    version: 'synthetic',
  );

  static Dio dio() {
    final client = Dio()
      ..httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () => HttpOverrides.runWithHttpOverrides(
          HttpClient.new,
          _RealHttpOverrides(),
        ),
      );
    _clients.add(client);
    return client;
  }

  MediaServerClient create(MediaServerType type) => switch (type) {
    MediaServerType.emby => EmbyClient(
      device: device,
      dio: dioForFakeEmby(embyAdapter),
    ),
    MediaServerType.jellyfin => JellyfinClient(device: device, dio: dio()),
    MediaServerType.plex => PlexClient(device: device, dio: dio()),
  };
}

extension ProviderCaptures on CaptureSession {
  PlayerController? get _capturePlayer => switch (platform) {
    'phone' when find.byType(MobilePlayerPage).evaluate().isNotEmpty =>
      tester
          .state<MobilePlayerPageState>(find.byType(MobilePlayerPage))
          .controller,
    'tv' when find.byType(TvPlayerPage).evaluate().isNotEmpty =>
      tester.state<TvPlayerPageState>(find.byType(TvPlayerPage)).controller,
    'desktop' when find.byType(PlayerPage).evaluate().isNotEmpty =>
      tester.state<PlayerPageState>(find.byType(PlayerPage)).controller,
    _ => null,
  };

  Future<void> _providerUntil(
    bool Function() ready,
    String reason, {
    String Function()? observed,
  }) async {
    final elapsed = Stopwatch()..start();
    while (!ready() && elapsed.elapsed < const Duration(seconds: 10)) {
      await advance(100);
    }
    expect(
      ready(),
      isTrue,
      reason: observed == null ? reason : '$reason; ${observed()}',
    );
  }

  Future<void> _providerArtworkReady() async {
    var observation = 'no visible artwork';
    await _providerUntil(
      () {
        final viewport =
            Offset.zero &
            (tester.view.physicalSize / tester.view.devicePixelRatio);
        final artwork = find.byWidgetPredicate(
          (widget) =>
              widget is MediaImage &&
              widget.blurSigma == null &&
              widget.item
                  .imageCandidates(
                    preferBackdrop: widget.preferBackdrop,
                    preferThumb: widget.preferThumb,
                    preferParentBackdrop: widget.preferParentBackdrop,
                  )
                  .isNotEmpty,
        );
        var visible = 0;
        observation = 'no visible artwork';
        for (final element in artwork.evaluate()) {
          final owner = find.byElementPredicate(
            (value) => identical(value, element),
          );
          if (!tester.getRect(owner).overlaps(viewport)) continue;
          visible++;
          final frames = tester.widgetList<RawImage>(
            find.descendant(of: owner, matching: find.byType(RawImage)),
          );
          if (frames.isEmpty || frames.any((frame) => frame.image == null)) {
            observation =
                '${(element.widget as MediaImage).item.id}: no decoded frame';
            return false;
          }
        }
        observation = '$visible visible images decoded';
        return visible > 0;
      },
      'Connected provider must display its visible artwork before capture',
      observed: () => observation,
    );
    // Let first-frame fades and the palette transition finish after decoding.
    await advance(300);
  }

  Future<void> closeCapturedPlayer() async {
    final controller = _capturePlayer;
    if (controller == null) return;
    if (find.byKey(PlayerKeys.endedClose).evaluate().isNotEmpty) {
      await activate(find.byKey(PlayerKeys.endedClose));
    } else if (platform == 'desktop') {
      await activate(find.byKey(const Key('player-window-close')));
    } else if (platform == 'phone') {
      await tap(const Key('mobile-player-close'));
    } else {
      await activate(find.byKey(const Key('tv-player-close')));
    }
    // The page only pops after controller.close has flushed the stopped report
    // and snapshot. Removing it via router.go skips that user-visible lifecycle.
    await _providerUntil(
      () => _capturePlayer == null,
      'Normal playback close must finish before changing server',
    );
  }

  Future<void> _providerField(String key, String value) async {
    final field = find.byKey(Key(key));
    // User-Agent 收在「高级选项」里;先展开再填写。
    final advanced = find.byKey(const Key('provider-advanced'));
    if (field.evaluate().isEmpty && advanced.evaluate().isNotEmpty) {
      await activate(advanced);
    }
    if (platform == 'tv') {
      await activate(field);
      await tester.enterText(find.byKey(const Key('tv-input-editor')), value);
      await tester.testTextInput.receiveAction(TextInputAction.done);
    } else {
      await tester.ensureVisible(field);
      await tester.enterText(field, value);
      tester.testTextInput.hide();
      FocusManager.instance.primaryFocus?.unfocus();
    }
    await advance(150);
  }

  Future<void> _providerWait(String key) async {
    for (var i = 0; i < 40; i++) {
      await advance(200);
      if (find.byKey(Key(key)).evaluate().isNotEmpty) return;
    }
    expect(
      find.byKey(Key(key)),
      findsOneWidget,
      reason: find
          .byType(Text)
          .evaluate()
          .map((e) => (e.widget as Text).data)
          .join(' | '),
    );
  }

  Future<void> providerPages(
    RillightApp app,
    AuthController auth,
    FakeEmbyServer emby,
    CaptureBackend Function() newBackend,
    MemoryPlaybackSessionSnapshotStore snapshots,
  ) async {
    for (final type in MediaServerType.values) {
      if (!wants('login') && !wants('player')) continue;
      final name = type.name;
      app.router.go('/connect?add=1');
      await advance(400);
      if (type == MediaServerType.emby) {
        // The reusable authorization dialog remains available to management
        // flows; the ordinary login page retains its dedicated Emby form.
        unawaited(
          showProviderConnect(
            tester.element(find.byKey(const Key('login-provider-emby'))),
            auth,
          ),
        );
        await advance(400);
      } else {
        await tap(Key('login-provider-$name'));
      }
      await _providerField('provider-user-agent', 'Rillight-Capture/1.0');
      await save('provider-$name-login');
      if (type == MediaServerType.plex) {
        CaptureProviders.plex.authorized = false;
        await activate(find.byKey(const Key('provider-authorize')));
        await _providerWait('provider-authorization-code');
        await save('provider-plex-authorization');
        CaptureProviders.plex.authorized = true;
        await _providerWait('provider-home-user');
        await save('provider-plex-discovery');
        await activate(find.byKey(const Key('provider-home-user')));
        await activate(find.text('Child').last);
        await save('provider-plex-home-pin');
        await _providerField('provider-home-pin', '0000');
        await activate(find.byKey(const Key('provider-home-switch')));
        await _providerWait('provider-error');
        await save('provider-plex-error');
        await _providerField('provider-home-pin', '1234');
        await activate(find.byKey(const Key('provider-home-switch')));
        await advance(800);
        // Match the rendered resource connection by its stable key, which
        // carries the connection URL.
        final url = CaptureProviders.plex.url.toString();
        final button = find.byWidgetPredicate(
          (widget) =>
              widget.key is ValueKey<String> &&
              (widget.key! as ValueKey<String>).value.startsWith(
                'provider-resource-',
              ) &&
              (widget.key! as ValueKey<String>).value.contains(url),
        );
        expect(button, findsOneWidget, reason: url);
        await activate(button);
      } else {
        await _providerField(
          'provider-address',
          type == MediaServerType.emby
              ? emby.baseUrl.toString()
              : CaptureProviders.jellyfin.url.toString(),
        );
        await _providerField('provider-username', 'alice');
        if (type == MediaServerType.jellyfin) {
          await activate(find.byKey(const Key('provider-authorize')));
          await _providerWait('provider-authorization-code');
          await save('provider-jellyfin-quick-connect');
          await tap(const Key('login-provider-emby'));
          await tap(const Key('login-provider-jellyfin'));
          await _providerField(
            'provider-address',
            CaptureProviders.jellyfin.url.toString(),
          );
          await _providerField('provider-username', 'alice');
        }
        await _providerField('provider-password', 'wrong');
        await activate(find.byKey(const Key('provider-password-submit')));
        await _providerWait('provider-error');
        await save('provider-$name-error');
        await _providerField(
          'provider-password',
          type == MediaServerType.emby ? 'correct-horse' : 'password',
        );
        await activate(find.byKey(const Key('provider-password-submit')));
      }
      for (
        var i = 0;
        i < 30 && find.byType(ProviderConnectDialog).evaluate().isNotEmpty;
        i++
      ) {
        await advance(200);
      }
      expect(find.byType(ProviderConnectDialog), findsNothing);
      expect(auth.client.serviceType, type);
      app.router.go('/');
      await advance(800);
      final id = switch (type) {
        MediaServerType.emby => 'movie-up',
        MediaServerType.jellyfin => 'movie-1',
        MediaServerType.plex => '42',
      };
      if (shouldCapture('provider-$name-connected')) {
        await _providerArtworkReady();
      }
      await save('provider-$name-connected');
      if (!wants('player')) continue;
      final backend = newBackend();
      final gate = Completer<void>();
      backend.openGate = gate;
      app.router.go('/item/$id');
      await advance(700);
      if (platform == 'desktop') {
        await activate(find.byKey(PlayerKeys.open));
      } else {
        unawaited(app.router.push('/play/$id'));
      }
      await advance(500);
      if (find
          .byKey(PlayerKeys.resumeFromStart)
          .hitTestable()
          .evaluate()
          .isNotEmpty) {
        await activate(find.byKey(PlayerKeys.resumeFromStart).hitTestable());
      }
      await save('provider-$name-player-loading');
      backend.openGate = null;
      gate.complete();
      await _providerUntil(
        () => backend.openCount > 0 && _capturePlayer?.loading == false,
        '$name playback must finish preparation and open the capture backend',
      );
      expect(backend.openCount, greaterThan(0));
      expect(_capturePlayer?.sessionExpired, isFalse);
      expect(_capturePlayer?.error, isNull);
      await save('provider-$name-player');
      await closeCapturedPlayer();
      expect(
        snapshots.snapshot,
        isNull,
        reason: '$name stopped report completed',
      );
      app.router.go('/');
      await advance(400);
      expect(find.text('上次播放已中断，可从详情页继续观看。'), findsNothing);
    }
  }
}
