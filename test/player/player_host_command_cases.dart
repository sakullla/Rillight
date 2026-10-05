import 'dart:io';
import 'package:rillight/aggregation/identity/media_identity.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/player/player_host_command.dart';
import 'package:rillight/player/player_process_protocol.dart';

void main() {
  late PlayerProcessProtocol protocol;
  setUp(() async => protocol = await PlayerProcessProtocol.create());
  tearDown(() async => protocol.dispose());

  test(
    'process-scoped detail command is consumed exactly once and preserves the season',
    () async {
      await PlayerHostOpenItem.write(
        'series-friends',
        protocol: protocol,
        seasonId: 'season-2',
      );
      final command = await PlayerHostOpenItem.consume(
        protocol: protocol,
        expectedPid: pid,
      );
      expect(command?.itemId, 'series-friends');
      expect(command?.seasonId, 'season-2');
      expect(
        await PlayerHostOpenItem.consume(protocol: protocol, expectedPid: pid),
        isNull,
      );
    },
  );
  test(
    'detail IPC preserves the actual source account, library and generation',
    () async {
      const source = SourceReference(
        account: SourceAccount(
          region: AccessRegion.private,
          configuredServerId: 'b-config',
          verifiedServerId: 'b-verified',
          userId: 'b-user',
        ),
        itemId: 'same-series',
      );
      const command = PlayerHostOpenItemCommand(
        itemId: 'same-series',
        seasonId: 'b-season',
        source: source,
        libraryId: 'b-library',
        regionGeneration: 42,
      );
      await PlayerHostOpenItem.write(
        command.itemId,
        protocol: protocol,
        seasonId: command.seasonId,
        command: command,
      );
      final received = (await PlayerHostOpenItem.consume(
        protocol: protocol,
        expectedPid: pid,
      ))!;
      expect(received.source, source);
      expect(received.libraryId, 'b-library');
      expect(received.regionGeneration, 42);
      expect(received.seasonId, 'b-season');
    },
  );
  test(
    'malformed explicit source command never becomes a legacy naked ID',
    () async {
      await protocol.write('open-item', {
        'itemId': 'same-series',
        'source': {'configuredServerId': 'b'},
      });
      expect(
        await PlayerHostOpenItem.consume(protocol: protocol, expectedPid: pid),
        isNull,
      );
      await protocol.write('open-item', {
        'itemId': 'same-series',
        'libraryId': 'b-library',
        'regionGeneration': 42,
      });
      expect(
        await PlayerHostOpenItem.consume(protocol: protocol, expectedPid: pid),
        isNull,
      );
    },
  );

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
