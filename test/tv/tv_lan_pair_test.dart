import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/tv_widgets.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/auth/tv_connect_page.dart';
import 'package:rillight/auth/tv_lan_pair.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';

import '../emby/fake_emby_server.dart';

const _password = 'pw-lan-secret';
const _device = EmbyDeviceInfo(
  clientName: 'test',
  deviceName: 'tv',
  deviceId: 'tv-lan-pair',
  version: '1',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  TvLanAssist? assist;

  tearDown(() async {
    final current = assist;
    assist = null;
    await current?.close();
  });

  TvLanAssist start({Duration? lifetime}) {
    return TvLanAssist(
      advertiseHost: '127.0.0.1',
      lifetime: lifetime ?? const Duration(minutes: 3),
    );
  }

  AuthController authFor(FakeEmbyServer server) {
    return AuthController.memory(
      client: EmbyClient(
        device: _device,
        dio: dioForFakeEmby(FakeEmbyAdapter([server])),
      ),
    );
  }

  test('the assist stays closed until it is opened', () async {
    assist = start();
    expect(assist!.phase, TvLanPhase.idle);
    expect(assist!.offer, isNull);
    expect(assist!.pending, isNull);
  });

  test(
    'the QR and address carry only the origin, id, and fingerprint',
    () async {
      assist = start();
      await assist!.open();
      final offer = assist!.offer!;
      final uri = Uri.parse(offer.manualUrl);
      expect(offer.qrText, offer.manualUrl);
      expect(uri.scheme, 'https');
      expect(uri.host, '127.0.0.1');
      expect(uri.port, offer.port);
      expect(uri.userInfo, isEmpty);
      expect(uri.queryParameters.keys.toSet(), {'id', 'fp'});
      expect(uri.queryParameters['id'], offer.pairingId);
      expect(uri.queryParameters['fp'], offer.fingerprint);
      expect(offer.fingerprint, hasLength(64));
      expect(offer.qrText.contains(_password), isFalse);
      expect(offer.manualUrl.contains('token'), isFalse);
      expect(offer.qrModules.first.first, isTrue);
      expect(offer.qrModules.length, greaterThanOrEqualTo(21));

      final page = await _exchange(offer);
      expect(page!.status, 200);
      expect(page.body.contains(offer.fingerprint), isTrue);
      expect(page.body.contains(_password), isFalse);
      expect(page.body.contains('cdn'), isFalse);
      expect(page.body.contains('<script'), isFalse);
      expect(page.sawUntrustedCertificate, isTrue);
      expect(page.certificateDer, orderedEquals(offer.certificateDer));
    },
  );

  test(
    'a phone submission does not log in until the remote confirms',
    () async {
      final server = FakeEmbyServer();
      final auth = authFor(server);
      addTearDown(auth.dispose);
      assist = start();
      await assist!.open();
      final posted = await _exchange(
        assist!.offer!,
        method: 'POST',
        path: '/submit',
        body: _form(server.baseUrl.toString(), 'alice', 'correct-horse'),
      );
      expect(posted!.status, 200);
      expect(posted.body.contains('correct-horse'), isFalse);
      expect(assist!.phase, TvLanPhase.pending);
      expect(assist!.pending!.server, server.baseUrl.toString());
      expect(assist!.pending!.account, 'alice');
      expect(auth.isLoggedIn, isFalse);
      expect(auth.session, isNull);

      await assist!.confirm(auth);
      expect(auth.isLoggedIn, isTrue);
      expect(auth.session!.username, 'alice');
      expect(auth.session!.accessToken.contains('correct-horse'), isFalse);
    },
  );

  test(
    'reject, cancel, expiry, and a second device cannot reuse the entry',
    () async {
      final server = FakeEmbyServer();
      final auth = authFor(server);
      addTearDown(auth.dispose);
      await auth.connect(
        address: server.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
      );
      final token = auth.session!.accessToken;
      expect(token.isNotEmpty, isTrue);

      assist = start();
      await assist!.open();
      final offer = assist!.offer!;
      expect(offer.qrText.contains(token), isFalse);
      expect(offer.manualUrl.contains(_password), isFalse);

      final stranger = await _exchange(
        offer,
        method: 'POST',
        path: '/submit',
        body: _form('http://other.test:8096', 'mallory', _password),
        pairingId: 'not-the-pairing-id',
      );
      expect(stranger!.status, 404);
      expect(assist!.pending, isNull);
      expect(auth.session!.accessToken, token);
      expect(auth.session!.username, 'alice');

      final first = await _exchange(
        offer,
        method: 'POST',
        path: '/submit',
        body: _form('http://other.test:8096', 'mallory', _password),
      );
      expect(first!.status, 200);
      expect(assist!.pending!.account, 'mallory');
      expect(auth.session!.accessToken, token);

      final second = await _exchange(
        offer,
        method: 'POST',
        path: '/submit',
        body: _form('http://other.test:8096', 'bob', 'other-secret'),
      );
      expect(second!.status, 409);
      expect(assist!.pending!.account, 'mallory');
      expect(auth.session!.username, 'alice');

      await assist!.reject();
      expect(assist!.phase, TvLanPhase.rejected);
      expect(assist!.pending, isNull);
      expect(auth.session!.accessToken, token);
      final afterReject = await _exchange(
        offer,
        method: 'POST',
        path: '/submit',
        body: _form(server.baseUrl.toString(), 'alice', _password),
      );
      expect(afterReject == null || afterReject.status != 200, isTrue);
      await assist!.confirm(auth);
      expect(auth.session!.accessToken, token);
      expect(auth.session!.username, 'alice');
    },
  );

  test(
    'cancel and expiry drop the submission without replacing a session',
    () async {
      final server = FakeEmbyServer();
      final auth = authFor(server);
      addTearDown(auth.dispose);
      await auth.connect(
        address: server.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
      );
      final token = auth.session!.accessToken;

      assist = start();
      await assist!.open();
      final offer = assist!.offer!;
      await _exchange(
        offer,
        method: 'POST',
        path: '/submit',
        body: _form('http://other.test:8096', 'mallory', _password),
      );
      expect(assist!.pending, isNotNull);
      await assist!.cancel();
      expect(assist!.phase, TvLanPhase.cancelled);
      expect(assist!.pending, isNull);
      expect(auth.session!.accessToken, token);
      final reused = await _exchange(
        offer,
        method: 'POST',
        path: '/submit',
        body: _form(server.baseUrl.toString(), 'alice', 'correct-horse'),
      );
      expect(reused == null || reused.status != 200, isTrue);
      await assist!.confirm(auth);
      expect(auth.session!.accessToken, token);

      final expired = start(lifetime: const Duration(milliseconds: 200));
      assist = expired;
      await expired.open();
      final expiredOffer = expired.offer!;
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(expired.phase, TvLanPhase.expired);
      expect(expired.pending, isNull);
      final latePost = await _exchange(
        expiredOffer,
        method: 'POST',
        path: '/submit',
        body: _form('http://other.test:8096', 'mallory', _password),
      );
      expect(latePost == null || latePost.status != 200, isTrue);
      await expired.confirm(auth);
      expect(auth.session!.accessToken, token);
      expect(auth.session!.username, 'alice');
    },
  );

  testWidgets(
    'phone assist sits after remote connect and confirms only the account',
    (tester) async {
      tester.view.physicalSize = const Size(800, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final server = FakeEmbyServer();
      final auth = authFor(server);
      addTearDown(auth.dispose);
      TvLanAssist? opened;
      await tester.pumpWidget(
        _app(
          auth: auth,
          child: TvConnectPage(
            createLanAssist: () {
              opened = TvLanAssist(advertiseHost: '127.0.0.1');
              return opened!;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      final submit = find.byKey(const Key('tv-connect-submit'));
      final assistButton = find.byKey(const Key('tv-lan-assist'));
      expect(submit, findsOneWidget);
      expect(assistButton, findsOneWidget);
      expect(find.byKey(const Key('tv-lan-qr')), findsNothing);
      expect(
        tester.getTopLeft(assistButton).dy,
        greaterThan(tester.getTopLeft(submit).dy),
      );

      await tester.tap(assistButton);
      await _waitForLan(tester, () => opened);
      assist = opened;
      expect(assist!.phase, TvLanPhase.waiting);
      expect(find.text(_password), findsNothing);

      final posted = await tester.runAsync(
        () => _exchange(
          assist!.offer!,
          method: 'POST',
          path: '/submit',
          body: _form(server.baseUrl.toString(), 'alice', 'correct-horse'),
        ),
      );
      expect(posted!.status, 200);
      await tester.pump();
      expect(find.byKey(const Key('tv-lan-server')), findsOneWidget);
      expect(find.byKey(const Key('tv-lan-account')), findsOneWidget);
      expect(find.text(server.baseUrl.toString()), findsWidgets);
      expect(find.text('alice'), findsWidgets);
      expect(find.text('correct-horse'), findsNothing);
      expect(auth.isLoggedIn, isFalse);

      await tester.tap(find.byKey(const Key('tv-lan-confirm')));
      for (var i = 0; i < 40 && !auth.isLoggedIn; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
      }
      expect(auth.isLoggedIn, isTrue);
      expect(auth.session!.username, 'alice');
    },
  );

  testWidgets('an unfinished browser warning keeps remote login available', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final auth = AuthController.memory();
    addTearDown(auth.dispose);
    TvLanAssist? opened;
    await tester.pumpWidget(
      _app(
        auth: auth,
        child: TvConnectPage(
          createLanAssist: () {
            opened = TvLanAssist(advertiseHost: '127.0.0.1');
            return opened!;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('tv-lan-assist')));
    await _waitForLan(tester, () => opened);
    assist = opened;
    expect(find.byKey(const Key('tv-connect-address')), findsOneWidget);
    expect(find.text('辅助连接未完成'), findsOneWidget);

    await tester.tap(find.byKey(const Key('tv-lan-incomplete')));
    await tester.pump();
    await tester.runAsync(() => assist!.close());
    await tester.pump();
    expect(assist!.phase, TvLanPhase.failed);
    expect(auth.isLoggedIn, isFalse);
    expect(find.byKey(const Key('tv-connect-address')), findsOneWidget);
    expect(find.byKey(const Key('tv-connect-submit')), findsOneWidget);
    expect(find.text('辅助连接未完成'), findsWidgets);
  });
}

Future<void> _waitForLan(
  WidgetTester tester,
  TvLanAssist? Function() current,
) async {
  for (var i = 0; i < 40; i++) {
    await tester.pump();
    final lan = current();
    if (lan != null &&
        (lan.phase == TvLanPhase.waiting || lan.phase == TvLanPhase.failed)) {
      return;
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 250)),
    );
  }
}

String _form(String address, String username, String password) {
  return 'address=${Uri.encodeQueryComponent(address)}'
      '&username=${Uri.encodeQueryComponent(username)}'
      '&password=${Uri.encodeQueryComponent(password)}';
}

class _Page {
  const _Page({
    required this.status,
    required this.body,
    required this.sawUntrustedCertificate,
    required this.certificateDer,
  });

  final int status;
  final String body;
  final bool sawUntrustedCertificate;
  final List<int> certificateDer;
}

/// The widget binding replaces [HttpClient] with a client that never connects.
class _DirectHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context);
  }
}

Future<_Page?> _exchange(
  TvLanOffer offer, {
  String method = 'GET',
  String path = '/',
  String? body,
  String? pairingId,
}) {
  return HttpOverrides.runWithHttpOverrides(
    () => _exchangeDirect(
      offer,
      method: method,
      path: path,
      body: body,
      pairingId: pairingId,
    ),
    _DirectHttpOverrides(),
  );
}

Future<_Page?> _exchangeDirect(
  TvLanOffer offer, {
  required String method,
  required String path,
  required String? body,
  required String? pairingId,
}) async {
  final client = HttpClient();
  var untrusted = false;
  List<int> der = const [];
  try {
    client.badCertificateCallback = (certificate, host, port) {
      untrusted = true;
      der = certificate.der;
      return true;
    };
    final uri = Uri(
      scheme: 'https',
      host: '127.0.0.1',
      port: offer.port,
      path: path,
      queryParameters: {
        'id': pairingId ?? offer.pairingId,
        'fp': offer.fingerprint,
      },
    );
    final request = await client
        .openUrl(method, uri)
        .timeout(const Duration(seconds: 5));
    if (body != null) {
      request.headers.contentType = ContentType(
        'application',
        'x-www-form-urlencoded',
        charset: 'utf-8',
      );
      request.write(body);
    }
    final response = await request.close().timeout(const Duration(seconds: 5));
    final text = await utf8.decoder.bind(response).join();
    return _Page(
      status: response.statusCode,
      body: text,
      sawUntrustedCertificate: untrusted,
      certificateDer: der,
    );
  } on Object {
    return null;
  } finally {
    client.close(force: true);
  }
}

Widget _app({required AuthController auth, required Widget child}) {
  return MaterialApp(
    locale: const Locale('zh', 'CN'),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    home: AuthScope(controller: auth, child: child),
  );
}
