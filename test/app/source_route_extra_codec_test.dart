import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/source_route_extra_codec.dart';
import 'package:rillight/aggregation/identity/media_identity.dart';
import 'package:rillight/player/player_host_command.dart';
import 'package:rillight/player/player_window_host.dart';

void main() {
  const codec = SourceRouteExtraCodec();
  const source = SourceReference(
    account: SourceAccount(
      region: AccessRegion.private,
      configuredServerId: 'configured-b',
      verifiedServerId: 'verified-b',
      userId: 'user-b',
    ),
    itemId: 'episode-b',
    mediaSourceId: 'version-b',
  );
  Object? roundTrip(Object? value) =>
      codec.decode(jsonDecode(jsonEncode(codec.encode(value))));

  test(
    'detail refresh preserves complete provenance but invents no permit',
    () {
      final restored =
          roundTrip(
                const PlayerHostOpenItemCommand(
                  itemId: 'episode-b',
                  seasonId: 'season-b',
                  source: source,
                  libraryId: 'library-b',
                  regionGeneration: 17,
                ),
              )
              as PlayerHostOpenItemCommand;
      expect(restored.source, source);
      expect(restored.itemId, 'episode-b');
      expect(restored.seasonId, 'season-b');
      expect(restored.libraryId, 'library-b');
      expect(restored.regionGeneration, 17);
    },
  );

  test(
    'player refresh preserves concrete version timeline intent and tracks',
    () {
      final restored =
          roundTrip(
                PlayerOpenRequest(
                  itemId: 'episode-b',
                  source: source,
                  work: source.item,
                  libraryId: 'library-b',
                  regionGeneration: 17,
                  autoResume: false,
                  mediaSourceId: 'version-b',
                  audioStreamIndex: 4,
                  subtitleStreamIndex: 7,
                  startTimeTicks: 123456789,
                  startPaused: true,
                  subtitleOff: true,
                  maxStreamingBitrate: 12000000,
                ),
              )
              as PlayerOpenRequest;
      expect(restored.source, source);
      expect(restored.work, source.item);
      expect(restored.libraryId, 'library-b');
      expect(restored.regionGeneration, 17);
      expect(restored.autoResume, isFalse);
      expect(restored.mediaSourceId, 'version-b');
      expect(restored.audioStreamIndex, 4);
      expect(restored.subtitleStreamIndex, 7);
      expect(restored.startTimeTicks, 123456789);
      expect(restored.startPaused, isTrue);
      expect(restored.subtitleOff, isTrue);
      expect(restored.maxStreamingBitrate, 12000000);
    },
  );

  test('legacy extras gain no source and unknown versions fail closed', () {
    final legacy =
        roundTrip(const PlayerOpenRequest(itemId: 'legacy'))
            as PlayerOpenRequest;
    expect(legacy.source, isNull);
    expect(legacy.libraryId, isNull);
    expect(legacy.regionGeneration, isNull);
    expect(roundTrip({'filter': true}), {'filter': true});
    expect(roundTrip(Object()), isNull);
    expect(
      () => codec.decode({'rillightRouteExtra': 'v999'}),
      throwsFormatException,
    );
  });
}
