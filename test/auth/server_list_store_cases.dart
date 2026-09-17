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

  test('lines and User-Agent round-trip through the file store', () async {
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
            lines: [
              ServerLine(id: 'line-a', address: 'http://lan.test:8096'),
              ServerLine(
                id: 'line-b',
                address: 'https://wan.test',
                userAgent: 'LineB/1',
              ),
            ],
          ),
        ],
      ),
    );

    final snapshot = await FileServerListStore(file).load();
    final server = snapshot.servers.single;
    expect(server.lines, hasLength(2));
    expect(server.baseUrl, 'https://wan.test');
    expect(server.activeLine?.userAgent, 'LineB/1');
  });
}
