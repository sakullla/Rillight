import 'dart:async';

import 'package:rillight/auth/server_entry_coordinator.dart';
import 'package:rillight/auth/server_access_credentials.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/auth/server_access.dart';
import 'package:rillight/auth/server_list_store.dart';

SavedServer _server(String id, {String? protection}) => SavedServer(
  id: id,
  name: id,
  username: 'user',
  protectionRef: protection,
  lines: const [ServerLine(id: 'line', address: 'https://test.example')],
);

class _FailingStore extends MemoryServerAccessStore {
  bool fail = false;
  @override
  Future<void> write(String reference, ServerAccessRecord record) async {
    if (fail) throw StateError('write failed');
    await super.write(reference, record);
  }
}

void main() {
  test('entry cancellation discards late password and preserves original destination', () async {
    final access = ServerAccessController(store: MemoryServerAccessStore());
    addTearDown(access.dispose);
    final server = _server('protected');
    await access.register(server);
    await access.setPassword(server.id, 'local', 'local');
    final coordinator = ServerEntryCoordinator(access);
    final answer = Completer<String?>();
    final requested = Completer<void>();
    var connected = false, navigated = false;
    final pending = coordinator.enter<String>(
      server: server,
      destination: '/item/original',
      requestPassword: () {
        requested.complete();
        return answer.future;
      },
      connect: (_) async {
        connected = true;
        return true;
      },
      navigate: (_) async {
        navigated = true;
      },
    );
    final rejected = expectLater(pending, throwsStateError);
    await requested.future;
    coordinator.cancel();
    answer.complete('local');
    await rejected;
    expect(connected, isFalse);
    expect(navigated, isFalse);
    expect(access.allows(server.id), isFalse);
  });

  test('entry only publishes unlock and locks old server after a successful connection', () async {
    final access = ServerAccessController(store: MemoryServerAccessStore());
    addTearDown(access.dispose);
    final old = _server('old'), next = _server('next');
    for (final server in [old, next]) {
      await access.register(server);
      await access.setPassword(server.id, 'local', 'local');
    }
    await access.unlock(old.id, 'local');
    final coordinator = ServerEntryCoordinator(access);
    String? reached;
    Future<bool> enter(bool connected) => coordinator.enter<String>(
      server: next,
      destination: '/item/target?resume=1',
      requestPassword: () async => 'local',
      connect: (guard) async {
        guard();
        expect(access.allows(next.id), isFalse);
        return connected;
      },
      navigate: (destination) async {
        reached = destination;
      },
    );
    expect(await enter(false), isFalse);
    expect(access.allows(old.id), isTrue);
    expect(access.allows(next.id), isFalse);
    expect(reached, isNull);
    expect(await enter(true), isTrue);
    expect(access.allows(old.id), isFalse);
    expect(access.allows(next.id), isTrue);
    expect(reached, '/item/target?resume=1');
  });

  test('credential-backed entry verifier survives a fresh controller without touching remote login', () async {
    final credentials = MemoryCredentialStore({
      'a': const StoredCredentials(
        accessToken: 'remote-token',
        userId: 'u',
        username: 'alice',
      ),
    });
    final store = CredentialServerAccessStore(credentials);
    final access = ServerAccessController(store: store);
    addTearDown(access.dispose);
    await access.register(_server('a'));
    String? reference;
    await access.setPassword(
      'a',
      ' 本机 password ',
      ' 本机 password ',
      persistReference: (value) async {
        reference = value;
      },
    );
    final restored = ServerAccessController(store: store);
    addTearDown(restored.dispose);
    await restored.register(_server('a', protection: reference));
    expect(restored.allows('a'), isFalse);
    expect(await restored.unlock('a', ' 本机 password '), isTrue);
    expect((await credentials.read('a'))!.accessToken, 'remote-token');
  });

  test(
    'failed configuration commit leaves the previous password and permit valid',
    () async {
      final store = MemoryServerAccessStore();
      final access = ServerAccessController(store: store);
      addTearDown(access.dispose);
      await access.register(_server('a'));
      final ref = await access.setPassword('a', 'old', 'old');
      expect(await access.unlock('a', 'old'), isTrue);
      final permit = access.permit('a')!;
      await expectLater(
        access.setPassword(
          'a',
          'new',
          'new',
          oldPassword: 'old',
          persistReference: (_) async =>
              throw StateError('configuration disk full'),
        ),
        throwsStateError,
      );
      expect(access.protectionRef('a'), ref);
      expect(permit.isValid, isTrue);
      expect(store.records.keys, [ref]);
      expect(await access.unlock('a', 'old'), isTrue);
    },
  );
  test(
    'passwords preserve text, use independent salt and reject invalid input',
    () async {
      final a = await ServerPasswordVerifier.create(' 文字 123 ');
      final b = await ServerPasswordVerifier.create(' 文字 123 ');
      expect(a.salt, isNot(b.salt));
      expect(a.iterations, 210000);
      expect(await a.matches(' 文字 123 '), isTrue);
      expect(await a.matches('文字 123'), isFalse);
      expect(
        await ServerPasswordVerifier.fromJson(a.toJson()).matches(' 文字 123 '),
        isTrue,
      );
      await expectLater(ServerPasswordVerifier.create(''), throwsArgumentError);
      await expectLater(
        ServerPasswordVerifier.create('a' * 1025),
        throwsArgumentError,
      );
    },
  );

  test(
    'per-server unlock, backoff, restart and changed password are isolated',
    () async {
      final store = MemoryServerAccessStore();
      var now = DateTime.utc(2026);
      final access = ServerAccessController(store: store, clock: () => now);
      addTearDown(access.dispose);
      await access.register(_server('a'));
      await access.register(_server('b'));
      await access.setPassword('a', 'one', 'one');
      final bRef = await access.setPassword('b', 'two', 'two');
      expect(await access.unlock('a', 'wrong'), isFalse);
      expect(access.retryAt('a'), isNotNull);
      expect(await access.unlock('b', 'two'), isTrue);
      expect(access.retryAt('b'), isNull);
      expect(await access.unlock('a', 'one'), isFalse);
      now = now.add(const Duration(minutes: 1));
      expect(await access.unlock('a', 'one'), isTrue);
      final permit = access.permit('a')!;
      final aRef = await access.setPassword(
        'a',
        'new',
        'new',
        oldPassword: 'one',
      );
      expect(permit.isValid, isFalse);
      expect(access.allows('b'), isTrue);
      expect(await access.unlock('a', 'new'), isTrue);
      access.didEnter('b');
      expect(access.allows('a'), isFalse);
      final restarted = ServerAccessController(store: store);
      addTearDown(restarted.dispose);
      await restarted.register(_server('a', protection: aRef));
      await restarted.register(_server('b', protection: bRef));
      expect(restarted.allows('a'), isFalse);
      expect(restarted.allows('b'), isFalse);
      expect(await restarted.unlock('a', 'new'), isTrue);
      expect(await restarted.unlock('b', 'two'), isTrue);
    },
  );

  test(
    'old password, confirmation and storage failures keep previous settings',
    () async {
      final store = _FailingStore();
      final access = ServerAccessController(store: store);
      addTearDown(access.dispose);
      await access.register(_server('a'));
      final ref = await access.setPassword('a', 'old', 'old');
      final before = store.records[ref];
      await expectLater(
        access.setPassword('a', 'new', 'different', oldPassword: 'old'),
        throwsArgumentError,
      );
      expect(store.records[ref], same(before));
      store.fail = true;
      await expectLater(
        access.setPassword('a', 'new', 'new', oldPassword: 'old'),
        throwsStateError,
      );
      await expectLater(access.disablePassword('a', 'old'), throwsStateError);
      expect(store.records[ref], same(before));
      expect(await access.unlock('a', 'old'), isTrue);
      store.fail = false;
      await expectLater(access.disablePassword('a', 'wrong'), throwsStateError);
      expect(store.records[ref], same(before));
    },
  );

  test('candidate cancellation and lock revoke late unlock without publishing content', () async {
    final store = MemoryServerAccessStore();
    final access = ServerAccessController(store: store);
    addTearDown(access.dispose);
    await access.register(_server('a'));
    await access.setPassword('a', 'password', 'password');
    final candidate = (await access.prepareUnlock('a', 'password'))!;
    expect(access.allows('a'), isFalse);
    candidate.cancel();
    expect(access.commitUnlock(candidate), isFalse);
    final late = access.unlock('a', 'password');
    access.lock('a');
    expect(await late, isFalse);
    expect(await access.unlock('a', 'password'), isTrue);
    final permit = access.permit('a')!;
    access.unregister('a');
    await access.register(_server('a'));
    expect(permit.isValid, isFalse);
  });

  test(
    'missing or corrupt secure record stays protected and cannot be disabled',
    () async {
      final secure = SecureServerAccessStore(
        readSecure: (_) async => 'bad json',
        writeSecure: (_, _) async {},
        deleteSecure: (_) async {},
      );
      final access = ServerAccessController(store: secure);
      addTearDown(access.dispose);
      await access.register(_server('a', protection: 'missing'));
      expect(access.isUnavailable('a'), isTrue);
      expect(access.allows('a'), isFalse);
      expect(await access.unlock('a', 'password'), isFalse);
      await expectLater(
        access.disablePassword('a', 'password'),
        throwsStateError,
      );
      expect(access.allows('unregistered'), isFalse);
    },
  );

  test('disabling requires current password and survives restart', () async {
    final store = MemoryServerAccessStore();
    final access = ServerAccessController(store: store);
    addTearDown(access.dispose);
    await access.register(_server('a'));
    await access.setPassword('a', 'password', 'password');
    final ref = await access.disablePassword('a', 'password');
    expect(access.allows('a'), isTrue);
    final restarted = ServerAccessController(store: store);
    addTearDown(restarted.dispose);
    await restarted.register(_server('a', protection: ref));
    expect(restarted.isProtected('a'), isFalse);
    expect(restarted.allows('a'), isTrue);
  });
}
