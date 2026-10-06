import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const capabilityStatuses = <String>['支持并验证', '能力不支持', '尚未验证', '已失败'];

const capabilityPlatforms = <String>[
  'windows',
  'macos',
  'linux',
  'android-phone',
  'android-tv',
];

const coreCapabilities = <String>[
  'native-dolby-vision',
  'video-output',
  'atmos-passthrough',
  'multichannel-pcm',
  'profile5-rpu',
  'profile7-fel',
  'profile8-base-layer',
  'frame-interpolation',
  'anime4k',
  'super-resolution',
  'denoise',
  'sharpen',
  'frame-interval',
  'av-sync',
  'enhancement-working-set',
];

/// Markers that cannot establish `支持并验证`, including an English alias.
const _insufficientPassMarkers = <String>[
  '首帧',
  'first-frame',
  'first frame',
  'firstframe',
  '模拟器',
  'emulator',
  '单张截图',
  'single screenshot',
  'one screenshot',
];

class CapabilityRow {
  const CapabilityRow({
    required this.platform,
    required this.capability,
    required this.status,
    required this.evidence,
  });

  final String platform;
  final String capability;
  final String status;
  final String evidence;
}

String capabilityRecordSection() {
  final text = File('tool/player_release_evidence.md').readAsStringSync();
  const start = '<!-- capability-record:start -->';
  const end = '<!-- capability-record:end -->';
  final startAt = text.indexOf(start);
  final endAt = text.indexOf(end);
  if (startAt < 0 || endAt <= startAt) {
    throw StateError('capability record markers are missing');
  }
  return text.substring(startAt + start.length, endAt);
}

List<CapabilityRow> parseCapabilityRows(String section) {
  final rows = <CapabilityRow>[];
  for (final raw in section.split('\n')) {
    final line = raw.trim();
    if (!line.startsWith('|')) continue;
    final cells = line
        .split('|')
        .map((cell) => cell.trim())
        .where((cell) => cell.isNotEmpty)
        .toList();
    if (cells.isEmpty) {
      throw FormatException('empty capability table row');
    }
    if (cells.first == 'platform' ||
        cells.every((cell) => RegExp(r'^:?-+:?$').hasMatch(cell))) {
      continue;
    }
    if (cells.length != 4) {
      throw FormatException('capability row must have 4 cells: $line');
    }
    rows.add(
      CapabilityRow(
        platform: cells[0],
        capability: cells[1],
        status: cells[2],
        evidence: cells[3],
      ),
    );
  }
  return rows;
}

bool insufficientWholePassEvidence(String evidence) {
  final text = evidence.toLowerCase();
  return _insufficientPassMarkers.any(text.contains);
}

/// Rejects a whole-item pass built from a first frame, emulator, or one shot.
String? wholeItemPassRejection(CapabilityRow row) {
  if (row.status != '支持并验证') return null;
  if (insufficientWholePassEvidence(row.evidence)) {
    return '首帧、模拟器或单张截图不能记成整项通过';
  }
  final evidence = row.evidence.toLowerCase();
  if (!row.evidence.contains('物理') && !evidence.contains('physical')) {
    return '支持并验证需要物理输出证据，不能记成整项通过';
  }
  return null;
}

void auditRows(List<CapabilityRow> rows) {
  if (rows.isEmpty) {
    throw StateError('capability record has no rows');
  }
  final seen = <String>{};
  for (final row in rows) {
    if (!capabilityStatuses.contains(row.status)) {
      throw StateError('unknown capability status: ${row.status}');
    }
    final key = '${row.platform}/${row.capability}';
    if (!seen.add(key)) {
      throw StateError('duplicate capability row: $key');
    }
    final rejection = wholeItemPassRejection(row);
    if (rejection != null) throw StateError(rejection);
  }
}

CapabilityRow _row(
  List<CapabilityRow> rows,
  String platform,
  String capability,
) {
  return rows.singleWhere(
    (row) => row.platform == platform && row.capability == capability,
  );
}

void main() {
  test('capability record fixes the five-target matrix and thresholds', () {
    final section = capabilityRecordSection();
    final rows = parseCapabilityRows(section);
    auditRows(rows);

    for (final status in capabilityStatuses) {
      expect(section, contains(status));
    }
    expect(section, contains('测量结果不能反过来改阈值'));
    expect(section, contains('1080p24'));
    expect(section, contains('至少 95% 的呈现间隔落在理想值的 0.5 到 1.5 倍'));
    expect(section, contains('超过 2 倍的不超过 1%'));
    expect(section, contains('80 毫秒'));
    expect(section, contains('1.5 GiB'));
    expect(section, contains('未单列的片源、连接和增强组合同样尚未验证'));

    for (final platform in capabilityPlatforms) {
      for (final capability in coreCapabilities) {
        expect(
          rows.where(
            (row) => row.platform == platform && row.capability == capability,
          ),
          hasLength(1),
          reason: '$platform/$capability',
        );
      }
    }
    expect(rows.where((row) => row.status == '支持并验证'), isEmpty);
  });

  test('scRGB, EDR, and SDR mapping stay non-native Dolby', () {
    final rows = parseCapabilityRows(capabilityRecordSection());

    for (final platform in ['windows', 'macos', 'linux']) {
      expect(_row(rows, platform, 'native-dolby-vision').status, '能力不支持');
    }
    expect(
      _row(rows, 'windows', 'video-output').evidence,
      contains('scRGB 是非原生杜比'),
    );
    expect(
      _row(rows, 'macos', 'video-output').evidence,
      contains('EDR 是非原生杜比'),
    );
    expect(
      _row(rows, 'linux', 'video-output').evidence,
      contains('SDR 映射是非原生杜比'),
    );
    expect(_row(rows, 'linux', 'hdr-output').status, '能力不支持');
    expect(
      _row(rows, 'linux', 'native-dolby-vision').evidence,
      contains('SDR 映射是非原生杜比'),
    );
  });

  test('PKM110 cannot claim Dolby Vision and Android TV stays unverified', () {
    final rows = parseCapabilityRows(capabilityRecordSection());
    final phone = _row(rows, 'android-phone', 'native-dolby-vision');
    expect(phone.status, '能力不支持');
    expect(phone.evidence, contains('PKM110'));
    expect(phone.evidence, contains('video/dolby-vision'));
    expect(_row(rows, 'android-phone', 'profile5-rpu').status, '尚未验证');
    expect(
      _row(rows, 'android-phone', 'profile5-rpu').evidence,
      contains('旧通过不沿用'),
    );
    expect(_row(rows, 'android-phone', 'physical-lock').status, '尚未验证');
    expect(_row(rows, 'android-phone', 'frame-interval').status, '尚未验证');

    final television = rows.where((row) => row.platform == 'android-tv');
    expect(television.map((row) => row.capability), coreCapabilities);
    for (final row in television) {
      expect(row.status, '尚未验证', reason: row.capability);
      expect(row.evidence, '没有 leanback 机器，不用手机结果顶替');
    }
  });

  test('historical Android failure is not the current candidate result', () {
    final rows = parseCapabilityRows(capabilityRecordSection());
    final historical = _row(
      rows,
      'historical-android-2026-10-01',
      'dolby-frame-interval-and-long-gop-seek',
    );
    expect(historical.status, '已失败');
    expect(historical.evidence, contains('不自动成为当前候选结论'));
    expect(historical.evidence, contains('passed=false'));
  });

  test(
    'first frame, emulator, or one screenshot cannot be a whole-item pass',
    () {
      const rejected = <String>[
        '首帧回调',
        'first-frame callback',
        'firstFrame event',
        '模拟器上的变化画面',
        'emulator virtual speaker',
        '单张截图',
        'a single screenshot of the HDR frame',
        'one screenshot',
      ];
      for (final evidence in rejected) {
        expect(
          wholeItemPassRejection(
            CapabilityRow(
              platform: 'windows',
              capability: 'video-output',
              status: '支持并验证',
              evidence: evidence,
            ),
          ),
          '首帧、模拟器或单张截图不能记成整项通过',
          reason: evidence,
        );
        expect(
          () => auditRows(
            parseCapabilityRows('''
| platform | capability | status | evidence |
| --- | --- | --- | --- |
| windows | video-output | 支持并验证 | $evidence |
'''),
          ),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('不能记成整项通过'),
            ),
          ),
          reason: evidence,
        );
      }

      expect(
        wholeItemPassRejection(
          const CapabilityRow(
            platform: 'windows',
            capability: 'video-output',
            status: '支持并验证',
            evidence: '参考机上的连续物理画面与物理扬声器',
          ),
        ),
        isNull,
      );
      expect(
        wholeItemPassRejection(
          const CapabilityRow(
            platform: 'macos',
            capability: 'av-sync',
            status: '支持并验证',
            evidence:
                'physical speaker and changing frames on the reference Mac',
          ),
        ),
        isNull,
      );
      auditRows(const [
        CapabilityRow(
          platform: 'android-phone',
          capability: 'video-output',
          status: '尚未验证',
          evidence: '模拟器结果不能记成整项通过',
        ),
      ]);
      auditRows(parseCapabilityRows(capabilityRecordSection()));
    },
  );
}
