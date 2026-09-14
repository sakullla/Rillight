import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// dandanplay 匹配哈希规范:文件前 16MB 的 MD5。
const int kDanmakuHashHeadBytes = 16 * 1024 * 1024;

/// 纯 Dart MD5(RFC 1321),支持分块喂入,避免整文件落内存。
///
/// 仅用于 dandanplay 匹配指纹(非安全用途),不引入额外依赖。
class Md5Sink {
  int _a = 0x67452301;
  int _b = 0xefcdab89;
  int _c = 0x98badcfe;
  int _d = 0x10325476;

  final Uint8List _buffer = Uint8List(64);
  int _bufferLength = 0;
  int _totalLength = 0;

  void add(List<int> data) {
    var offset = 0;
    _totalLength += data.length;
    if (_bufferLength > 0) {
      final need = 64 - _bufferLength;
      final take = math.min(need, data.length);
      _buffer.setRange(_bufferLength, _bufferLength + take, data);
      _bufferLength += take;
      offset = take;
      if (_bufferLength < 64) {
        return;
      }
      _processBlock(_buffer, 0);
      _bufferLength = 0;
    }
    while (offset + 64 <= data.length) {
      _processBlock(data, offset);
      offset += 64;
    }
    final left = data.length - offset;
    if (left > 0) {
      _buffer.setRange(0, left, data, offset);
      _bufferLength = left;
    }
  }

  String close() {
    final bitLength = _totalLength * 8;
    // 填充:0x80 + 0x00* + 8 字节小端比特长度,凑足 64 字节对齐。
    final padding = Uint8List(64);
    padding[0] = 0x80;
    var padLength = _totalLength % 64 < 56
        ? 56 - _totalLength % 64
        : 120 - _totalLength % 64;
    final tail = Uint8List(8);
    ByteData.view(tail.buffer).setUint64(0, bitLength, Endian.little);
    add(padding.sublist(0, padLength));
    add(tail);
    assert(_bufferLength == 0, 'MD5 填充后必须整块处理');
    return _hex(_a) + _hex(_b) + _hex(_c) + _hex(_d);
  }

  static String _hex(int value) {
    var result = '';
    for (var i = 0; i < 4; i++) {
      final byte = (value >> (8 * i)) & 0xff;
      result += byte.toRadixString(16).padLeft(2, '0');
    }
    return result;
  }

  void _processBlock(List<int> block, int offset) {
    final m = List<int>.filled(16, 0);
    for (var i = 0; i < 16; i++) {
      m[i] =
          block[offset + 4 * i] |
          (block[offset + 4 * i + 1] << 8) |
          (block[offset + 4 * i + 2] << 16) |
          (block[offset + 4 * i + 3] << 24);
    }
    var a = _a;
    var b = _b;
    var c = _c;
    var d = _d;
    for (var i = 0; i < 64; i++) {
      int f;
      int g;
      if (i < 16) {
        f = (b & c) | (~b & d);
        g = i;
      } else if (i < 32) {
        f = (d & b) | (~d & c);
        g = (5 * i + 1) % 16;
      } else if (i < 48) {
        f = b ^ c ^ d;
        g = (3 * i + 5) % 16;
      } else {
        f = c ^ (b | ~d);
        g = (7 * i) % 16;
      }
      final tmp = d;
      d = c;
      c = b;
      final sum = (a + f + _k[i] + m[g]) & 0xffffffff;
      b = (b + _rotl32(sum, _s[i])) & 0xffffffff;
      a = tmp;
    }
    _a = (_a + a) & 0xffffffff;
    _b = (_b + b) & 0xffffffff;
    _c = (_c + c) & 0xffffffff;
    _d = (_d + d) & 0xffffffff;
  }

  static int _rotl32(int value, int shift) {
    return ((value << shift) | (value >> (32 - shift))) & 0xffffffff;
  }

  static const List<int> _s = [
    7,
    12,
    17,
    22,
    7,
    12,
    17,
    22,
    7,
    12,
    17,
    22,
    7,
    12,
    17,
    22,
    5,
    9,
    14,
    20,
    5,
    9,
    14,
    20,
    5,
    9,
    14,
    20,
    5,
    9,
    14,
    20,
    4,
    11,
    16,
    23,
    4,
    11,
    16,
    23,
    4,
    11,
    16,
    23,
    4,
    11,
    16,
    23,
    6,
    10,
    15,
    21,
    6,
    10,
    15,
    21,
    6,
    10,
    15,
    21,
    6,
    10,
    15,
    21,
  ];

  static const List<int> _k = [
    0xd76aa478,
    0xe8c7b756,
    0x242070db,
    0xc1bdceee,
    0xf57c0faf,
    0x4787c62a,
    0xa8304613,
    0xfd469501,
    0x698098d8,
    0x8b44f7af,
    0xffff5bb1,
    0x895cd7be,
    0x6b901122,
    0xfd987193,
    0xa679438e,
    0x49b40821,
    0xf61e2562,
    0xc040b340,
    0x265e5a51,
    0xe9b6c7aa,
    0xd62f105d,
    0x02441453,
    0xd8a1e681,
    0xe7d3fbc8,
    0x21e1cde6,
    0xc33707d6,
    0xf4d50d87,
    0x455a14ed,
    0xa9e3e905,
    0xfcefa3f8,
    0x676f02d9,
    0x8d2a4c8a,
    0xfffa3942,
    0x8771f681,
    0x6d9d6122,
    0xfde5380c,
    0xa4beea44,
    0x4bdecfa9,
    0xf6bb4b60,
    0xbebfbc70,
    0x289b7ec6,
    0xeaa127fa,
    0xd4ef3085,
    0x04881d05,
    0xd9d4d039,
    0xe6db99e5,
    0x1fa27cf8,
    0xc4ac5665,
    0xf4292244,
    0x432aff97,
    0xab9423a7,
    0xfc93a039,
    0x655b59c3,
    0x8f0ccc92,
    0xffeff47d,
    0x85845dd1,
    0x6fa87e4f,
    0xfe2ce6e0,
    0xa3014314,
    0x4e0811a1,
    0xf7537e82,
    0xbd3af235,
    0x2ad7d2bb,
    0xeb86d391,
  ];
}

/// 计算数据流前 [kDanmakuHashHeadBytes] 字节的 MD5(十六进制小写)。
///
/// 超出上限的部分不读取语义由调用方保证;本函数对流内容不做截断,
/// [DanmakuStreamHasher] 负责 16MB 上限。
Future<String> md5OfBytes(Stream<List<int>> bytes) async {
  final sink = Md5Sink();
  await for (final chunk in bytes) {
    sink.add(chunk);
  }
  return sink.close();
}

/// 从直连播放流地址读取前 16MB 并计算 dandanplay 匹配哈希。
///
/// 通过 Range 请求尽量只取前 16MB(服务器忽略 Range 时在流上截断),
/// 任何失败返回 null(哈希不可得时匹配按文件名+时长降级,不打扰播放)。
class DanmakuStreamHasher {
  DanmakuStreamHasher({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 30),
              headers: const {'Accept': '*/*'},
            ),
          );

  final Dio _dio;

  Future<String?> hashOf(Uri streamUrl) async {
    try {
      final response = await _dio.getUri<ResponseBody>(
        streamUrl,
        options: Options(
          responseType: ResponseType.stream,
          headers: {'Range': 'bytes=0-${kDanmakuHashHeadBytes - 1}'},
          validateStatus: (status) => status != null && status < 300,
        ),
      );
      final body = response.data;
      if (body == null) {
        return null;
      }
      var remaining = kDanmakuHashHeadBytes;
      final sink = Md5Sink();
      await for (final chunk in body.stream) {
        if (remaining <= 0) {
          break;
        }
        if (chunk.length > remaining) {
          sink.add(chunk.sublist(0, remaining));
          remaining = 0;
          break;
        }
        sink.add(chunk);
        remaining -= chunk.length;
      }
      return sink.close();
    } catch (_) {
      return null;
    }
  }
}
