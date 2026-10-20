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

const String _marker = 'Color(0x';
const String _hexDigits = '0123456789abcdefABCDEF';

/// 该行是否手写了十六进制颜色(允许 6 位或 8 位 ARGB)。
bool _hasRawColor(String line) {
  var from = 0;
  while (true) {
    final start = line.indexOf(_marker, from);
    if (start < 0) return false;
    final digits = line.substring(start + _marker.length);
    final length = digits.length >= 8 && _hexDigits.contains(digits[7]) ? 8 : 6;
    if (digits.length >= length &&
        digits.substring(0, length).split('').every(_hexDigits.contains)) {
      return true;
    }
    from = start + _marker.length;
  }
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
      final lines = file.readAsLinesSync();
      for (var index = 0; index < lines.length; index++) {
        final line = lines[index];
        if (!_hasRawColor(line)) continue;
        final lineNumber = index + 1;
        final text = line.trim();
        violations.add('$path:$lineNumber: $text');
      }
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
}
