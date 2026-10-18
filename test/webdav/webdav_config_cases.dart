import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/webdav/webdav_config.dart';

void main() {
  test('missing file yields empty config', () async {
    final dir = await Directory.systemTemp.createTemp('rillight_webdav_cfg');
    addTearDown(() => dir.delete(recursive: true));
    final store = WebDavConfigStore(File('${dir.path}/webdav.json'));
    final loaded = await store.load();
    expect(loaded.isEmpty, isTrue);
    expect(loaded.address, '');
    expect(loaded.username, '');
    expect(loaded.password, '');
    expect(loaded.directory, '');
  });

  test('save and load roundtrip keeps all fields', () async {
    final dir = await Directory.systemTemp.createTemp('rillight_webdav_cfg');
    addTearDown(() => dir.delete(recursive: true));
    final store = WebDavConfigStore(File('${dir.path}/webdav.json'));
    const config = WebDavConfig(
      address: 'http://192.0.2.10:5005/dav',
      username: 'user',
      password: 'pass',
      directory: 'rillight',
    );
    await store.save(config);
    final loaded = await store.load();
    expect(loaded.address, config.address);
    expect(loaded.username, config.username);
    expect(loaded.password, config.password);
    expect(loaded.directory, config.directory);
    expect(loaded.isEmpty, isFalse);
  });

  test('atomic save leaves no temporary file behind', () async {
    final dir = await Directory.systemTemp.createTemp('rillight_webdav_cfg');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/webdav.json');
    final store = WebDavConfigStore(file);
    await store.save(const WebDavConfig(address: 'http://192.0.2.10/dav'));
    expect(file.existsSync(), isTrue);
    expect(File('${file.path}.tmp').existsSync(), isFalse);
    final normalized = file.path.replaceAll('\\', '/');
    expect(dir.listSync().map((e) => e.path.replaceAll('\\', '/')), [
      normalized,
    ]);
  });
}
