import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 原始十六进制颜色只允许出现在这些文件里:
/// 调色板/品牌/token 定义、第三方元数据标记与弹幕预设。
///
/// 页面与共享控件必须改用 AppInk、AppScrim、AppBrand 等 token,
/// 逐页手写色值会让动态取色与明暗对比度失去统一出口。
const Set<String> rawColorAllowlist = {
  'lib/app/theme/palette.dart',
  'lib/app/theme/brand.dart',
  'lib/app/theme/tokens.dart',
  'lib/library/provider_marks.dart',
  'lib/player/danmaku/danmaku_display_form.dart',
};

/// 旧粉/青/紫品牌的色值(6 位 RGB,不含 alpha)。
///
/// 品牌已换成单强调色,这些值在 lib 下任何文件里都不能再出现,
/// 包括 [rawColorAllowlist] 里的调色板与品牌定义,避免新旧两套品牌并存。
const Set<String> retiredBrandHexes = {
  // AppBrand 旧常量:粉、深粉、青、深青、紫、深紫、三个 on 色、底色与纸色。
  'FF7FA8', 'B21F54', '6FD6F2', '0A6178', 'C8B8FF', '5B4BC4',
  '3A1124', '062A33', '221448', '0D0A12', 'FAF2F7',
  // HEAD ddc8b375 的 palette.dart 专有表面与容器值(error 组沿用,不在此列)。
  '083344', '123A47', '141019', '141216', '160E18', '161218', '1A1421',
  '211A2A', '24185C', '2A2234', '342B3B', '382A3E', '3C3464', '46384D',
  '4F2440', '53464F', '5C1E3A', '6E6570', '9A8C9A', 'A33D6C', 'C9F2FF',
  'CDBFCB', 'D6F0F7', 'E8E4FF', 'EAD3DE', 'EADCE3', 'ECE8FF', 'EFE3EA',
  'F2A8C8', 'F5DFE9', 'F5EAF0', 'F7F2F5', 'F7F2F6', 'FADDE9', 'FFD9E8',
  // 已删除的 AppBrand.libraryGradients。
  '5A2346', '1C0D17', '3F2F6B', '141022', '14504A', '0A1C1A', '5C2A3A',
  '1C0F16', '2F3F6B', '101522', '3A2A5A', '14101E', '1E3D5A', '0C1520',
  '3A3F4A', '14161A',
};

/// `0x` 后可带 2 位 alpha(`0xFF`/`0x80` 等),或 `#` 前缀,再跟一个旧品牌值。
final RegExp _retiredBrandPattern = RegExp(
  '(?:0[xX](?:[0-9a-fA-F]{2})?|#)(${retiredBrandHexes.join('|')})'
  '(?![0-9a-fA-F])',
  caseSensitive: false,
);

/// 文件内容里所有旧品牌色值的 `path:line: text` 描述。
List<String> retiredBrandViolations(String path, String contents) {
  return [
    for (final match in _retiredBrandPattern.allMatches(contents))
      '$path:${lineOfOffset(contents, match.start)}: '
          '${lineAtOffset(contents, match.start)}',
  ];
}

/// `Color` 后允许跨空白与换行再跟 `0x`/`0X` 十六进制(6 位 RGB 或 8 位 ARGB)。
///
/// 按整份文件内容匹配而不是逐行匹配:dart format 会把超长调用拆成
/// `const Color(` + 换行 + `0xff000000,` + 换行 + `)`,逐行扫描会整段漏掉。
final RegExp _rawColorPattern = RegExp(
  r'Color\s*\(\s*0[xX](?:[0-9a-fA-F]{8}|[0-9a-fA-F]{6})\b',
);

/// 字符偏移对应的 1 基行号。
int lineOfOffset(String text, int offset) {
  var line = 1;
  final limit = offset < text.length ? offset : text.length;
  for (var index = 0; index < limit; index++) {
    if (text.codeUnitAt(index) == 0x0A) line++;
  }
  return line;
}

/// 字符偏移所在行的去空白文本,用于失败输出定位。
String lineAtOffset(String text, int offset) {
  final start = offset < 1 ? 0 : text.lastIndexOf('\n', offset - 1) + 1;
  final end = text.indexOf('\n', offset);
  return text.substring(start, end < 0 ? text.length : end).trim();
}

/// 文件内容里所有原始十六进制颜色的 `path:line: text` 描述。
List<String> rawColorViolations(String path, String contents) {
  return [
    for (final match in _rawColorPattern.allMatches(contents))
      '$path:${lineOfOffset(contents, match.start)}: '
          '${lineAtOffset(contents, match.start)}',
  ];
}

String _relative(File file) =>
    file.path.replaceAll(Platform.pathSeparator, '/');

/// 相对仓库根目录的 lib 源码,按路径排序,便于稳定复现失败输出。
List<File> _libSources() {
  final directory = Directory('lib');
  expect(
    directory.existsSync(),
    isTrue,
    reason: '颜色卫生检查需要从仓库根目录运行 flutter test',
  );
  return directory
      .listSync(recursive: true)
      .whereType<File>()
      .where((file) => file.path.endsWith('.dart'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
}

/// lib 下全部文本文件(含白名单与 ARB),按路径排序。
List<File> _libFiles() {
  final directory = Directory('lib');
  expect(directory.existsSync(), isTrue);
  return directory.listSync(recursive: true).whereType<File>().toList()
    ..sort((a, b) => a.path.compareTo(b.path));
}

void main() {
  test('lib 内任何文件(包括白名单)都不再出现旧粉/青/紫品牌色值', () {
    final violations = <String>[];
    for (final file in _libFiles()) {
      final contents = utf8.decode(
        file.readAsBytesSync(),
        allowMalformed: true,
      );
      violations.addAll(retiredBrandViolations(_relative(file), contents));
    }
    final separator = Platform.lineTerminator;
    expect(
      violations,
      isEmpty,
      reason:
          '旧品牌色值仍在使用,请改用 AppBrand.accent 系或新的 Tones:'
          '$separator${violations.join(separator)}',
    );
  });

  test('旧品牌值扫描识别 ARGB、# 前缀与大小写,不误报更长的十六进制', () {
    expect(
      retiredBrandViolations('lib/a.dart', 'const c = Color(0xFFFF7FA8);'),
      hasLength(1),
    );
    expect(
      retiredBrandViolations('lib/b.dart', 'const c = Color(0x80ff7fa8);'),
      hasLength(1),
    );
    expect(
      retiredBrandViolations('lib/c.dart', '/// 旧粉 #FF7FA8 已退役'),
      hasLength(1),
    );
    expect(
      retiredBrandViolations('lib/d.dart', 'const c = Color(0xFF82ADFF);'),
      isEmpty,
    );
    expect(
      retiredBrandViolations('lib/e.dart', 'const id = 0xFF7FA8FF00;'),
      isEmpty,
    );
  });

  test('白名单文件仍然存在', () {
    for (final path in rawColorAllowlist) {
      expect(
        File(path).existsSync(),
        isTrue,
        reason: '$path 已不存在,请同步更新 rawColorAllowlist',
      );
    }
  });

  test('lib 内除白名单外不再出现原始十六进制颜色', () {
    final violations = <String>[];
    for (final file in _libSources()) {
      final path = _relative(file);
      if (rawColorAllowlist.contains(path)) continue;
      violations.addAll(rawColorViolations(path, file.readAsStringSync()));
    }

    final separator = Platform.lineTerminator;
    final detail = violations.join(separator);
    expect(
      violations,
      isEmpty,
      reason:
          '发现调色板外的原始颜色,请改用 AppInk / AppScrim / AppBrand token:'
          '$separator$detail',
    );
  });

  test('跨行 Color 字面量同样会被扫描到(回归夹具)', () {
    // 三引号字符串开头的换行会被 Dart 吃掉,所以从第一行直接起文。
    const fixture = '''class Fake {
  static const color = Color(
    0xff000000,
  );
}
''';
    final violations = rawColorViolations('lib/fake.dart', fixture);
    expect(violations, hasLength(1));
    expect(
      violations.single,
      startsWith('lib/fake.dart:2: '),
      reason: '行号必须由字符偏移换算,指向 Color( 起始行',
    );
  });

  test('token 与 8 位 ARGB 同样被识别,普通代码不会误报', () {
    expect(
      rawColorViolations(
        'lib/a.dart',
        'const c = AppInk.black;\ncolor: AppScrim.scrim(.5),',
      ),
      isEmpty,
    );
    expect(
      rawColorViolations('lib/b.dart', 'const c = Color ( 0x80FF7FA8 );'),
      hasLength(1),
    );
    expect(
      rawColorViolations('lib/c.dart', 'const c = Color(0XFF7FA8);'),
      hasLength(1),
      reason: 'Dart 允许大写 0X 前缀,扫描不能漏掉',
    );
  });
}
