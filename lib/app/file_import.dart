import 'package:file_selector/file_selector.dart' as selector;
import 'package:flutter/services.dart';

/// 读取边界:请求最多 [limit] 字节。文件超过该上限时抛出
/// [AppFileTooLargeException],其余读失败抛出 [AppFileReadException]。
/// Android 的 content URI 停在此边界内,不会以原始字符串形式传给播放核心。
typedef AppFileBytesReader = Future<Uint8List> Function(int limit);

class PickedAppFile {
  const PickedAppFile({
    required this.fileName,
    required this.length,
    required this.read,
  });

  final String fileName;
  final int? length;
  final AppFileBytesReader read;

  Future<Uint8List> readBytes(int limit) => read(limit);
}

/// 设备没有可用的文件选择 provider(常见于 Android TV)。
class AppFilePickerUnavailableException implements Exception {
  const AppFilePickerUnavailableException(this.detail);
  final String detail;
  @override
  String toString() => 'File picker unavailable: $detail';
}

/// 文件超过调用方声明的读取上限。
class AppFileTooLargeException implements Exception {
  const AppFileTooLargeException(this.length, this.limit);
  final int length;
  final int limit;
  @override
  String toString() => 'File is $length bytes, limit is $limit';
}

class AppFileReadException implements Exception {
  const AppFileReadException(this.detail);
  final String detail;
  @override
  String toString() => 'File could not be read: $detail';
}

/// 可注入的文件选择边界。字幕导入和后续备份导入 UI 共用;
/// 测试用假实现替换,产品路径使用 [DefaultAppFilePicker]。
abstract class AppFilePicker {
  /// 用户取消时返回 null;设备缺失 provider 时抛出
  /// [AppFilePickerUnavailableException]。
  Future<PickedAppFile?> pickFile({
    required String dialogTitle,
    required List<String> allowedExtensions,
  });
}

class DefaultAppFilePicker implements AppFilePicker {
  const DefaultAppFilePicker();

  @override
  Future<PickedAppFile?> pickFile({
    required String dialogTitle,
    required List<String> allowedExtensions,
  }) async {
    final group = selector.XTypeGroup(
      label: dialogTitle,
      extensions: allowedExtensions,
    );
    selector.XFile? picked;
    try {
      picked = await selector.openFile(acceptedTypeGroups: [group]);
    } on PlatformException catch (error) {
      // Android TV 常见:系统没有 documents provider,选择器无法弹出。
      throw AppFilePickerUnavailableException(error.code);
    }
    if (picked == null) return null;
    final file = picked;
    return PickedAppFile(
      fileName: file.name.isEmpty
          ? (file.path.split(RegExp(r'[\\/]')).last)
          : file.name,
      length: await _lengthOf(file),
      read: (limit) => _readBounded(file, limit),
    );
  }

  static Future<int?> _lengthOf(selector.XFile file) async {
    try {
      return await file.length();
    } catch (_) {
      return null;
    }
  }

  static Future<Uint8List> _readBounded(selector.XFile file, int limit) async {
    final Stream<List<int>> stream;
    try {
      stream = file.openRead(0, limit + 1);
    } catch (error) {
      throw AppFileReadException(error.toString());
    }
    final chunks = <Uint8List>[];
    var total = 0;
    try {
      await for (final chunk in stream) {
        total += chunk.length;
        if (total > limit) {
          throw AppFileTooLargeException(-1, limit);
        }
        chunks.add(chunk is Uint8List ? chunk : Uint8List.fromList(chunk));
      }
    } on AppFileTooLargeException {
      rethrow;
    } catch (error) {
      throw AppFileReadException(error.toString());
    }
    final bytes = Uint8List(total);
    var offset = 0;
    for (final chunk in chunks) {
      bytes.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
    }
    return bytes;
  }
}
