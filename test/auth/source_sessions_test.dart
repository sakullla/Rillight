import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/auth/credential_store.dart';
import 'package:rillight/auth/region_access.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/auth/source_sessions.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/player/playback_models.dart';

const device = EmbyDeviceInfo(
  clientName: 'test',
  deviceName: 'test',
  deviceId: 'test',
  version: '1',
);

void main() {
  test(
    'real HTTP sessions preserve token ownership; local 401 and manual status are independent',
    () async {
      final hosts = <HttpServer>[];
      var expireA = false;
      var mismatchA = false;
      final requests = <String>[];
      for (final id in ['a', 'b']) {
        final host = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        hosts.add(host);
        host.listen((request) async {
          request.response.headers.contentType = ContentType.json;
          if (request.uri.path.endsWith('/System/Info/Public')) {
            request.response.write(
              jsonEncode({
                'Id': id == 'a' && mismatchA ? 'impostor' : id,
                'ServerName': id,
              }),
            );
          } else {
            requests.add('$id:${request.headers.value('X-Emby-Token')}');
            if (id == 'a' && expireA) {
              request.response.statusCode = 401;
              request.response.write('{}');
            } else {
              request.response.write(
                jsonEncode({'Id': 'user-$id', 'Name': id}),
              );
            }
          }
          await request.response.close();
        });
      }
      addTearDown(() async {
        for (final host in hosts) {
          await host.close(force: true);
        }
      });
      final saved = [
        for (var i = 0; i < hosts.length; i++)
          SavedServer(
            id: i == 0 ? 'a' : 'b',
            name: 'server',
            username: 'user',
            lines: [
              ServerLine(
                id: 'line',
                address: 'http://127.0.0.1:${hosts[i].port}',
              ),
            ],
            libraryIds: const ['movies'],
            scopeKnown: true,
          ),
      ];
      final store = MemoryServerListStore(ServerListSnapshot(servers: saved));
      final r = SourceSessionRegistry(
        access: RegionAccessController(),
        store: store,
        credentials: MemoryCredentialStore({
          for (final s in saved)
            s.id: StoredCredentials(
              accessToken: 'token-${s.id}',
              userId: 'user-${s.id}',
              username: 'user',
            ),
        }),
        createClient: () => EmbyClient(device: device),
      );
      addTearDown(r.dispose);
      await r.load();
      final sessions = await Future.wait([
        r.authenticate('a'),
        r.authenticate('b'),
      ]);
      final a = r.permit(sessions[0].account);
      final b = r.permit(sessions[1].account);
      await Future.wait([
        a.dispatch((c) => c.getUser()),
        b.dispatch((c) => c.getUser()),
      ]);
      expect(requests, containsAll(['a:token-a', 'b:token-b']));
      expireA = true;
      await expectLater(a.dispatch((c) => c.getUser()), throwsStateError);
      expect(a.isValid, false);
      expect(b.isValid, true);
      expect((await r.check('a')).status, ManualCheckStatus.needsLogin);
      expect(sessions[1].client.accessToken, 'token-b');
      expireA = false;
      mismatchA = true;
      final count = requests.length;
      expect((await r.check('a')).status, ManualCheckStatus.identityMismatch);
      expect(
        requests.length,
        count,
        reason: 'Never dispatch credentials to an identity mismatch',
      );
      expect(
        (await store.load()).servers.first.checkStatus,
        'identityMismatch',
      );
      expect((await store.load()).servers.first.checkedAt, isNotNull);
    },
  );

  test(
    'frozen close sends exactly one source-owned Stopped and cannot run after locked',
    () async {
      final host = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => host.close(force: true));
      final paths = <String>[];
      host.listen((request) async {
        paths.add(request.uri.path);
        request.response.headers.contentType = ContentType.json;
        if (request.uri.path.endsWith('/System/Info/Public')) {
          request.response.write(
            jsonEncode({'Id': 'secret', 'ServerName': 'secret'}),
          );
        } else if (request.uri.path.endsWith('/Stopped')) {
          expect(request.headers.value('X-Emby-Token'), 'secret-token');
          final body =
              jsonDecode(await utf8.decoder.bind(request).join()) as Map;
          expect(body['ItemId'], 'item');
          expect(body['PositionTicks'], 123);
          request.response.write('{}');
        } else {
          request.response.write(jsonEncode({'Id': 'user', 'Name': 'user'}));
        }
        await request.response.close();
      });
      final access = RegionAccessController(
        verifier: await PinVerifier.create('1234'),
      );
      await access.unlock('1234');
      final r = SourceSessionRegistry(
        access: access,
        store: MemoryServerListStore(
          ServerListSnapshot(
            servers: [
              SavedServer(
                id: 'secret',
                name: 'secret',
                username: 'user',
                region: AccessRegion.private,
                lines: [
                  ServerLine(
                    id: 'line',
                    address: 'http://127.0.0.1:${host.port}',
                  ),
                ],
                libraryIds: const ['movies'],
                scopeKnown: true,
              ),
            ],
          ),
        ),
        credentials: MemoryCredentialStore({
          'secret': const StoredCredentials(
            accessToken: 'secret-token',
            userId: 'user',
            username: 'user',
          ),
        }),
        createClient: () => EmbyClient(device: device),
      );
      addTearDown(r.dispose);
      await r.load();
      final session = await r.authenticate('secret');
      final stop = r.freezeStop(
        r.permit(session.account),
        const PlaybackReport(
          itemId: 'item',
          mediaSourceId: 'version',
          playSessionId: 'play',
          playMethod: PlayMethod.directPlay,
          positionTicks: 123,
        ),
      );
      RestrictedStopPermit? closing;
      access.addCleanupHook((permit) async {
        closing = permit;
        await stop.reportStopped(permit);
      });
      await access.lock();
      expect(paths.where((p) => p.endsWith('/Stopped')), hasLength(1));
      expect(session.client.hasSession, false);
      await expectLater(stop.reportStopped(closing!), throwsStateError);
      expect(paths.where((p) => p.endsWith('/Stopped')), hasLength(1));
    },
  );
}
