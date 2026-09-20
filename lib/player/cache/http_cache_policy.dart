import 'dart:io';

/// Inclusive byte interval. Invalid/unsupported Range syntax is passed upstream.
class MediaByteRange {
  const MediaByteRange(this.start, this.end);
  final int start;
  final int end;
  int get length => end - start + 1;

  static MediaByteRange? resolve(String? value, int length) {
    if (length <= 0) return null;
    if (value == null) return MediaByteRange(0, length - 1);
    final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(value);
    if (match == null || (match[1]!.isEmpty && match[2]!.isEmpty)) {
      return null;
    }
    final first = int.tryParse(match[1]!);
    final last = int.tryParse(match[2]!);
    if (first == null) {
      if (last == null || last <= 0) return null;
      return MediaByteRange((length - last).clamp(0, length), length - 1);
    }
    if (first >= length || (last != null && last < first)) return null;
    return MediaByteRange(first, (last ?? length - 1).clamp(0, length - 1));
  }

  static bool beyondEnd(String? value, int length) {
    final match = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(value ?? '');
    if (match == null) return false;
    final first = int.tryParse(match[1]!);
    final last = int.tryParse(match[2]!);
    return first != null && first >= length && (last == null || last >= first);
  }
}

class MediaContentRange {
  const MediaContentRange(this.start, this.end, this.total);
  final int start;
  final int end;
  final int total;

  static MediaContentRange? parse(String? value) {
    final match = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$').firstMatch(value ?? '');
    if (match == null) return null;
    final start = int.tryParse(match[1]!);
    final end = int.tryParse(match[2]!);
    final total = int.tryParse(match[3]!);
    if (start == null ||
        end == null ||
        total == null ||
        start > end ||
        end >= total) {
      return null;
    }
    return MediaContentRange(start, end, total);
  }
}

/// Private session cache: request headers are fixed per origin, never persisted.
class MediaCachePolicy {
  MediaCachePolicy(HttpHeaders headers, {DateTime? now}) {
    final current = now ?? DateTime.now();
    final control = headers.value('cache-control')?.toLowerCase() ?? '';
    final directives = control.split(',').map((s) => s.trim()).toList();
    final vary = headers.value('vary')?.toLowerCase().split(',') ?? [];
    // Unknown Vary fields are bypassed, including conditional/range fields.
    const fixedHeaders = {
      'accept-encoding',
      'user-agent',
      'authorization',
      'x-emby-token',
      'host',
    };
    storable =
        !directives.contains('no-store') &&
        vary.every((name) => fixedHeaders.contains(name.trim())) &&
        (headers.value('content-encoding') ?? 'identity').toLowerCase() ==
            'identity';
    final etagValue = headers.value('etag');
    etag = etagValue != null && etagValue.length <= 1024 ? etagValue : null;
    strongEtag = etag != null && RegExp(r'^"[^"\r\n]*"$').hasMatch(etag!)
        ? etag
        : null;
    final modified = headers.value('last-modified');
    lastModified = modified != null && modified.length <= 1024
        ? modified
        : null;
    final age = int.tryParse(headers.value('age') ?? '') ?? 0;
    DateTime? date;
    try {
      date = HttpDate.parse(headers.value('date') ?? '');
    } catch (_) {}
    final apparentAge = date == null
        ? 0
        : current.difference(date).inSeconds.clamp(0, 1 << 31);
    final lifetimeMatch = RegExp(
      r'(?:^|,)\s*max-age\s*=\s*"?(\d+)',
    ).firstMatch(control);
    var lifetime = int.tryParse(lifetimeMatch?[1] ?? '') ?? 0;
    if (lifetimeMatch == null) {
      try {
        lifetime = HttpDate.parse(
          headers.value('expires') ?? '',
        ).difference(date ?? current).inSeconds;
      } catch (_) {}
    }
    if (directives.any((d) => d == 'no-cache' || d.startsWith('no-cache='))) {
      lifetime = 0;
    }
    final remaining = lifetime - (age > apparentAge ? age : apparentAge);
    freshUntil = current.add(Duration(seconds: remaining.clamp(0, 1 << 31)));
  }

  late final bool storable;
  late final String? etag;
  late final String? strongEtag;
  late final String? lastModified;
  late final DateTime freshUntil;
  bool get fresh => DateTime.now().isBefore(freshUntil);
}
