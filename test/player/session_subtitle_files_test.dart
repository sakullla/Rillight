import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/player/session_subtitle_files.dart';

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('subtitle-store-test-');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('sniffs formats from content when the extension is unknown', () {
    final srt = validateSubtitleContent(
      Uint8List.fromList(
        utf8.encode('1\n00:00:01,000 --> 00:00:04,000\nLine\n'),
      ),
    );
    expect(srt.format, SubtitleFileFormat.srt);
    final vtt = validateSubtitleContent(
      Uint8List.fromList(utf8.encode('WEBVTT\n\n00:01.000 --> 00:04.000\nx\n')),
    );
    expect(vtt.format, SubtitleFileFormat.vtt);
    final ass = validateSubtitleContent(
      Uint8List.fromList(
        utf8.encode('[Script Info]\nScriptType: v4.00+\n[Events]\n'),
      ),
    );
    expect(ass.format, SubtitleFileFormat.ass);
    final ssa = validateSubtitleContent(
      Uint8List.fromList(
        utf8.encode('[Script Info]\n[V4 Styles]\nFormat: Name\n'),
      ),
      hint: SubtitleFileFormat.ssa,
    );
    expect(ssa.format, SubtitleFileFormat.ssa);
  });

  test('accepts a UTF-8 BOM and CRLF without changing the bytes', () {
    const body = '﻿1\r\n00:00:01,000 --> 00:00:02,000\r\n两行\r\n字幕\r\n';
    final bytes = Uint8List.fromList(utf8.encode(body));
    final result = validateSubtitleContent(bytes);
    expect(result.format, SubtitleFileFormat.srt);
    expect(result.textLength, body.length - 1, reason: 'BOM 只在解析时剥离');
  });

  test('rejects invalid UTF-8, empty files and non-subtitle documents', () {
    expect(
      () => validateSubtitleContent(Uint8List.fromList([0xFF, 0xFE, 0x00])),
      throwsFormatException,
    );
    expect(
      () => validateSubtitleContent(Uint8List.fromList(utf8.encode('  \n'))),
      throwsFormatException,
    );
    expect(
      () => validateSubtitleContent(
        Uint8List.fromList(utf8.encode('{"kind":"json"}')),
      ),
      throwsFormatException,
    );
    expect(
      () => validateSubtitleContent(
        Uint8List.fromList(utf8.encode('arbitrary text file')),
      ),
      throwsFormatException,
    );
    expect(
      () => validateSubtitleContent(
        Uint8List.fromList(utf8.encode('WEBVTT but srt extension')),
        hint: SubtitleFileFormat.srt,
      ),
      throwsFormatException,
      reason: '扩展名与内容不符时拒绝',
    );
  });

  test('enforces the single-file and session-total limits', () async {
    final store = SessionSubtitleStore(maxFileBytes: 64, maxTotalBytes: 40)
      ..bindDirectory(temp);
    final small = Uint8List.fromList(
      utf8.encode('1\n00:00:01,000 --> 00:00:02,000\na\n'),
    );
    expect(
      (await store.add(fileName: 'a.srt', bytes: small)).outcome,
      SubtitleImportOutcome.added,
    );
    expect(
      (await store.add(fileName: 'b.srt', bytes: small)).outcome,
      SubtitleImportOutcome.duplicate,
    );
    final tooLarge = Uint8List(65);
    expect(
      (await store.add(fileName: 'big.srt', bytes: tooLarge)).outcome,
      SubtitleImportOutcome.tooLarge,
    );
    final second = Uint8List.fromList(
      utf8.encode('2\n00:00:03,000 --> 00:00:04,000\nb\n'),
    );
    expect(
      (await store.add(fileName: 'c.srt', bytes: second)).outcome,
      SubtitleImportOutcome.sessionLimit,
      reason: '会话总量超过上限时拒绝新候选',
    );
    expect(store.files, hasLength(1));
  });

  test('copies into the bound directory and clears with deletion', () async {
    final store = SessionSubtitleStore()..bindDirectory(temp);
    final added = await store.add(
      fileName: '中文 名.srt',
      bytes: Uint8List.fromList(
        utf8.encode('1\n00:00:01,000 --> 00:00:02,000\n中文\n'),
      ),
    );
    expect(added.outcome, SubtitleImportOutcome.added);
    final file = added.file!;
    expect(file.file.path.startsWith(temp.path), isTrue);
    expect(await file.file.exists(), isTrue);
    expect(file.label, '中文 名.srt');

    await store.clear();
    expect(store.files, isEmpty);
    expect(await file.file.exists(), isFalse, reason: '清理删除会话副本');
    // 清理后可以再次导入相同内容。
    expect(
      (await store.add(
        fileName: '中文 名.srt',
        bytes: Uint8List.fromList(
          utf8.encode('1\n00:00:01,000 --> 00:00:02,000\n中文\n'),
        ),
      )).outcome,
      SubtitleImportOutcome.added,
    );
  });
}
