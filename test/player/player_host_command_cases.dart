import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/player/player_host_command.dart';
import 'package:rillight/player/player_process_protocol.dart';

void main() {
  late PlayerProcessProtocol protocol;
  setUp(() async => protocol = await PlayerProcessProtocol.create());
  tearDown(() async => protocol.dispose());

  test('process-scoped detail command is consumed exactly once', () async {
    await PlayerHostOpenItem.write('series-friends', protocol: protocol);
    final command = await PlayerHostOpenItem.consume(
      protocol: protocol,
      expectedPid: pid,
    );
    expect(command?.itemId, 'series-friends');
    expect(
      await PlayerHostOpenItem.consume(protocol: protocol, expectedPid: pid),
      isNull,
    );
  });
  test('detail command preserves the season', () async {
    await PlayerHostOpenItem.write(
      'series-friends',
      protocol: protocol,
      seasonId: 'season-2',
    );
    expect(
      (await PlayerHostOpenItem.consume(
        protocol: protocol,
        expectedPid: pid,
      ))?.seasonId,
      'season-2',
    );
  });
  test('a detail command from another process is rejected', () async {
    await PlayerHostOpenItem.write('old-item', protocol: protocol);
    expect(
      await PlayerHostOpenItem.consume(
        protocol: protocol,
        expectedPid: pid + 1,
      ),
      isNull,
    );
  });
}
