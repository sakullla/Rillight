import 'dart:typed_data';

/// Roku BIF v0 stores timestamp/offset pairs followed by encoded JPEGs.
class BifPreview {
  BifPreview._(this._bytes, this._timesMs, this._offsets);
  final Uint8List _bytes;
  final List<int> _timesMs;
  final List<int> _offsets;

  static BifPreview? parse(Uint8List bytes) {
    const magic = [0x89, 0x42, 0x49, 0x46, 0x0d, 0x0a, 0x1a, 0x0a];
    if (bytes.length < 72) return null;
    for (var i = 0; i < magic.length; i++) {
      if (bytes[i] != magic[i]) return null;
    }
    final data = ByteData.sublistView(bytes);
    if (data.getUint32(8, Endian.little) != 0) return null;
    final count = data.getUint32(12, Endian.little);
    final multiplier = data.getUint32(16, Endian.little);
    final indexEnd = 64 + (count + 1) * 8;
    if (count == 0 || indexEnd > bytes.length) return null;
    final times = <int>[];
    final offsets = <int>[];
    for (var i = 0; i <= count; i++) {
      final time = data.getUint32(64 + i * 8, Endian.little);
      final offset = data.getUint32(68 + i * 8, Endian.little);
      if (offset < indexEnd ||
          offset > bytes.length ||
          (offsets.isNotEmpty && offset <= offsets.last)) {
        return null;
      }
      offsets.add(offset);
      if (i < count) {
        final ms = time * (multiplier == 0 ? 1000 : multiplier);
        if (times.isNotEmpty && ms < times.last) return null;
        times.add(ms);
      } else if (time != 0xffffffff) {
        return null;
      }
    }
    return BifPreview._(bytes, times, offsets);
  }

  Uint8List imageAt(Duration position) {
    var low = 0;
    var high = _timesMs.length;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (_timesMs[mid] <= position.inMilliseconds) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    final index = (low - 1).clamp(0, _timesMs.length - 1);
    return Uint8List.sublistView(_bytes, _offsets[index], _offsets[index + 1]);
  }
}
