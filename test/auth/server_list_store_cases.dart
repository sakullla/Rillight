import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/auth/server_list_store.dart';

void main() {
  test('legacy saved server without lines becomes a single line', () async {
    final dir = await Directory.systemTemp.createTemp('rillight-servers');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/servers.json');
    await file.writeAsString(
      jsonEncode({
        'lastServerId': 'server-id-1',
        'servers': [
          {
            'id': 'server-id-1',
            'name': '灯川测试',
            'baseUrl': 'http://emby.test:8096',
            'username': 'alice',
          },
        ],
      }),
    );

    final snapshot = await FileServerListStore(file).load();
    expect(snapshot.lastServerId, 'server-id-1');
    expect(snapshot.servers, hasLength(1));
    expect(snapshot.servers.single.lines, hasLength(1));
    expect(
      snapshot.servers.single.lines.single.address,
      'http://emby.test:8096',
    );
    expect(snapshot.servers.single.baseUrl, 'http://emby.test:8096');
    expect(snapshot.servers.single.activeLineId, 'default');
  });

  test('server-level User-Agent round-trips through the file store', () async {
    final dir = await Directory.systemTemp.createTemp('rillight-servers');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/servers.json');
    final store = FileServerListStore(file);
    await store.save(
      const ServerListSnapshot(
        lastServerId: 'server-id-1',
        servers: [
          SavedServer(
            id: 'server-id-1',
            name: '灯川测试',
            username: 'alice',
            activeLineId: 'line-b',
            userAgent: 'ServerUA/1',
            lines: [
              ServerLine(id: 'line-a', address: 'http://lan.test:8096'),
              ServerLine(id: 'line-b', address: 'https://wan.test'),
            ],
          ),
        ],
      ),
    );

    final snapshot = await FileServerListStore(file).load();
    final server = snapshot.servers.single;
    expect(server.lines, hasLength(2));
    expect(server.baseUrl, 'https://wan.test');
    expect(server.normalizedUserAgent, 'ServerUA/1');
    // Lines carry only addresses; the UA lives at the server level.
    for (final line in server.lines) {
      expect(line.toJson().containsKey('userAgent'), isFalse);
    }
  });

  test(
    'legacy per-line User-Agent migrates to the active line server level',
    () async {
      final dir = await Directory.systemTemp.createTemp('rillight-servers');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/servers.json');
      await file.writeAsString(
        jsonEncode({
          'lastServerId': 'server-id-1',
          'servers': [
            {
              'id': 'server-id-1',
              'name': '灯川测试',
              'username': 'alice',
              'activeLineId': 'line-b',
              'lines': [
                {
                  'id': 'line-a',
                  'address': 'http://lan.test:8096',
                  'userAgent': 'LanUA/1',
                },
                {
                  'id': 'line-b',
                  'address': 'https://wan.test',
                  'userAgent': 'WanUA/2',
                },
              ],
            },
          ],
        }),
      );

      final snapshot = await FileServerListStore(file).load();
      final server = snapshot.servers.single;
      expect(server.normalizedUserAgent, 'WanUA/2');
      for (final line in server.lines) {
        expect(line.toJson().containsKey('userAgent'), isFalse);
      }
      // Re-saving drops the legacy per-line UA keys entirely.
      await FileServerListStore(file).save(snapshot);
      final reloaded = await FileServerListStore(file).load();
      expect(reloaded.servers.single.normalizedUserAgent, 'WanUA/2');
      final raw = jsonDecode(await file.readAsString());
      final rawLines = (raw as Map)['servers'] as List;
      for (final line in (rawLines.single as Map)['lines'] as List) {
        expect((line as Map).containsKey('userAgent'), isFalse);
      }
    },
  );

  test(
    'legacy per-line User-Agent without activeLineId falls back to first',
    () async {
      final dir = await Directory.systemTemp.createTemp('rillight-servers');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/servers.json');
      await file.writeAsString(
        jsonEncode({
          'servers': [
            {
              'id': 'server-id-1',
              'name': '灯川测试',
              'username': 'alice',
              'lines': [
                {
                  'id': 'line-a',
                  'address': 'http://lan.test:8096',
                  'userAgent': 'LanUA/1',
                },
                {'id': 'line-b', 'address': 'https://wan.test'},
              ],
            },
          ],
        }),
      );

      final snapshot = await FileServerListStore(file).load();
      expect(snapshot.servers.single.normalizedUserAgent, 'LanUA/1');
    },
  );
}
