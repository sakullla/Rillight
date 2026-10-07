import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
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

  TvLanAssist start({Duration? lifetime, Duration? phoneGrace}) {
    return TvLanAssist(
      advertiseHost: '127.0.0.1',
      lifetime: lifetime ?? const Duration(minutes: 3),
      phoneGrace: phoneGrace ?? Duration.zero,
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
      expect(page.body, contains('name="userAgent"'));
      expect(page.sawUntrustedCertificate, isTrue);
      expect(page.certificateDer, orderedEquals(offer.certificateDer));
    },
  );

  test(
    'a phone submission applies its UA only after the remote confirms',
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
        body: _form(
          server.baseUrl.toString(),
          'alice',
          'correct-horse',
          userAgent: '  TvAssist/1.0  ',
        ),
      );
      expect(posted!.status, 200);
      expect(posted.body, contains('待确认'));
      expect(posted.body.contains('correct-horse'), isFalse);
      expect(posted.body.contains('<script'), isFalse);
      expect(assist!.phase, TvLanPhase.pending);
      expect(assist!.pending!.server, server.baseUrl.toString());
      expect(assist!.pending!.account, 'alice');
      expect(assist!.pending!.userAgent, 'TvAssist/1.0');
      expect(auth.isLoggedIn, isFalse);
      expect(auth.session, isNull);

      await assist!.confirm(auth);
      expect(auth.isLoggedIn, isTrue);
      expect(auth.session!.username, 'alice');
      expect(auth.client.userAgent, 'TvAssist/1.0');
      expect(auth.session!.server.normalizedUserAgent, 'TvAssist/1.0');
      expect(auth.session!.accessToken.contains('correct-horse'), isFalse);
    },
  );

  for (final ua in ['bad\r\nheader', 'x' * 1025]) {
    test(
      'invalid UA is rejected before confirmation (${ua.length} chars)',
      () async {
        assist = start();
        await assist!.open();
        final response = await _exchange(
          assist!.offer!,
          method: 'POST',
          path: '/submit',
          body: _form('http://server.test', 'alice', 'secret', userAgent: ua),
        );
        expect(response!.status, 400);
        expect(assist!.pending, isNull);
      },
    );
  }

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
      expect(expired.expiresAt, isNotNull);
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
              opened = TvLanAssist(
                advertiseHost: '127.0.0.1',
                phoneGrace: Duration.zero,
              );
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
      final deadline = assist!.expiresAt;
      expect(deadline, isNotNull);
      final shown = tester
          .widget<Text>(find.byKey(const Key('tv-lan-expires')))
          .data!;
      final local = deadline!.toLocal();
      String two(int value) => value.toString().padLeft(2, '0');
      expect(
        shown,
        '本次配对有效至 ${two(local.hour)}:${two(local.minute)}:${two(local.second)}',
      );
      expect(shown.contains(_password), isFalse);

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
            opened = TvLanAssist(
              advertiseHost: '127.0.0.1',
              phoneGrace: Duration.zero,
            );
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

  test(
    'a failed confirm keeps the previous session and the phone sees failure',
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
      expect(auth.client.accessToken, token);

      assist = start(phoneGrace: const Duration(seconds: 3));
      await assist!.open();
      final offer = assist!.offer!;
      final posted = await _exchange(
        offer,
        method: 'POST',
        path: '/submit',
        body: _form('http://other.test:8096', 'mallory', _password),
      );
      expect(posted!.status, 200);
      _expectPhone(posted.body, '待确认', secret: _password, token: token);
      expect(_statusQuery(posted.body), {'id', 'fp'});

      final connectingFuture = _exchange(offer, path: '/status');
      await _waitForPhone(assist!);
      final confirmFuture = assist!.confirm(auth);
      final connecting = await connectingFuture;
      _expectPhone(connecting!.body, '连接中', secret: _password, token: token);

      final failedFuture = _exchange(offer, path: '/status');
      final failed = await failedFuture;
      final accepted = await confirmFuture;
      _expectPhone(failed!.body, '失败', secret: _password, token: token);
      expect(failed.body.contains('成功'), isFalse);
      expect(accepted, isFalse);
      expect(assist!.phase, TvLanPhase.failed);
      expect(auth.isLoggedIn, isTrue);
      expect(auth.session!.accessToken, token);
      expect(auth.session!.username, 'alice');
      expect(auth.client.accessToken, token);
      expect(auth.client.baseUrl, server.baseUrl);
      final closed = await _exchange(offer, path: '/status');
      expect(closed == null || closed.status != 200, isTrue);
    },
  );

  test('a failed confirm with no session stays signed out', () async {
    final server = FakeEmbyServer();
    final auth = authFor(server);
    addTearDown(auth.dispose);
    assist = start(phoneGrace: const Duration(seconds: 3));
    await assist!.open();
    final offer = assist!.offer!;
    final posted = await _exchange(
      offer,
      method: 'POST',
      path: '/submit',
      body: _form(server.baseUrl.toString(), 'alice', _password),
    );
    _expectPhone(
      posted!.body,
      '待确认',
      secret: _password,
      token: 'session-token-must-not-appear',
    );

    final connectingFuture = _exchange(offer, path: '/status');
    await _waitForPhone(assist!);
    final confirmFuture = assist!.confirm(auth);
    final connecting = await connectingFuture;
    _expectPhone(
      connecting!.body,
      '连接中',
      secret: _password,
      token: 'session-token-must-not-appear',
    );
    final failed = await _exchange(offer, path: '/status');
    final accepted = await confirmFuture;
    _expectPhone(
      failed!.body,
      '失败',
      secret: _password,
      token: 'session-token-must-not-appear',
    );
    expect(accepted, isFalse);
    expect(auth.isLoggedIn, isFalse);
    expect(auth.session, isNull);
    expect(auth.client.accessToken, isNull);
    expect(auth.client.baseUrl, isNull);
  });

  test('a successful confirm still switches to the new session', () async {
    final home = FakeEmbyServer();
    final other = FakeEmbyServer(
      serverId: 'server-id-2',
      serverName: '第二台',
      baseUrl: Uri.parse('http://other.test:8096'),
      users: const [
        FakeEmbyUser(
          username: 'bob',
          password: 'correct-horse',
          userId: 'user-bob',
        ),
      ],
    );
    final auth = AuthController.memory(
      client: EmbyClient(
        device: _device,
        dio: dioForFakeEmby(FakeEmbyAdapter([home, other])),
      ),
    );
    addTearDown(auth.dispose);
    await auth.connect(
      address: home.baseUrl.toString(),
      username: 'alice',
      password: 'correct-horse',
    );
    final token = auth.session!.accessToken;

    assist = start(phoneGrace: const Duration(seconds: 3));
    await assist!.open();
    final offer = assist!.offer!;
    final posted = await _exchange(
      offer,
      method: 'POST',
      path: '/submit',
      body: _form(other.baseUrl.toString(), 'bob', 'correct-horse'),
    );
    _expectPhone(posted!.body, '待确认', secret: 'correct-horse', token: token);

    final connectingFuture = _exchange(offer, path: '/status');
    await _waitForPhone(assist!);
    final confirmFuture = assist!.confirm(auth);
    final connecting = await connectingFuture;
    _expectPhone(
      connecting!.body,
      '连接中',
      secret: 'correct-horse',
      token: token,
    );
    final success = await _exchange(offer, path: '/status');
    final accepted = await confirmFuture;
    _expectPhone(success!.body, '成功', secret: 'correct-horse', token: token);
    expect(success.body.contains('连接中'), isFalse);
    expect(success.body.contains('待确认'), isFalse);
    expect(accepted, isTrue);
    expect(auth.session!.username, 'bob');
    expect(auth.session!.accessToken, isNot(token));
    expect(success.body.contains(auth.session!.accessToken), isFalse);
    expect(auth.client.accessToken, auth.session!.accessToken);
    expect(auth.client.baseUrl, other.baseUrl);
  });

  test('reject and expiry tell the phone before the entry closes', () async {
    final server = FakeEmbyServer();
    final auth = authFor(server);
    addTearDown(auth.dispose);
    await auth.connect(
      address: server.baseUrl.toString(),
      username: 'alice',
      password: 'correct-horse',
    );
    final token = auth.session!.accessToken;
    assist = start(phoneGrace: const Duration(seconds: 3));
    await assist!.open();
    final offer = assist!.offer!;
    await _exchange(
      offer,
      method: 'POST',
      path: '/submit',
      body: _form('http://other.test:8096', 'mallory', _password),
    );
    final rejected = _exchange(offer, path: '/status');
    await _waitForPhone(assist!);
    await assist!.reject();
    final page = await rejected;
    _expectPhone(page!.body, '失败', secret: _password, token: token);
    expect(auth.session!.accessToken, token);
    expect(assist!.phase, TvLanPhase.rejected);
    final again = await _exchange(offer, path: '/status');
    expect(again == null || again.status != 200, isTrue);

    final expired = start(
      lifetime: const Duration(seconds: 5),
      phoneGrace: const Duration(seconds: 3),
    );
    assist = expired;
    await expired.open();
    final expiredOffer = expired.offer!;
    expect(expired.expiresAt, isNotNull);
    expect(expired.expiresAt!.isAfter(DateTime.now()), isTrue);
    await _exchange(
      expiredOffer,
      method: 'POST',
      path: '/submit',
      body: _form('http://other.test:8096', 'mallory', _password),
    );
    final failure = _exchange(expiredOffer, path: '/status');
    await _waitForPhone(expired);
    final remaining = expired.expiresAt!.difference(DateTime.now());
    await Future<void>.delayed(remaining + const Duration(milliseconds: 400));
    expect(expired.phase, TvLanPhase.expired);
    final expiredPage = await failure;
    _expectPhone(expiredPage!.body, '失败', secret: _password, token: token);
    expect(auth.session!.accessToken, token);
    final late = await _exchange(
      expiredOffer,
      method: 'POST',
      path: '/submit',
      body: _form(server.baseUrl.toString(), 'alice', _password),
    );
    expect(late == null || late.status != 200, isTrue);
  });

  test(
    'backing out while the phone is waiting delivers failure and keeps the session',
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

      assist = start(phoneGrace: const Duration(seconds: 3));
      await assist!.open();
      final offer = assist!.offer!;
      await _exchange(
        offer,
        method: 'POST',
        path: '/submit',
        body: _form('http://other.test:8096', 'mallory', _password),
      );
      expect(assist!.phase, TvLanPhase.pending);
      final waiting = _exchange(offer, path: '/status');
      await _waitForPhone(assist!);
      assist!.dispose();
      final page = await waiting;
      _expectPhone(page!.body, '失败', secret: _password, token: token);
      expect(page.body.contains('成功'), isFalse);
      expect(page.body.contains('待确认'), isFalse);
      expect(assist!.phase, TvLanPhase.cancelled);
      expect(assist!.pending, isNull);
      expect(await assist!.confirm(auth), isFalse);
      expect(auth.isLoggedIn, isTrue);
      expect(auth.session!.accessToken, token);
      expect(auth.session!.username, 'alice');
      expect(auth.client.accessToken, token);
      expect(auth.client.baseUrl, server.baseUrl);
      final again = await _exchange(offer, path: '/status');
      expect(again == null || again.status != 200, isTrue);
    },
  );

  test(
    'dispose during connect still delivers the decided success page',
    () async {
      final home = FakeEmbyServer();
      final other = FakeEmbyServer(
        serverId: 'server-id-2',
        serverName: '第二台',
        baseUrl: Uri.parse('http://other.test:8096'),
        users: const [
          FakeEmbyUser(
            username: 'bob',
            password: 'correct-horse',
            userId: 'user-bob',
          ),
        ],
      );
      final dio = dioForFakeEmby(FakeEmbyAdapter([home, other]));
      final auth = AuthController.memory(
        client: EmbyClient(device: _device, dio: dio),
      );
      addTearDown(auth.dispose);
      await auth.connect(
        address: home.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
      );
      final token = auth.session!.accessToken;
      assist = start(phoneGrace: const Duration(seconds: 3));
      await assist!.open();
      final offer = assist!.offer!;
      final posted = await _exchange(
        offer,
        method: 'POST',
        path: '/submit',
        body: _form(other.baseUrl.toString(), 'bob', 'correct-horse'),
      );
      _expectPhone(posted!.body, '待确认', secret: 'correct-horse', token: token);

      final gate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) {
          gate.complete();
        }
      });
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) async {
            await gate.future;
            handler.next(options);
          },
        ),
      );
      final connectingFuture = _exchange(offer, path: '/status');
      await _waitForPhone(assist!);
      final confirmFuture = assist!.confirm(auth);
      final connecting = await connectingFuture;
      _expectPhone(
        connecting!.body,
        '连接中',
        secret: 'correct-horse',
        token: token,
      );
      final resultFuture = _exchange(offer, path: '/status');
      await _waitForPhone(assist!);
      expect(assist!.phase, TvLanPhase.connecting);
      assist!.dispose();
      expect(assist!.phase, TvLanPhase.connecting);
      gate.complete();
      final page = await resultFuture;
      final accepted = await confirmFuture;
      _expectPhone(page!.body, '成功', secret: 'correct-horse', token: token);
      expect(page.body.contains('失败'), isFalse);
      expect(page.body.contains('连接中'), isFalse);
      expect(accepted, isTrue);
      expect(assist!.phase, TvLanPhase.confirmed);
      expect(auth.session!.username, 'bob');
      expect(auth.session!.accessToken, isNot(token));
      expect(page.body.contains(auth.session!.accessToken), isFalse);
      expect(auth.client.accessToken, auth.session!.accessToken);
      expect(auth.client.baseUrl, other.baseUrl);
    },
  );

  test(
    'dispose during a failed connect still delivers failure and keeps the session',
    () async {
      final server = FakeEmbyServer();
      final dio = dioForFakeEmby(FakeEmbyAdapter([server]));
      final auth = AuthController.memory(
        client: EmbyClient(device: _device, dio: dio),
      );
      addTearDown(auth.dispose);
      await auth.connect(
        address: server.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
      );
      final token = auth.session!.accessToken;
      assist = start(phoneGrace: const Duration(seconds: 3));
      await assist!.open();
      final offer = assist!.offer!;
      await _exchange(
        offer,
        method: 'POST',
        path: '/submit',
        body: _form('http://missing.test:8096', 'mallory', _password),
      );
      final gate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) {
          gate.complete();
        }
      });
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) async {
            await gate.future;
            handler.next(options);
          },
        ),
      );
      final connectingFuture = _exchange(offer, path: '/status');
      await _waitForPhone(assist!);
      final confirmFuture = assist!.confirm(auth);
      final connecting = await connectingFuture;
      _expectPhone(connecting!.body, '连接中', secret: _password, token: token);
      final resultFuture = _exchange(offer, path: '/status');
      await _waitForPhone(assist!);
      expect(assist!.phase, TvLanPhase.connecting);
      assist!.dispose();
      gate.complete();
      final page = await resultFuture;
      final accepted = await confirmFuture;
      _expectPhone(page!.body, '失败', secret: _password, token: token);
      expect(page.body.contains('成功'), isFalse);
      expect(accepted, isFalse);
      expect(assist!.phase, TvLanPhase.failed);
      expect(auth.isLoggedIn, isTrue);
      expect(auth.session!.accessToken, token);
      expect(auth.session!.username, 'alice');
      expect(auth.client.accessToken, token);
      expect(auth.client.baseUrl, server.baseUrl);
    },
  );
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

Future<void> _waitForPhone(TvLanAssist lan) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (lan.phoneWaiters == 0) {
    if (DateTime.now().isAfter(deadline)) {
      fail('phone status request was not held');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void _expectPhone(
  String body,
  String heading, {
  required String secret,
  required String token,
}) {
  expect(body, contains('<h1>$heading</h1>'));
  expect(body.contains(secret), isFalse);
  expect(body.contains(token), isFalse);
  expect(body.contains('<script'), isFalse);
  expect(body.contains('cdn'), isFalse);
}

Set<String> _statusQuery(String body) {
  final match = RegExp('url=([^"]+)').firstMatch(body);
  expect(match, isNotNull);
  final raw = match!.group(1)!.replaceAll('&amp;', '&');
  final uri = Uri.parse('https://127.0.0.1$raw');
  return uri.queryParameters.keys.toSet();
}

String _form(
  String address,
  String username,
  String password, {
  String? userAgent,
}) {
  return 'address=${Uri.encodeQueryComponent(address)}'
      '&username=${Uri.encodeQueryComponent(username)}'
      '&password=${Uri.encodeQueryComponent(password)}'
      '${userAgent == null ? '' : '&userAgent=${Uri.encodeQueryComponent(userAgent)}'}';
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
class _DirectHttpOverrides extends HttpOverrides {}

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
