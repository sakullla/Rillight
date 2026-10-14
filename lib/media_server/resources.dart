import 'dart:async';
import 'dart:typed_data';

import 'capabilities.dart';

/// Credentials are evaluated anew for every redirect, manifest and subtitle.
class ResourceAuthorization {
  ResourceAuthorization({
    required Map<String, Map<String, String>> headersByOrigin,
    Map<String, String> publicHeaders = const {},
  }) : publicHeaders = Map.unmodifiable(publicHeaders),
       headersByOrigin = Map.unmodifiable({
         for (final e in headersByOrigin.entries)
           e.key: Map<String, String>.unmodifiable(e.value),
       });
  final Map<String, Map<String, String>> headersByOrigin;
  final Map<String, String> publicHeaders;
  Map<String, String> headersFor(Uri target) => {
    ...publicHeaders,
    ...?headersByOrigin[target.origin],
  };

  /// Remove copied service credentials on each hop without rebuilding signed
  /// query parameters. A different authorized origin only receives its own
  /// credentials, never another origin's token.
  Uri sanitizeUri(Uri target) {
    final permitted = _credentialValues(headersByOrigin[target.origin]);
    final foreign = <String>{
      for (final entry in headersByOrigin.entries)
        if (entry.key != target.origin) ..._credentialValues(entry.value),
    }..removeAll(permitted);
    if (!target.hasQuery || foreign.isEmpty) return target;
    final parts = target.query.split('&');
    final kept = parts.where((part) {
      final decoded = Uri.decodeQueryComponent(part);
      return !foreign.any(decoded.contains);
    }).toList();
    if (kept.length == parts.length) return target;
    return target.replace(query: kept.join('&'));
  }

  static Set<String> _credentialValues(Map<String, String>? headers) {
    final values = <String>{};
    for (final entry in (headers ?? const <String, String>{}).entries) {
      final name = entry.key.toLowerCase();
      if (entry.value.isEmpty ||
          !(name.contains('token') ||
              name.contains('authorization') ||
              name == 'cookie' ||
              name == 'api-key' ||
              name == 'x-api-key')) {
        continue;
      }
      values.add(entry.value);
      if (name == 'authorization' || name == 'x-emby-authorization') {
        final bearer = RegExp(
          r'^Bearer\s+(.+)$',
          caseSensitive: false,
        ).firstMatch(entry.value);
        if (bearer != null) values.add(bearer.group(1)!);
        for (final match in RegExp(
          r'(?:^|[,\s])Token\s*=\s*"([^"]+)"',
          caseSensitive: false,
        ).allMatches(entry.value)) {
          values.add(match.group(1)!);
        }
      }
    }
    return values;
  }
}

class AuthorizedMediaResource {
  const AuthorizedMediaResource({
    required this.url,
    required this.authorization,
  });

  /// Keep signed URL bytes; adapters must not rebuild its query parameters.
  final String url;
  final ResourceAuthorization authorization;
}

class MediaPart {
  const MediaPart({required this.id, required this.resource, this.duration});
  final String id;
  final AuthorizedMediaResource resource;
  final Duration? duration;
}

class PartPosition {
  const PartPosition(this.index, this.local, this.global);
  final int index;
  final Duration local;
  final Duration global;
}

class MediaTimeline {
  MediaTimeline(List<MediaPart> parts) : parts = List.unmodifiable(parts);
  final List<MediaPart> parts;

  Duration? get duration {
    var total = Duration.zero;
    for (final part in parts) {
      if (part.duration == null) return null;
      total += part.duration!;
    }
    return total;
  }

  /// Unknown preceding duration never invents a global position.
  PartPosition? locate(Duration global) {
    if (global < Duration.zero) return null;
    var offset = Duration.zero;
    for (var i = 0; i < parts.length; i++) {
      final length = parts[i].duration;
      if (global == offset) return PartPosition(i, Duration.zero, global);
      if (length == null || length < Duration.zero) return null;
      if (global < offset + length ||
          (i == parts.length - 1 && global == offset + length)) {
        return PartPosition(i, global - offset, global);
      }
      offset += length;
    }
    return null;
  }
}

/// One owner, coalesced cleanup; failure remains retryable and never says freed.
class PlaybackResourceLease {
  PlaybackResourceLease({
    required this.id,
    this.itemId,
    this.mediaSourceId,
    required this._release,
  });
  final String id;

  /// Concrete remote identity captured when this resource was allocated.
  final String? itemId, mediaSourceId;
  final Future<void> Function() _release;
  Future<void>? _pending;
  bool _released = false;
  bool get isReleased => _released;
  Future<void> release() {
    if (_released) return Future.value();
    return _pending ??= Future.sync(_release)
        .then((_) {
          _released = true;
        })
        .whenComplete(() {
          _pending = null;
        });
  }
}

class PreviewFrame {
  const PreviewFrame({required this.bytes, this.tile});
  final Uint8List bytes;
  final PreviewTile? tile;
}

class PreviewTile {
  const PreviewTile({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });
  final int x, y, width, height;
}

abstract interface class MediaPreview {
  String get itemId;
  CapabilityStatus get availability;
  Future<PreviewFrame?> frameAt(Duration position);
  Future<void> close();
}
