import 'dart:convert';

import '../aggregation/history/history_models.dart';
import '../player/player_host_command.dart';
import '../player/player_window_host.dart';

/// Preserve source provenance when GoRouter refreshes an imperative stack.
/// Encoding is not authorization: every restored route still requires its
/// registry permit, library membership and (for private routes) generation.
class SourceRouteExtraCodec extends Codec<Object?, Object?> {
  const SourceRouteExtraCodec();
  @override
  Converter<Object?, Object?> get encoder => const _Encode();
  @override
  Converter<Object?, Object?> get decoder => const _Decode();
}

class _Encode extends Converter<Object?, Object?> {
  const _Encode();
  @override
  Object? convert(Object? input) {
    if (input is PlayerHostOpenItemCommand) {
      return {
        'rillightRouteExtra': 'detail-v1',
        'itemId': input.itemId,
        'seasonId': input.seasonId,
        'source': input.source == null ? null : encodeSource(input.source!),
        'libraryId': input.libraryId,
        'regionGeneration': input.regionGeneration,
      };
    }
    if (input is PlayerOpenRequest) {
      return {
        'rillightRouteExtra': 'player-v1',
        'itemId': input.itemId,
        'source': input.source == null ? null : encodeSource(input.source!),
        'work': input.work == null ? null : encodeSource(input.work!),
        'libraryId': input.libraryId,
        'regionGeneration': input.regionGeneration,
        'autoResume': input.autoResume,
        'mediaSourceId': input.mediaSourceId,
        'audioStreamIndex': input.audioStreamIndex,
        'subtitleStreamIndex': input.subtitleStreamIndex,
        'startTimeTicks': input.startTimeTicks,
        'startPaused': input.startPaused,
        'subtitleOff': input.subtitleOff,
        'maxStreamingBitrate': input.maxStreamingBitrate,
      };
    }
    // Retain the router's existing JSON-compatible extras only.
    try {
      return jsonDecode(jsonEncode(input));
    } on JsonUnsupportedObjectError {
      return null;
    }
  }
}

class _Decode extends Converter<Object?, Object?> {
  const _Decode();
  @override
  Object? convert(Object? input) {
    if (input is! Map || !input.containsKey('rillightRouteExtra')) return input;
    final value = Map<String, dynamic>.from(input);
    final source = value['source'] == null
        ? null
        : decodeSource(Map<String, dynamic>.from(value['source'] as Map));
    switch (value['rillightRouteExtra']) {
      case 'detail-v1':
        return PlayerHostOpenItemCommand(
          itemId: value['itemId'] as String,
          seasonId: value['seasonId'] as String?,
          source: source,
          libraryId: value['libraryId'] as String?,
          regionGeneration: value['regionGeneration'] as int?,
        );
      case 'player-v1':
        return PlayerOpenRequest(
          itemId: value['itemId'] as String,
          source: source,
          work: value['work'] == null
              ? null
              : decodeSource(Map<String, dynamic>.from(value['work'] as Map)),
          libraryId: value['libraryId'] as String?,
          regionGeneration: value['regionGeneration'] as int?,
          autoResume: value['autoResume'] as bool,
          mediaSourceId: value['mediaSourceId'] as String?,
          audioStreamIndex: value['audioStreamIndex'] as int?,
          subtitleStreamIndex: value['subtitleStreamIndex'] as int?,
          startTimeTicks: value['startTimeTicks'] as int?,
          startPaused: value['startPaused'] as bool,
          subtitleOff: value['subtitleOff'] as bool,
          maxStreamingBitrate: value['maxStreamingBitrate'] as int?,
        );
      default:
        throw const FormatException('Unknown source route extra version');
    }
  }
}
