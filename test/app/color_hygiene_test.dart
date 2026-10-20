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

/// `Color` 后允许跨空白与换行再跟 `0x` 十六进制(6 位 RGB 或 8 位 ARGB)。
///
/// 按整份文件内容匹配而不是逐行匹配:dart format 会把超长调用拆成
/// `const Color(` + 换行 + `0xff000000,` + 换行 + `)`,逐行扫描会整段漏掉。
final RegExp _rawColorPattern = RegExp(
  r'Color\s*\(\s*0x(?:[0-9a-fA-F]{8}|[0-9a-fA-F]{6})\b',
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

void main() {
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
  });
}
