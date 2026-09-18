import '../helpers/image_cache_fixture.dart';
import '../helpers/settle.dart';
import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/auth/session_actions.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/player/desktop_player_window.dart';
import 'package:rillight/player/playback_session_snapshot.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/player/player_host_command.dart';
import 'package:rillight/player/player_window_host.dart';
import 'package:window_manager/window_manager.dart';

import '../emby/fake_emby_server.dart';
import 'fake_player_process_control.dart';

const _device = EmbyDeviceInfo(
  clientName: '灯川 Rillight',
  deviceName: 'test',
  deviceId: 'device-host',
  version: '0.1.0',
);

/// 把 logout/switchTo 记入与进程控制假实现共享的调用序列。
class _TrackingAuth extends AuthController {
  _TrackingAuth({
    required super.client,
    required super.credentials,
    required super.servers,
    required this.calls,
  });

  final List<String> calls;

  @override
  Future<void> logout() {
    calls.add('logout');
    return super.logout();
  }

  @override
  Future<void> switchTo(String serverId, {String? lineId}) {
    calls.add('switchTo:$serverId');
    return super.switchTo(serverId, lineId: lineId);
  }
}

void main() {
  setUp(isolateImageCache);
  late FakeEmbyServer server;
  late FakeEmbyAdapter adapter;
  late List<String> calls;
  late FakePlayerProcessControl control;
  late Map<int, MemoryPlaybackSessionSnapshotStore> stores;

  setUp(() {
    server = FakeEmbyServer();
    adapter = FakeEmbyAdapter([server]);
    calls = <String>[];
    control = FakePlayerProcessControl(calls: calls);
    stores = <int, MemoryPlaybackSessionSnapshotStore>{};
  });

  MemoryPlaybackSessionSnapshotStore storeFor(int pid) {
    return stores.putIfAbsent(pid, MemoryPlaybackSessionSnapshotStore.new);
  }

  _TrackingAuth newAuth() {
    return _TrackingAuth(
      client: EmbyClient(device: _device, dio: dioForFakeEmby(adapter)),
      credentials: MemoryCredentialStore(),
      servers: MemoryServerListStore(),
      calls: calls,
    );
  }

  Future<_TrackingAuth> loggedInAuth() async {
    final auth = newAuth();
    await auth.connect(
      address: server.baseUrl.toString(),
      username: 'alice',
      password: 'correct-horse',
    );
    expect(auth.isLoggedIn, isTrue);
    return auth;
  }

  DesktopPlayerWindowHost newHost(
    AuthController auth, {
    PlayerHostOpenItemConsumer? consumeOpenItem,
  }) {
    return DesktopPlayerWindowHost(
      auth: auth,
      processControl: control,
      snapshotStoreForPid: storeFor,
      consumeOpenItem: consumeOpenItem ?? () async => null,
      closeTimeout: const Duration(milliseconds: 50),
      reportTimeout: const Duration(milliseconds: 50),
      watchInterval: const Duration(milliseconds: 10),
    );
  }

  PlaybackSessionSnapshot snapshotFor(
    AuthController auth, {
    String? baseUrl,
    String? userId,
    int positionTicks = 4200000000,
  }) {
    return PlaybackSessionSnapshot(
      itemId: 'movie-up',
      mediaSourceId: 'source-up',
      playSessionId: 'play-host-1',
      positionTicks: positionTicks,
      baseUrl: baseUrl ?? auth.client.baseUrl!.toString(),
      userId: userId ?? auth.client.userId!,
      timestamp: DateTime.utc(2026, 9, 14),
    );
  }

  List<FakePlaybackEvent> stoppedEvents() {
    return [
      for (final event in server.playbackEvents)
        if (event.kind == 'Stopped') event,
    ];
  }

  group('DesktopPlayerWindowHost', () {
    test(
      'a delayed detail command cannot route after another player opens',
      () async {
        final auth = await loggedInAuth();
        final gate = Completer<PlayerHostOpenItemCommand?>();
        var consumed = false;
        final host = newHost(
          auth,
          consumeOpenItem: () async {
            if (consumed) return null;
            consumed = true;
            return gate.future;
          },
        );
        addTearDown(() {
          host.dispose();
          auth.dispose();
        });
        String? routed;
        host.onOpenItemRoute = (id, {seasonId}) => routed = id;
        await host.open(const PlayerOpenRequest(itemId: 'movie-up'));
        for (var i = 0; i < 50 && !consumed; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 2));
        }
        expect(consumed, isTrue);
        await host.open(const PlayerOpenRequest(itemId: 'movie-inception'));
        gate.complete(const PlayerHostOpenItemCommand(itemId: 'old-detail'));
        await Future<void>.delayed(Duration.zero);
        expect(routed, isNull);
        expect(host.current?.itemId, 'movie-inception');
      },
    );

    test('close during spawn cannot publish the late player window', () async {
      final auth = await loggedInAuth();
      final host = newHost(auth);
      addTearDown(() {
        host.dispose();
        auth.dispose();
      });
      control.spawnHold = Completer<void>();
      final opening = host.open(const PlayerOpenRequest(itemId: 'movie-up'));
      for (var i = 0; i < 50 && control.spawnedArguments.isEmpty; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      final closing = host.close();
      control.spawnHold!.complete();
      await Future.wait([opening, closing]);
      expect(host.current, isNull);
      expect(control.alive, isEmpty);
      expect(calls.where((e) => e.startsWith('kill:')), hasLength(1));
    });

    test('opening a second item requests close, kills on timeout, and resends '
        'Stopped once from the snapshot before deleting it', () async {
      final auth = await loggedInAuth();
      final host = newHost(auth);
      addTearDown(() {
        host.dispose();
        auth.dispose();
      });

      await host.open(const PlayerOpenRequest(itemId: 'movie-up'));
      final firstPid = control.lastPid;
      expect(host.current?.itemId, 'movie-up');
      await storeFor(firstPid).write(snapshotFor(auth));

      await host.open(const PlayerOpenRequest(itemId: 'movie-inception'));

      expect(calls, [
        'spawn:$firstPid',
        'requestClose:$firstPid',
        'kill:$firstPid',
        'spawn:${firstPid + 1}',
      ]);
      expect(host.current?.itemId, 'movie-inception');
      final stopped = stoppedEvents();
      expect(stopped, hasLength(1));
      expect(stopped.single.body['ItemId'], 'movie-up');
      expect(stopped.single.body['PlaySessionId'], 'play-host-1');
      expect(stopped.single.body['PositionTicks'], 4200000000);
      expect(storeFor(firstPid).snapshot, isNull);
      expect(storeFor(firstPid).deleteCount, 1);
    });

    for (final reopen in [false, true]) {
      test('cancelled late spawn reconciles after exit and before release '
          'when ${reopen ? 'reopening' : 'closing'}', () async {
        final auth = await loggedInAuth();
        final host = newHost(auth);
        addTearDown(() {
          host.dispose();
          auth.dispose();
        });
        control.spawnHold = Completer<void>();
        control.killHold = Completer<void>();
        final opening = host.open(const PlayerOpenRequest(itemId: 'movie-up'));
        for (var i = 0; i < 50 && control.spawnedArguments.isEmpty; i++) {
          await Future<void>.delayed(Duration.zero);
        }
        final pid = control.lastPid;
        await storeFor(pid).write(snapshotFor(auth));
        var released = false;
        control.onRelease = (releasedPid) {
          if (releasedPid != pid) return;
          expect(control.isAlive(pid), isFalse);
          expect(stoppedEvents(), hasLength(1));
          expect(storeFor(pid).snapshot, isNull);
          released = true;
        };
        final next = reopen
            ? host.open(const PlayerOpenRequest(itemId: 'movie-inception'))
            : host.close();
        control.spawnHold!.complete();
        for (var i = 0; i < 50 && !calls.contains('kill:$pid'); i++) {
          await Future<void>.delayed(Duration.zero);
        }
        expect(calls, contains('kill:$pid'));
        expect(stoppedEvents(), isEmpty);
        expect(released, isFalse);
        control.killHold!.complete();
        await Future.wait([opening, next]);
        expect(released, isTrue);
        expect(stoppedEvents().single.body['PlaySessionId'], 'play-host-1');
        expect(host.current?.itemId, reopen ? 'movie-inception' : null);
        control.onRelease = null;
        await host.close();
      });
    }

    for (final foreignSnapshot in [false, true]) {
      test(
        'cancelled late spawn retains ${foreignSnapshot ? 'foreign' : 'failed'} '
        'Stopped snapshot',
        () async {
          final auth = await loggedInAuth();
          final host = newHost(auth);
          addTearDown(() {
            host.dispose();
            auth.dispose();
          });
          server.stoppedStatus = 500;
          control.spawnHold = Completer<void>();
          final opening = host.open(
            const PlayerOpenRequest(itemId: 'movie-up'),
          );
          for (var i = 0; i < 50 && control.spawnedArguments.isEmpty; i++) {
            await Future<void>.delayed(Duration.zero);
          }
          final pid = control.lastPid;
          await storeFor(pid).write(
            snapshotFor(auth, userId: foreignSnapshot ? 'another-user' : null),
          );
          final closing = host.close();
          control.spawnHold!.complete();
          await Future.wait([opening, closing]);
          expect(stoppedEvents(), hasLength(foreignSnapshot ? 0 : 1));
          expect(storeFor(pid).snapshot, isNotNull);
          expect(storeFor(pid).deleteCount, 0);
        },
      );
    }

    test('watch delivers an open-item command to the main window', () async {
      final auth = await loggedInAuth();
      PlayerHostOpenItemCommand? pending;
      final host = newHost(
        auth,
        consumeOpenItem: () async {
          final command = pending;
          pending = null;
          return command;
        },
      );
      addTearDown(() {
        host.dispose();
        auth.dispose();
      });

      String? opened;
      String? openedSeason;
      host.onOpenItemRoute = (itemId, {seasonId}) {
        opened = itemId;
        openedSeason = seasonId;
      };
      await host.open(const PlayerOpenRequest(itemId: 'episode-friends-s1e1'));
      pending = const PlayerHostOpenItemCommand(
        itemId: 'series-friends',
        seasonId: 'season-friends-1',
      );
      for (var i = 0; i < 40 && opened == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(opened, 'series-friends');
      expect(openedSeason, 'season-friends-1');
    });

    test('graceful close skips kill and tolerates a stale snapshot', () async {
      final auth = await loggedInAuth();
      control.requestCloseResult = true;
      final host = newHost(auth);
      final notices = <PlayerHostNotice>[];
      host.notices.listen(notices.add);
      addTearDown(() {
        host.dispose();
        auth.dispose();
      });

      await host.open(const PlayerOpenRequest(itemId: 'movie-up'));
      final pid = control.lastPid;
      await storeFor(pid).write(snapshotFor(auth));
      await host.close();

      expect(calls, ['spawn:$pid', 'requestClose:$pid']);
      expect(host.current, isNull);
      expect(stoppedEvents(), hasLength(1));
      expect(storeFor(pid).snapshot, isNull);
      expect(notices, isEmpty);
    });

    test('no snapshot means nothing is resent', () async {
      final auth = await loggedInAuth();
      final host = newHost(auth);
      addTearDown(() {
        host.dispose();
        auth.dispose();
      });

      await host.open(const PlayerOpenRequest(itemId: 'movie-up'));
      await host.close();

      expect(stoppedEvents(), isEmpty);
      expect(host.current, isNull);
    });

    test('snapshot from another server or user is not resent', () async {
      final auth = await loggedInAuth();
      final host = newHost(auth);
      addTearDown(() {
        host.dispose();
        auth.dispose();
      });

      await host.open(const PlayerOpenRequest(itemId: 'movie-up'));
      final otherServerPid = control.lastPid;
      await storeFor(
        otherServerPid,
      ).write(snapshotFor(auth, baseUrl: 'http://other.test:8096/'));
      await host.close();
      expect(stoppedEvents(), isEmpty);
      expect(storeFor(otherServerPid).snapshot, isNotNull);
      expect(storeFor(otherServerPid).deleteCount, 0);

      await host.open(const PlayerOpenRequest(itemId: 'movie-up'));
      final otherUserPid = control.lastPid;
      await storeFor(otherUserPid).write(snapshotFor(auth, userId: 'user-bob'));
      await host.close();
      expect(stoppedEvents(), isEmpty);
      expect(storeFor(otherUserPid).snapshot, isNotNull);
    });

    test('an unexpectedly exited process is detected, cleared and its Stopped '
        'is resent', () async {
      final auth = await loggedInAuth();
      addTearDown(auth.dispose);

      fakeAsync((async) {
        final host = newHost(auth);
        addTearDown(host.dispose);

        var opened = false;
        host.open(const PlayerOpenRequest(itemId: 'movie-up')).then((_) {
          opened = true;
        });
        async.flushMicrotasks();
        expect(opened, isTrue);
        final pid = control.lastPid;

        var wrote = false;
        storeFor(pid).write(snapshotFor(auth, positionTicks: 777)).then((_) {
          wrote = true;
        });
        async.flushMicrotasks();
        expect(wrote, isTrue);

        control.exit(pid);
        async.elapse(const Duration(milliseconds: 20));
        async.flushMicrotasks();

        expect(host.current, isNull);
        expect(stoppedEvents(), hasLength(1));
        expect(stoppedEvents().single.body['PositionTicks'], 777);
        expect(calls, ['spawn:$pid']);
        async.elapse(const Duration(milliseconds: 20));
        async.flushMicrotasks();
        expect(storeFor(pid).snapshot, isNull);
      });
    });

    test(
      'a failed resend keeps the snapshot and emits progressSyncFailed',
      () async {
        final auth = await loggedInAuth();
        final host = newHost(auth);
        final notices = <PlayerHostNotice>[];
        host.notices.listen(notices.add);
        addTearDown(() {
          host.dispose();
          auth.dispose();
        });
        server.stoppedStatus = 500;

        await host.open(const PlayerOpenRequest(itemId: 'movie-up'));
        final pid = control.lastPid;
        await storeFor(pid).write(snapshotFor(auth));
        await host.close();
        // 广播流异步投递,让出一个事件循环再断言。
        await Future<void>.delayed(Duration.zero);

        expect(stoppedEvents(), hasLength(1));
        expect(storeFor(pid).snapshot, isNotNull);
        expect(storeFor(pid).deleteCount, 0);
        expect(notices, [PlayerHostNotice.progressSyncFailed]);
      },
    );

    test('overlapping close then open keeps the new pid watched', () async {
      final auth = await loggedInAuth();
      addTearDown(auth.dispose);

      fakeAsync((async) {
        final host = newHost(auth);
        addTearDown(host.dispose);

        var opened = false;
        host.open(const PlayerOpenRequest(itemId: 'movie-up')).then((_) {
          opened = true;
        });
        async.flushMicrotasks();
        expect(opened, isTrue);
        final firstPid = control.lastPid;
        control.requestCloseHold = Completer<void>();

        var closed = false;
        host.close().then((_) => closed = true);
        async.flushMicrotasks();
        expect(calls, contains('requestClose:$firstPid'));

        var openedSecond = false;
        host.open(const PlayerOpenRequest(itemId: 'movie-inception')).then((_) {
          openedSecond = true;
        });
        control.requestCloseHold!.complete();
        async.flushMicrotasks();
        expect(closed, isTrue);
        expect(openedSecond, isTrue);

        final secondPid = control.lastPid;
        expect(secondPid, firstPid + 1);
        expect(host.current?.itemId, 'movie-inception');
        expect(control.isAlive(secondPid), isTrue);
        expect(control.isAlive(firstPid), isFalse);
        expect(calls, [
          'spawn:$firstPid',
          'requestClose:$firstPid',
          'kill:$firstPid',
          'spawn:$secondPid',
        ]);

        control.exit(secondPid);
        async.elapse(const Duration(milliseconds: 20));
        async.flushMicrotasks();
        expect(host.current, isNull);
      });
    });

    test('close joins watcher reconcile before logout', () async {
      final auth = await loggedInAuth();
      final releaseRead = Completer<void>();
      final host = DesktopPlayerWindowHost(
        auth: auth,
        processControl: control,
        snapshotStoreForPid: (pid) => _GatedReadSnapshotStore(
          storeFor(pid),
          calls: calls,
          pid: pid,
          gate: releaseRead,
        ),
        consumeOpenItem: () async => null,
        closeTimeout: const Duration(milliseconds: 50),
        reportTimeout: const Duration(milliseconds: 50),
        watchInterval: const Duration(milliseconds: 10),
      );
      addTearDown(() {
        if (!releaseRead.isCompleted) {
          releaseRead.complete();
        }
        host.dispose();
        auth.dispose();
      });

      await host.open(const PlayerOpenRequest(itemId: 'movie-up'));
      final pid = control.lastPid;
      await storeFor(pid).write(snapshotFor(auth));

      control.exit(pid);
      for (var i = 0; i < 100 && !calls.contains('reconcile:$pid'); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(calls, contains('reconcile:$pid'));
      expect(host.current, isNull);
      expect(stoppedEvents(), isEmpty);
      expect(auth.isLoggedIn, isTrue);

      var closed = false;
      final closeFuture = host.close().whenComplete(() => closed = true);
      await Future<void>.delayed(Duration.zero);
      expect(closed, isFalse);
      expect(stoppedEvents(), isEmpty);

      releaseRead.complete();
      await closeFuture;
      expect(closed, isTrue);
      expect(stoppedEvents(), hasLength(1));
      expect(storeFor(pid).snapshot, isNull);
      expect(auth.isLoggedIn, isTrue);

      await auth.logout();
      expect(
        calls,
        containsAllInOrder(['spawn:$pid', 'reconcile:$pid', 'logout']),
      );
    });

    test('logout without a prior close cannot resend (session gone)', () async {
      final auth = await loggedInAuth();
      final host = newHost(auth);
      addTearDown(() {
        host.dispose();
        auth.dispose();
      });

      await host.open(const PlayerOpenRequest(itemId: 'movie-up'));
      final pid = control.lastPid;
      await storeFor(pid).write(snapshotFor(auth));
      await auth.logout();
      for (var i = 0; i < 20 && host.current != null; i++) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(host.current, isNull);
      expect(calls, containsAllInOrder(['requestClose:$pid', 'kill:$pid']));
      expect(stoppedEvents(), isEmpty);
      expect(storeFor(pid).snapshot, isNotNull);
    });
  });

  group('main window integration', () {
    Future<_TrackingAuth> pumpLoggedIn(
      WidgetTester tester, {
      required DesktopPlayerWindowHost Function(AuthController auth) hostFor,
      Future<_TrackingAuth> Function()? authFor,
    }) async {
      final auth = await tester.runAsync(authFor ?? loggedInAuth);
      final app = RillightApp(
        auth: auth!,
        playerBindings: PlayerBindings(
          windowHost: hostFor(auth),
          snapshotStore: MemoryPlaybackSessionSnapshotStore(),
        ),
      );
      app.router.go('/item/movie-up');
      await tester.pumpWidget(app);
      await settle(tester);
      return auth;
    }

    Future<void> pumpUntil(
      WidgetTester tester,
      bool Function() done, {
      Duration step = const Duration(milliseconds: 20),
      int maxSteps = 100,
    }) async {
      for (var i = 0; i < maxSteps && !done(); i++) {
        await tester.pump(step);
      }
    }

    testWidgets(
      'a failed resend after the process vanished shows progressSyncFailedMain',
      (tester) async {
        late DesktopPlayerWindowHost host;
        final auth = await pumpLoggedIn(
          tester,
          hostFor: (auth) => host = newHost(auth),
        );
        addTearDown(() {
          host.dispose();
          auth.dispose();
        });
        server.stoppedStatus = 500;

        await host.open(const PlayerOpenRequest(itemId: 'movie-up'));
        final pid = control.lastPid;
        await storeFor(pid).write(snapshotFor(auth));
        await tester.pump();

        control.exit(pid);
        await pumpUntil(
          tester,
          () => find.text('播放进度未能同步').evaluate().isNotEmpty,
        );

        expect(find.text('播放进度未能同步'), findsOneWidget);
        expect(host.current, isNull);
        expect(storeFor(pid).snapshot, isNotNull);
      },
      tags: ['integration'],
    );

    testWidgets('logout closes the player window before auth.logout', (
      tester,
    ) async {
      late DesktopPlayerWindowHost host;
      final auth = await pumpLoggedIn(
        tester,
        hostFor: (auth) => host = newHost(auth),
      );
      addTearDown(() {
        host.dispose();
        auth.dispose();
      });

      await host.open(const PlayerOpenRequest(itemId: 'movie-up'));
      final pid = control.lastPid;
      await tester.pump();

      await tester.tap(find.byKey(SessionActions.serverMenuKey));
      await settle(tester);
      await tester.tap(find.text('退出登录'));
      await pumpUntil(tester, () => !auth.isLoggedIn);
      await settle(tester);

      expect(auth.isLoggedIn, isFalse);
      expect(
        calls,
        containsAllInOrder(['requestClose:$pid', 'kill:$pid', 'logout']),
      );
      expect(host.current, isNull);
    }, tags: ['integration']);

    testWidgets('switching servers closes the player window before switchTo', (
      tester,
    ) async {
      final other = FakeEmbyServer(
        serverId: 'server-id-2',
        serverName: '另一台',
        baseUrl: Uri.parse('http://emby-other.test:8096'),
      );
      adapter.add(other);
      late DesktopPlayerWindowHost host;
      final auth = await pumpLoggedIn(
        tester,
        hostFor: (auth) => host = newHost(auth),
        authFor: () async {
          final auth = newAuth();
          await auth.connect(
            address: other.baseUrl.toString(),
            username: 'alice',
            password: 'correct-horse',
          );
          await auth.connect(
            address: server.baseUrl.toString(),
            username: 'alice',
            password: 'correct-horse',
          );
          expect(auth.savedServers, hasLength(2));
          expect(auth.session?.server.id, server.serverId);
          return auth;
        },
      );
      addTearDown(() {
        host.dispose();
        auth.dispose();
      });

      await host.open(const PlayerOpenRequest(itemId: 'movie-up'));
      final pid = control.lastPid;
      await tester.pump();

      await tester.tap(find.byKey(SessionActions.serverMenuKey));
      await settle(tester);
      await tester.tap(find.text('另一台'));
      await pumpUntil(tester, () => auth.session?.server.id == other.serverId);
      await settle(tester);

      expect(auth.session?.server.id, other.serverId);
      expect(
        calls,
        containsAllInOrder([
          'requestClose:$pid',
          'kill:$pid',
          'switchTo:${other.serverId}',
        ]),
      );
      expect(host.current, isNull);
    }, tags: ['integration']);

    testWidgets('MainWindowCloseGuard closes the player before destroying', (
      tester,
    ) async {
      final auth = await tester.runAsync(loggedInAuth);
      final host = newHost(auth!);
      addTearDown(() {
        host.dispose();
        auth.dispose();
      });
      await host.open(const PlayerOpenRequest(itemId: 'movie-up'));
      final pid = control.lastPid;

      await tester.pumpWidget(
        MainWindowCloseGuard(
          host: host,
          destroyWindow: () async => calls.add('destroy'),
          child: const SizedBox(),
        ),
      );
      final listener =
          tester.state(find.byType(MainWindowCloseGuard)) as WindowListener;
      listener.onWindowClose();
      listener.onWindowClose();
      await tester.pump();
      await pumpUntil(tester, () => calls.contains('destroy'));

      expect(calls, [
        'spawn:$pid',
        'requestClose:$pid',
        'kill:$pid',
        'destroy',
      ]);
      expect(host.current, isNull);
    });

    testWidgets('MainWindowCloseGuard destroys immediately when idle', (
      tester,
    ) async {
      final host = OverlayPlayerWindowHost();
      addTearDown(host.dispose);
      var destroyed = false;
      await tester.pumpWidget(
        MainWindowCloseGuard(
          host: host,
          closeTimeout: const Duration(seconds: 8),
          destroyWindow: () async => destroyed = true,
          child: const SizedBox(),
        ),
      );
      final listener =
          tester.state(find.byType(MainWindowCloseGuard)) as WindowListener;
      listener.onWindowClose();
      await tester.pump();
      expect(destroyed, isTrue);
    });

    testWidgets(
      'MainWindowCloseGuard destroys after close and forceClose time out',
      (tester) async {
        final hang = Completer<void>();
        addTearDown(() {
          if (!hang.isCompleted) hang.complete();
        });
        final host = _HangingPlayerWindowHost(hang);
        addTearDown(host.dispose);
        await host.open(const PlayerOpenRequest(itemId: 'movie-up'));
        var destroyed = false;
        await tester.pumpWidget(
          MainWindowCloseGuard(
            host: host,
            closeTimeout: const Duration(milliseconds: 20),
            forceCloseTimeout: const Duration(milliseconds: 20),
            destroyWindow: () async => destroyed = true,
            child: const SizedBox(),
          ),
        );
        final listener =
            tester.state(find.byType(MainWindowCloseGuard)) as WindowListener;
        listener.onWindowClose();
        await pumpUntil(tester, () => destroyed);
        expect(destroyed, isTrue);
        expect(hang.isCompleted, isFalse);
      },
    );
  });
}

class _HangingPlayerWindowHost extends OverlayPlayerWindowHost {
  _HangingPlayerWindowHost(this.hang);

  final Completer<void> hang;

  @override
  Future<void> close() => hang.future;

  @override
  Future<void> forceClose() => hang.future;
}

/// 把 [read] 挂起,让测试在 watcher 已进入 reconcile 后再调用 close/logout。
class _GatedReadSnapshotStore implements PlaybackSessionSnapshotStore {
  _GatedReadSnapshotStore(
    this.inner, {
    required this.calls,
    required this.pid,
    required this.gate,
  });

  final MemoryPlaybackSessionSnapshotStore inner;
  final List<String> calls;
  final int pid;
  final Completer<void> gate;

  @override
  Future<void> write(PlaybackSessionSnapshot snapshot) => inner.write(snapshot);

  @override
  Future<PlaybackSessionSnapshot?> read() async {
    calls.add('reconcile:$pid');
    await gate.future;
    return inner.read();
  }

  @override
  Future<void> delete() => inner.delete();
}
