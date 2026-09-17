import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/player/player_host_command.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('rillight-open-item-');
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  test('write then consume returns the item id once', () async {
    expect(await PlayerHostOpenItem.consume(directory: root), isNull);
    await PlayerHostOpenItem.write('series-friends', directory: root);
    final first = await PlayerHostOpenItem.consume(directory: root);
    expect(first?.itemId, 'series-friends');
    expect(first?.seasonId, isNull);
    expect(await PlayerHostOpenItem.consume(directory: root), isNull);
  });

  test('write then consume keeps the season id', () async {
    await PlayerHostOpenItem.write(
      'series-friends',
      seasonId: 'season-friends-2',
      directory: root,
    );
    final command = await PlayerHostOpenItem.consume(directory: root);
    expect(command?.itemId, 'series-friends');
    expect(command?.seasonId, 'season-friends-2');
  });

  test('stale command files are discarded', () async {
    await PlayerHostOpenItem.write('series-old', directory: root);
    await PlayerHostOpenItem.file(
      directory: root,
    ).setLastModified(DateTime.now().subtract(const Duration(minutes: 1)));
    expect(await PlayerHostOpenItem.consume(directory: root), isNull);
  });
}
