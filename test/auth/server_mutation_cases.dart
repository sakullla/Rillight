import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/connection_failure.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/provider_connect_controller.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/auth/server_paste_draft.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/media_server/device.dart';
import 'package:rillight/media_server/errors.dart';
import 'package:rillight/media_server/capabilities.dart';
import 'package:rillight/media_server/server_address.dart';

import '../emby/fake_emby_server.dart';

class _Store extends FileServerListStore {
  _Store(super.file);
  bool failAfterSave = false;
  Completer<void>? gate;
  Completer<void>? entered;
  @override
  Future<void> save(ServerListSnapshot snapshot) async {
    await super.save(snapshot);
    final wait = gate;
    gate = null;
    entered?.complete();
    entered = null;
    await wait?.future;
    if (failAfterSave) {
      failAfterSave = false;
      throw StateError('Injected configuration failure');
    }
  }
}

class _Adapter extends FakeEmbyAdapter {
  _Adapter(this.endpoints) : super(endpoints);
  final List<FakeEmbyServer> endpoints;
  final List<RequestOptions> requests = [];
  bool Function(RequestOptions)? holdWhen;
  Completer<void>? gate;
  Completer<void>? entered;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelled,
  ) async {
    requests.add(options);
    if (holdWhen?.call(options) == true) {
      holdWhen = null;
      entered?.complete();
      await gate?.future;
    }
    for (final server in endpoints) {
      server.issuedTokens.addAll(
        endpoints
            .where((s) => s.serverId == server.serverId)
            .expand((s) => s.issuedTokens)
            .toList(),
      );
    }
    return super.fetch(options, stream, cancelled);
  }
}

void main() {
  late Directory directory;
  late _Store store;
  late AuthController auth;
  late FakeEmbyServer primary, alternate, other;
  late _Adapter adapter;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('rillight-mutation-');
    store = _Store(File('${directory.path}/servers.json'));
    primary = FakeEmbyServer();
    alternate = FakeEmbyServer(
      baseUrl: Uri.parse('http://alternate.test:8096'),
    );
    other = FakeEmbyServer(
      serverId: 'different',
      baseUrl: Uri.parse('http://other.test'),
    );
    adapter = _Adapter([primary, alternate, other]);
    auth = AuthController(
      client: EmbyClient(
        device: const ClientDeviceInfo(
          clientName: 'test',
          deviceName: 'test',
          deviceId: 'mutation',
          version: '1',
        ),
        dio: dioForFakeEmby(adapter),
      ),
      credentials: MemoryCredentialStore(),
      servers: store,
    );
    expect(
      await auth.connect(
        address: primary.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
      ),
      isTrue,
    );
  });
  tearDown(() async {
    auth.dispose();
    await directory.delete(recursive: true);
  });

  Future<void> addAlternate() async =>
      auth.addLine(auth.savedServers.single.id, alternate.baseUrl.toString());

  for (final throughAuth in [true, false]) {
    test(
      'legacy fixed active deletion round trips via ${throughAuth ? 'AuthController' : 'Registry'}',
      () async {
        await addAlternate();
        final server = auth.savedServers.single;
        final raw = server.toJson()..remove('lineSelection');
        await store.file.writeAsString(
          jsonEncode({
            'version': 3,
            'lastServerId': server.id,
            'servers': [raw],
          }),
        );
        await auth.sources.load();
        await auth.refreshServers();
        expect(
          auth.savedServers.single.lineSelection.fixedLineId,
          server.activeLineId,
        );
        if (throughAuth) {
          await auth.deleteLine(server.id, server.activeLineId!);
        } else {
          await auth.sources.removeLine(server.id, server.activeLineId!);
        }
        final restored = (await FileServerListStore(
          store.file,
        ).load()).servers.single;
        expect(restored.lines, hasLength(1));
        expect(restored.lineSelection.fixedLineId, restored.lines.single.id);
        expect(restored.activeLineId, restored.lines.single.id);
        expect(restored.lastSuccessfulLineId, restored.lines.single.id);
      },
    );
  }

  test(
    'failed active deletion preserves disk, selected client and permit',
    () async {
      await addAlternate();
      final server = auth.savedServers.single;
      final session = await auth.sources.ensureSession(server.id);
      final permit = auth.sources.permit(session.account);
      final before = await store.file.readAsString();
      store.failAfterSave = true;
      await expectLater(
        auth.deleteLine(server.id, server.activeLineId!),
        throwsStateError,
      );
      expect(await store.file.readAsString(), before);
      expect(permit.isValid, isTrue);
      expect(auth.client.baseUrl, primary.baseUrl);
      expect(auth.savedServers.single.lines, hasLength(2));
    },
  );

  test('failed active address edit preserves old session and never saves an alien line', () async {
    final server = auth.savedServers.single;
    final before = await store.file.readAsString();
    await expectLater(
      auth.updateLineAddress(
        server.id,
        server.activeLineId!,
        other.baseUrl.toString(),
      ),
      throwsA(isA<MediaServerException>()),
    );
    expect(auth.client.baseUrl, primary.baseUrl);
    expect(await store.file.readAsString(), before);
    expect(
      adapter.requests
          .where((r) => r.uri.host == other.baseUrl.host)
          .map((r) => r.uri.path),
      everyElement(contains('/System/Info/Public')),
    );
    expect(
      adapter.requests
          .where((r) => r.uri.host == other.baseUrl.host)
          .any((r) => r.headers.values.any((v) => '$v'.contains('token-'))),
      isFalse,
    );
  });

  test('metadata and backup reorder preserve permits; automatic intent does not reopen', () async {
    await addAlternate();
    final server = auth.savedServers.single;
    final session = await auth.sources.ensureSession(server.id);
    final permit = auth.sources.permit(session.account);
    final revision = auth.sources.configurationRevision;
    await auth.renameServer(server.id, 'Renamed');
    await auth.sources.reorderLines(
      server.id,
      server.lines.reversed.map((l) => l.id).toList(),
    );
    await auth.selectLine(server.id, const LineSelection.auto());
    expect(auth.sources.configurationRevision, greaterThan(revision));
    expect(permit.isValid, isTrue);
    final requestCount = adapter.requests.length;
    final reused = await auth.sources.ensureSession(server.id);
    expect(reused.account, session.account);
    expect(reused.client.accessToken, session.client.accessToken);
    expect(adapter.requests.length, requestCount);
    expect(auth.client.baseUrl, primary.baseUrl);
    expect(
      (await FileServerListStore(
        store.file,
      ).load()).servers.single.lineSelection.isAutomatic,
      isTrue,
    );
  });

  test(
    'a failed fixed selection never changes saved or connected selection',
    () async {
      await addAlternate();
      final server = auth.savedServers.single;
      final before = await store.file.readAsString();
      alternate.expireAuthenticatedRequests = true;
      await auth.switchTo(server.id, lineId: server.lines.last.id);
      expect(auth.failure?.kind, MediaServerFailureKind.sessionExpired);
      expect(await store.file.readAsString(), before);
      expect(auth.client.baseUrl, primary.baseUrl);
      expect(auth.savedServers.single.lineSelection.isAutomatic, isTrue);
    },
  );

  test('reauthorization cancellation while saving keeps old permit usable and rolls back', () async {
    final server = auth.savedServers.single;
    final session = await auth.sources.ensureSession(server.id);
    final permit = auth.sources.permit(session.account);
    final old = await auth.credentials.read(server.id);
    final controller = ProviderConnectController(auth: auth, existing: server);
    addTearDown(controller.dispose);
    store.gate = Completer<void>();
    store.entered = Completer<void>();
    final gate = store.gate!;
    final entered = store.entered!.future;
    final pending = controller.password(
      primary.baseUrl.toString(),
      'alice',
      'correct-horse',
    );
    await entered;
    expect(permit.isValid, isTrue);
    expect(
      (await permit.dispatch((client) => client.getUser())).id,
      old!.userId,
    );
    controller.reset();
    gate.complete();
    await pending;
    expect(
      (await auth.credentials.read(server.id))!.accessToken,
      old.accessToken,
    );
    expect(permit.isValid, isTrue);
    expect(auth.session!.accessToken, old.accessToken);
  });

  test(
    'failed reauthorization password keeps live client, credential and permit',
    () async {
      final server = auth.savedServers.single;
      final session = await auth.sources.ensureSession(server.id);
      final permit = auth.sources.permit(session.account);
      final old = auth.session;
      final controller = ProviderConnectController(
        auth: auth,
        existing: server,
      );
      addTearDown(controller.dispose);
      await controller.password(primary.baseUrl.toString(), 'alice', 'wrong');
      expect(controller.failure, MediaServerFailureKind.invalidCredentials);
      expect(auth.session, same(old));
      expect(permit.isValid, isTrue);
      expect(
        (await permit.dispatch((client) => client.getUser())).id,
        old!.userId,
      );
    },
  );

  test(
    'paste preview stays editable and unverified extras never commit a login',
    () async {
      final preview = ServerPastePreview.parse(
        '名称: My server\n用户名: alice\n密码: correct-horse\n'
        '${primary.baseUrl}\n${other.baseUrl}',
      );
      final draft = preview.groups.single;
      final before = await store.file.readAsString();
      final controller = ProviderConnectController(auth: auth);
      addTearDown(controller.dispose);
      draft.unrecognized.add('https://invalid[host');
      await controller.submitDraft(draft);
      expect(controller.failure, MediaServerFailureKind.invalidResponse);
      expect(await store.file.readAsString(), before);
      draft.unrecognized.clear();
      await controller.submitDraft(draft);
      expect(controller.failure, MediaServerFailureKind.incompatibleServer);
      expect(draft.lines, hasLength(2));
      expect(await store.file.readAsString(), before);
      draft.lines.removeLast();
      await controller.submitDraft(draft);
      expect(controller.stage, ProviderConnectStage.done);
      expect(controller.failure, isNull);
    },
  );

  test('paste keeps partial fields, splits ambiguous accounts and never invents an empty entry', () {
    expect(ServerPastePreview.parse('unrecognized words').groups, isEmpty);
    final partial = ServerPastePreview.parse('用户名: alice\n备注: next');
    expect(partial.groups.single.username, 'alice');
    expect(partial.groups.single.lines, isEmpty);
    expect(partial.groups.single.unrecognized, ['备注: next']);
    final groups = ServerPastePreview.parse(
      '用户名: alice\nhttps://a.test\n用户名: bob\nhttps://b.test',
    );
    expect(groups.needsGroupSelection, isTrue);
    expect(groups.groups.map((g) => g.lines.single), [
      'https://a.test',
      'https://b.test',
    ]);
  });

  for (final entry in ['direct', 'provider', 'switch', 'restore', 'ensure']) {
    test('changed saved identity stays anonymous through $entry', () async {
      final saved = auth.savedServers.single;
      while (auth.libraryCountsLoading) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      primary.serverId = 'impostor';
      adapter.requests.clear();
      if (entry == 'direct') {
        expect(
          await auth.connect(
            address: primary.baseUrl.toString(),
            username: 'alice',
            password: 'correct-horse',
          ),
          isFalse,
        );
      } else if (entry == 'provider') {
        final controller = ProviderConnectController(
          auth: auth,
          existing: saved,
        );
        addTearDown(controller.dispose);
        await controller.password(
          primary.baseUrl.toString(),
          'alice',
          'correct-horse',
        );
        expect(controller.failure, MediaServerFailureKind.incompatibleServer);
      } else if (entry == 'switch') {
        await auth.switchTo(saved.id);
        expect(auth.failure?.kind, MediaServerFailureKind.incompatibleServer);
      } else {
        final cold = AuthController(
          client: EmbyClient(
            device: auth.client.device,
            dio: dioForFakeEmby(adapter),
          ),
          credentials: auth.credentials,
          servers: store,
        );
        addTearDown(cold.dispose);
        if (entry == 'restore') {
          await cold.restore();
          expect(cold.isLoggedIn, isFalse);
        } else {
          await cold.sources.load();
          await expectLater(
            cold.sources.ensureSession(saved.id),
            throwsA(isA<MediaServerException>()),
          );
        }
      }
      expect(adapter.requests, isNotEmpty);
      expect(
        adapter.requests.map((r) => r.uri.path),
        everyElement(contains('/System/Info/Public')),
      );
      expect(
        adapter.requests.any(
          (r) => r.headers.values.any((v) => '$v'.contains('token-')),
        ),
        isFalse,
      );
      expect((await store.load()).lastServerId, saved.id);
    });
  }

  test(
    'late line edit saves A without overriding a newer selection of B',
    () async {
      final a = auth.savedServers.single;
      await auth.connect(
        address: other.baseUrl.toString(),
        username: 'alice',
        password: 'correct-horse',
      );
      final b = auth.session!.server;
      await auth.switchTo(a.id);
      adapter.gate = Completer<void>();
      adapter.entered = Completer<void>();
      adapter.holdWhen = (r) => r.uri.host == alternate.baseUrl.host;
      final edit = auth.updateLineAddress(
        a.id,
        a.activeLineId!,
        alternate.baseUrl.toString(),
      );
      await adapter.entered!.future;
      await auth.switchTo(b.id);
      adapter.gate!.complete();
      await edit;
      expect(auth.session!.server.id, b.id);
      expect(auth.client.baseUrl, other.baseUrl);
      expect(auth.sources.server(a.id).baseUrl, alternate.baseUrl.toString());
      expect((await store.load()).lastServerId, b.id);
    },
  );

  test('failed or cancelled target activation leaves disk selection and current session', () async {
    final a = auth.savedServers.single;
    await auth.connect(
      address: other.baseUrl.toString(),
      username: 'alice',
      password: 'correct-horse',
    );
    final b = auth.session!.server;
    await auth.switchTo(a.id);
    final before = await store.file.readAsString();
    other.publicInfoStatus = 503;
    await auth.switchTo(b.id);
    expect(auth.session!.server.id, a.id);
    expect(await store.file.readAsString(), before);
    other.publicInfoStatus = null;
    store.gate = Completer<void>();
    store.entered = Completer<void>();
    final gate = store.gate!;
    var valid = true;
    final selecting = auth.switchTo(
      b.id,
      guard: () {
        if (!valid) throw StateError('cancelled');
      },
    );
    await store.entered!.future;
    valid = false;
    gate.complete();
    await selecting;
    expect(auth.session!.server.id, a.id);
    expect(auth.client.baseUrl, primary.baseUrl);
    expect(await store.file.readAsString(), before);
  });

  test('authorization merges concurrent metadata and rejects changed connection configuration', () async {
    final server = auth.savedServers.single;
    final value = (await auth.credentials.read(server.id))!;
    final attempt = await auth.sources.beginAuthorization(
      serviceType: server.serviceType,
      configuredServerId: server.id,
    );
    adapter.gate = Completer<void>();
    adapter.entered = Completer<void>();
    adapter.holdWhen = (r) => r.uri.path.endsWith('/System/Info/Public');
    final commit = auth.sources.commitAuthorization(
      attempt,
      server: server,
      value: value,
    );
    await adapter.entered!.future;
    await auth.renameServer(server.id, 'New name');
    await auth.sources.renameLine(server.id, server.activeLineId!, 'My line');
    await auth.sources.persistProtectionReference(server.id, 'new-protection');
    adapter.gate!.complete();
    await commit;
    final merged = (await store.load()).servers.single;
    expect(merged.nickname, 'New name');
    expect(merged.activeLine!.nickname, 'My line');
    expect(merged.protectionRef, 'new-protection');
    final nextAttempt = await auth.sources.beginAuthorization(
      serviceType: server.serviceType,
      configuredServerId: server.id,
    );
    adapter.gate = Completer<void>();
    adapter.entered = Completer<void>();
    adapter.holdWhen = (r) => r.uri.path.endsWith('/System/Info/Public');
    final pending = auth.sources.commitAuthorization(
      nextAttempt,
      server: merged,
      value: value,
    );
    final rejected = expectLater(pending, throwsStateError);
    await adapter.entered!.future;
    await auth.sources.setLineAddress(server.id, alternate.baseUrl.toString());
    final changed = await store.file.readAsString();
    adapter.gate!.complete();
    await rejected;
    expect(await store.file.readAsString(), changed);
    expect((await store.load()).servers.single.lines, hasLength(2));
  });

  test(
    'paste grouping keeps explicit backup lines with their named account',
    () {
      final preview = ServerPastePreview.parse(
        '名称: A\n地址: https://a.test\n用户名: alice\n密码: one\n'
        '线路2: https://backup-a.test\n名称: B\n地址: https://b.test\n'
        '用户名: bob\n密码: two',
      );
      expect(preview.needsGroupSelection, isTrue);
      expect(preview.groups, hasLength(2));
      final a = preview.groups.first;
      final b = preview.groups.last;
      expect([a.name, a.username, a.password], ['A', 'alice', 'one']);
      expect(a.lines, ['https://a.test', 'https://backup-a.test']);
      expect([b.name, b.username, b.password], ['B', 'bob', 'two']);
      expect(b.lines, ['https://b.test']);
    },
  );

  test(
    'paste grouping keeps explicit lines across unnamed account boundaries',
    () {
      final preview = ServerPastePreview.parse(
        '地址: https://a.test\n用户名: alice\n密码: one\n'
        '线路2: https://backup-a.test\n地址: https://b.test\n'
        '用户名: bob\n密码: two\n线路3: https://backup-b.test',
      );
      expect(preview.groups, hasLength(2));
      expect(preview.groups.first.username, 'alice');
      expect(preview.groups.first.lines, [
        'https://a.test',
        'https://backup-a.test',
      ]);
      expect(preview.groups.last.username, 'bob');
      expect(preview.groups.last.lines, [
        'https://b.test',
        'https://backup-b.test',
      ]);
    },
  );

  test('paste grouping leaves ambiguous plain addresses in an editable account-free group', () {
    for (final text in [
      '名称: A\n地址: https://a.test\n用户名: alice\n密码: one\n'
          'https://unassigned.test\n名称: B\n地址: https://b.test\n用户名: bob\n密码: two',
      '地址: https://a.test\n用户名: alice\n密码: one\n'
          'https://unassigned.test\nhttps://second-unassigned.test\n用户名: bob\n密码: two',
    ]) {
      final preview = ServerPastePreview.parse(text);
      expect(preview.needsGroupSelection, isTrue);
      expect(preview.groups, hasLength(3));
      expect(preview.groups.first.lines, ['https://a.test']);
      final unassigned = preview.groups[1];
      expect(unassigned.username, isEmpty);
      expect(unassigned.password, isEmpty);
      expect(unassigned.lines, contains('https://unassigned.test'));
      expect(preview.groups.last.username, 'bob');
      expect(
        preview.groups.last.lines,
        isNot(contains('https://unassigned.test')),
      );
      // The explicit preview edit assigns an account without mutating either
      // parsed neighboring account.
      unassigned.username = 'chosen-account';
      expect(preview.groups.first.username, 'alice');
      expect(preview.groups.last.username, 'bob');
    }
  });

  test('address-first accounts stay separated and same-account lines stay together', () {
    final preview = ServerPastePreview.parse(
      '地址: https://a.test\n用户名: alice\n密码: one\n'
      '地址: https://b.test\n用户名: bob\n密码: two',
    );
    expect(preview.groups, hasLength(2));
    expect(preview.groups.map((g) => g.username), ['alice', 'bob']);
    expect(preview.groups.map((g) => g.lines.single), [
      'https://a.test',
      'https://b.test',
    ]);
    final partial = ServerPastePreview.parse(
      '名称: Server\n地址: https://a.test\n用户名: alice\n'
      '地址: https://b.test\n用户名: bob',
    );
    expect(partial.groups.map((g) => g.lines.single), [
      'https://a.test',
      'https://b.test',
    ]);
    final multi = ServerPastePreview.parse(
      '地址: https://a.test\n用户名: alice\n密码: one\n线路2: https://b.test',
    );
    expect(multi.groups.single.lines, ['https://a.test', 'https://b.test']);
  });

  test(
    'reset discards failed paste name and lines before manual addition',
    () async {
      final controller = ProviderConnectController(auth: auth);
      addTearDown(controller.dispose);
      final draft = ServerPastePreview.parse(
        '名称: Cancelled\n用户名: alice\n密码: correct-horse\n'
        '${primary.baseUrl}\n${other.baseUrl}',
      ).groups.single;
      await controller.submitDraft(draft);
      expect(controller.failure, MediaServerFailureKind.incompatibleServer);
      controller.reset();
      expect(controller.displayName, isNull);
      expect(controller.extraLines, isEmpty);
      await controller.password(
        other.baseUrl.toString(),
        'alice',
        'correct-horse',
      );
      expect(controller.failure, isNull);
      expect(controller.stage, ProviderConnectStage.done);
      expect(auth.session!.server.nickname, isNull);
      expect(
        auth.session!.server.lines.single.address,
        other.baseUrl.toString(),
      );
    },
  );

  test('address validation preserves port and prefix and rejects credential-bearing URLs', () {
    expect(
      normalizeServerAddress(' https://HOST.test:8443/emby/ ').toString(),
      'https://host.test:8443/emby',
    );
    for (final value in [
      'ftp://host',
      'https://u:p@host',
      'https://host?api_key=secret',
      'https://host#token',
    ]) {
      expect(
        () => normalizeServerAddress(value),
        throwsA(isA<MediaServerException>()),
      );
    }
  });
  test('new authorization and logout reject late candidates without reviving credentials', () async {
    final server = auth.savedServers.single;
    final credential = (await auth.credentials.read(server.id))!;
    final session = await auth.sources.ensureSession(server.id);
    final permit = auth.sources.permit(session.account);
    final first = await auth.sources.beginAuthorization(
      serviceType: MediaServerType.emby,
      configuredServerId: server.id,
    );
    final second = await auth.sources.beginAuthorization(
      serviceType: MediaServerType.emby,
      configuredServerId: server.id,
    );
    expect(first.isValid, isFalse);
    expect(second.isValid, isTrue);
    expect(permit.isValid, isTrue);
    await expectLater(
      auth.sources.commitAuthorization(
        first,
        server: server,
        value: credential,
      ),
      throwsStateError,
    );
    await auth.sources.logoutSource(server.id);
    expect(second.isValid, isFalse);
    await expectLater(
      auth.sources.commitAuthorization(
        second,
        server: server,
        value: credential,
      ),
      throwsStateError,
    );
    expect(await auth.credentials.read(server.id), isNull);
    expect(
      (await FileServerListStore(store.file).load()).servers.single.id,
      server.id,
    );
    expect(permit.isValid, isFalse);
  });

  test('Emby public, password and token requests never follow a cross-origin redirect', () async {
    final destination = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => destination.close(force: true));
    addTearDown(() => origin.close(force: true));
    var leaked = 0;
    destination.listen((request) async {
      leaked++;
      await request.response.close();
    });
    origin.listen((request) async {
      request.response.statusCode = 307;
      request.response.headers.set(
        'location',
        'http://127.0.0.1:${destination.port}/received',
      );
      await request.response.close();
    });
    final client = EmbyClient(device: auth.client.device);
    final uri = Uri.parse('http://127.0.0.1:${origin.port}');
    await expectLater(
      client.getPublicInfo(uri),
      throwsA(isA<MediaServerException>()),
    );
    await expectLater(
      client.authenticateByName(
        baseUrl: uri,
        username: 'user',
        password: 'secret',
        serverId: 'id',
      ),
      throwsA(isA<MediaServerException>()),
    );
    client.attachSession(
      baseUrl: uri,
      accessToken: 'secret-token',
      userId: 'user',
    );
    await expectLater(client.getUser(), throwsA(isA<MediaServerException>()));
    expect(leaked, 0);
    client.clearSession();
  });
  test('connection feedback classifies identity and strips server-echoed credentials', () {
    final failure = connectionFailure(
      const MediaServerException(
        MediaServerFailureKind.forbidden,
        statusCode: 403,
        detail: 'token=private-value password=private-password',
      ),
    );
    expect(failure.kind, MediaServerFailureKind.forbidden);
    expect(failure.detail, 'HTTP 403');
    expect(failure.toString(), isNot(contains('private-')));
    expect(
      connectionFailure(StateError('Server identity mismatch')).kind,
      MediaServerFailureKind.incompatibleServer,
    );
    expect(
      connectionFailure(StateError('Authorization revoked')).kind,
      MediaServerFailureKind.cancelled,
    );
  });
}
