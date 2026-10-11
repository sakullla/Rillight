import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 会话内导入的字幕来源格式。仅接受严格校验通过的文本字幕。
enum SubtitleFileFormat { srt, ass, ssa, vtt }

extension SubtitleFileFormatName on SubtitleFileFormat {
  String get extension => switch (this) {
    SubtitleFileFormat.srt => 'srt',
    SubtitleFileFormat.ass => 'ass',
    SubtitleFileFormat.ssa => 'ssa',
    SubtitleFileFormat.vtt => 'vtt',
  };
}

/// 导入结果。失败类别不新增候选、不替换当前字幕。
enum SubtitleImportOutcome {
  added,
  duplicate,
  cancelled,
  pickerUnavailable,
  unreadable,
  tooLarge,
  sessionLimit,
  invalidFormat,
}

/// 单个字幕文件的上限:普通整季外挂字幕远小于此值。
const int kMaxSubtitleFileBytes = 8 * 1024 * 1024;

/// 同一播放会话内全部导入文件的总上限。
const int kMaxSessionSubtitleBytes = 32 * 1024 * 1024;

const Set<String> kSubtitleImportExtensions = {'srt', 'ass', 'ssa', 'vtt'};

/// 会话内导入的字幕候选:文件已复制进受控 IO 的临时目录,
/// 原始字节(含换行)原样保留,只有解析时才剥离 BOM。
class SessionSubtitleFile {
  const SessionSubtitleFile({
    required this.id,
    required this.label,
    required this.format,
    required this.file,
    required this.sizeBytes,
  });

  final String id;
  final String label;
  final SubtitleFileFormat format;
  final File file;
  final int sizeBytes;
}

/// 按扩展名识别格式;扩展名未知或不在支持列表时返回 null,
/// 由内容嗅探兜底。
SubtitleFileFormat? subtitleFormatForFileName(String fileName) {
  final dot = fileName.lastIndexOf('.');
  if (dot < 0 || dot == fileName.length - 1) return null;
  return subtitleFormatForExtension(fileName.substring(dot + 1));
}

SubtitleFileFormat? subtitleFormatForExtension(String extension) {
  if (extension.length != 3) return null;
  return switch (extension.toLowerCase()) {
    'srt' => SubtitleFileFormat.srt,
    'ass' => SubtitleFileFormat.ass,
    'ssa' => SubtitleFileFormat.ssa,
    'vtt' => SubtitleFileFormat.vtt,
    _ => null,
  };
}

/// 严格校验:UTF-8(可带 BOM)完整解码 + 按格式嗅探内容。
/// 返回识别到的格式;不能确认是受支持的字幕文本时返回 null。
/// 抛出 [FormatException] 表示字节不是有效 UTF-8。
({SubtitleFileFormat format, int textLength}) validateSubtitleContent(
  Uint8List bytes, {
  SubtitleFileFormat? hint,
}) {
  var start = 0;
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    start = 3;
  }
  final text = utf8.decode(
    bytes.sublist(start),
    allowMalformed: false,
  ); // throws FormatException
  if (text.trim().isEmpty) throw const FormatException('empty subtitle');
  final lower = text.trimLeft().toLowerCase();
  if (lower.startsWith('<!doctype') ||
      lower.startsWith('<html') ||
      lower.startsWith('{')) {
    throw const FormatException('not a subtitle document');
  }
  final detected =
      hint ??
      _sniff(text) ??
      (throw const FormatException('unrecognized subtitle format'));
  if (!_contentMatches(detected, text)) {
    throw const FormatException('content does not match the format');
  }
  return (format: detected, textLength: text.length);
}

SubtitleFileFormat? _sniff(String text) {
  final trimmed = text.trimLeft();
  if (trimmed.startsWith('WEBVTT') || trimmed.startsWith('﻿WEBVTT')) {
    return SubtitleFileFormat.vtt;
  }
  if (trimmed.startsWith('[')) {
    for (final marker in const ['[Script Info]', '[V4+ Styles]', '[Events]']) {
      if (trimmed.startsWith(marker)) return SubtitleFileFormat.ass;
    }
    if (trimmed.startsWith('[V4 Styles]')) return SubtitleFileFormat.ssa;
    return null;
  }
  final firstLine = trimmed.split(RegExp(r'\r?\n')).first.trim();
  if (int.tryParse(firstLine) != null && text.contains(' --> ')) {
    return SubtitleFileFormat.srt;
  }
  return null;
}

bool _contentMatches(SubtitleFileFormat format, String text) {
  switch (format) {
    case SubtitleFileFormat.vtt:
      return text.trimLeft().startsWith('WEBVTT');
    case SubtitleFileFormat.ass:
      return text.contains('[Script Info]') ||
          text.contains('[V4+ Styles]') ||
          text.contains('[Events]');
    case SubtitleFileFormat.ssa:
      return text.contains('[Script Info]') ||
          text.contains('[V4 Styles]') ||
          text.contains('[Events]');
    case SubtitleFileFormat.srt:
      final firstLine = text.trimLeft().split(RegExp(r'\r?\n')).first.trim();
      return int.tryParse(firstLine) != null && text.contains(' --> ');
  }
}

int _contentDigest(Uint8List bytes) {
  // 去重只需碰撞概率低,不需要密码学强度;FNV-1a 64 位足够。
  var hash = 0xcbf29ce484222325;
  for (final byte in bytes) {
    hash ^= byte;
    hash = (hash * 0x100000001b3) & 0x7FFFFFFFFFFFFFFF;
  }
  return hash;
}

String _safeLabel(String fileName) {
  final name = fileName.replaceAll(RegExp(r'[\\/]'), ' ').trim();
  return name.isEmpty ? 'subtitle' : name;
}

/// 会话级导入文件集合:负责严格校验、大小/总量上限、按内容去重和
/// 受控临时目录内的会话复制。宿主在会话结束时删除目录。
class SessionSubtitleStore {
  SessionSubtitleStore({
    this.maxFileBytes = kMaxSubtitleFileBytes,
    this.maxTotalBytes = kMaxSessionSubtitleBytes,
  });

  final int maxFileBytes;
  final int maxTotalBytes;

  final Map<String, SessionSubtitleFile> _files = {};
  final Map<int, String> _byDigest = {};
  Directory? _directory;
  int _sequence = 0;

  List<SessionSubtitleFile> get files => List.unmodifiable(
    _files.values.toList()..sort((a, b) => a.id.compareTo(b.id)),
  );

  SessionSubtitleFile? byId(String id) => _files[id];

  int get totalBytes =>
      _files.values.fold(0, (sum, file) => sum + file.sizeBytes);

  /// 目录由调用方([PlayerController])的生命周期管理;同一个缓存目录
  /// 在多次导入间复用。
  Future<void> bindDirectory(Directory directory) async {
    final existing = _directory;
    _directory = directory;
    if (existing == null || existing.path == directory.path) return;
    await clear();
  }

  /// 校验并复制 [bytes]。取消不是错误,由调用方在读取前处理。
  /// 返回 null 表示没有新增(重复或失败原因见 [outcome])。
  Future<({SubtitleImportOutcome outcome, SessionSubtitleFile? file})> add({
    required String fileName,
    required Uint8List bytes,
    Future<Directory> Function()? createDirectory,
  }) async {
    if (bytes.isEmpty) {
      return (outcome: SubtitleImportOutcome.invalidFormat, file: null);
    }
    if (bytes.length > maxFileBytes) {
      return (outcome: SubtitleImportOutcome.tooLarge, file: null);
    }
    final digest = _contentDigest(bytes);
    final existingId = _byDigest[digest];
    if (existingId != null && _files.containsKey(existingId)) {
      return (
        outcome: SubtitleImportOutcome.duplicate,
        file: _files[existingId],
      );
    }
    final SubtitleFileFormat format;
    ({SubtitleFileFormat format, int textLength}) validated;
    try {
      validated = validateSubtitleContent(
        bytes,
        hint: subtitleFormatForFileName(fileName),
      );
      format = validated.format;
    } on FormatException {
      return (outcome: SubtitleImportOutcome.invalidFormat, file: null);
    }
    if (totalBytes + bytes.length > maxTotalBytes) {
      return (outcome: SubtitleImportOutcome.sessionLimit, file: null);
    }
    var directory = _directory;
    if (directory == null) {
      if (createDirectory == null) {
        return (outcome: SubtitleImportOutcome.unreadable, file: null);
      }
      directory = await createDirectory();
      _directory = directory;
    }
    final id = 'import-${++_sequence}';
    final safeName = _safeLabel(
      fileName,
    ).replaceAll(RegExp(r'[^0-9A-Za-z._ -]'), '_');
    final target = File(
      '${directory.path}${Platform.pathSeparator}'
      '$id-${safeName.isEmpty ? 'subtitle' : safeName}'
      '.${format.extension}',
    );
    try {
      await target.writeAsBytes(bytes, flush: true);
    } on FileSystemException {
      return (outcome: SubtitleImportOutcome.unreadable, file: null);
    }
    final file = SessionSubtitleFile(
      id: id,
      label: _safeLabel(fileName),
      format: format,
      file: target,
      sizeBytes: bytes.length,
    );
    _files[id] = file;
    _byDigest[digest] = id;
    return (outcome: SubtitleImportOutcome.added, file: file);
  }

  /// 清空集合并删除会话副本;目录本身归调用方所有。
  Future<void> clear() async {
    final removed = _files.values.toList();
    _files.clear();
    _byDigest.clear();
    _sequence = 0;
    for (final file in removed) {
      try {
        if (await file.file.exists()) await file.file.delete();
      } catch (_) {
        // 会话临时目录随后整体删除;单个残留不阻塞清理。
      }
    }
  }
}
