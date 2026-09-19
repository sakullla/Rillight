import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/player/danmaku/dandanplay_models.dart';
import 'package:rillight/player/danmaku/danmaku_display_settings.dart';
import 'package:rillight/player/danmaku/danmaku_timeline.dart';

DanmakuComment comment(
  int cid,
  double time, {
  int mode = 1,
  String text = 'hello',
}) {
  return DanmakuComment(
    cid: cid,
    time: time,
    mode: mode,
    color: 0xFFFFFF,
    text: text,
  );
}

/// 30 条相同文本 '666',均匀落在 [start, start+10s) 内。
List<DanmakuComment> thirtySixes({double start = 0}) => [
  for (var i = 0; i < 30; i++) comment(i + 1, start + i / 3, text: '666'),
];

void main() {
  test('merges 30 identical texts within 10s into one ×30 entry', () {
    final timeline = DanmakuTimeline.build(
      thirtySixes(),
      const DanmakuDisplaySettings(mergeDuplicates: true),
    );
    expect(timeline, hasLength(1));
    expect(timeline.single.displayText, '666 ×30');
    expect(timeline.single.mergedCount, 30);
    expect(timeline.single.cid, 1);
    expect(timeline.single.time, 0);
  });

  test('mergeDuplicates=false keeps all 30 entries with plain text', () {
    final timeline = DanmakuTimeline.build(
      thirtySixes(),
      const DanmakuDisplaySettings(mergeDuplicates: false),
    );
    expect(timeline, hasLength(30));
    expect(timeline.every((e) => e.mergedCount == 1), isTrue);
    expect(timeline.every((e) => e.displayText == '666'), isTrue);
  });

  test('merge window is anchored at the first kept entry', () {
    // 0s 首条开窗;10s、20s 在窗内折叠;20.5s 超窗后开新组,25s 折叠进新组。
    final timeline = DanmakuTimeline.build([
      comment(1, 0, text: '666'),
      comment(2, 10, text: ' 666 '),
      comment(3, 20, text: '666'),
      comment(4, 20.5, text: '666'),
      comment(5, 25, text: '666'),
      comment(6, 12, text: 'other'),
    ], const DanmakuDisplaySettings());
    expect(timeline.map((e) => e.cid), [1, 6, 4]);
    expect(timeline[0].displayText, '666 ×3');
    expect(timeline[1].displayText, 'other');
    expect(timeline[1].mergedCount, 1);
    expect(timeline[2].displayText, '666 ×2');
    expect(kDanmakuMergeWindow, const Duration(seconds: 20));
  });

  test('positioned/advanced modes 7 and 8 are always dropped', () {
    final timeline = DanmakuTimeline.build([
      comment(1, 1, mode: 7, text: '[0,0,"1-1",5,"pos"]'),
      comment(2, 2, mode: 8, text: 'advanced'),
      comment(3, 3, mode: 1, text: 'scroll'),
    ], const DanmakuDisplaySettings());
    expect(timeline.map((e) => e.cid), [3]);
    expect(timeline.single.renderMode, DanmakuMode.scroll);
  });

  test('type switches drop the matching render mode', () {
    final raw = [
      comment(1, 1, mode: 1, text: 'scroll'),
      comment(2, 2, mode: 4, text: 'bottom'),
      comment(3, 3, mode: 5, text: 'top'),
      comment(4, 4, mode: 6, text: 'unknown-as-scroll'),
    ];
    expect(
      DanmakuTimeline.build(
        raw,
        const DanmakuDisplaySettings(showTop: false),
      ).map((e) => e.cid),
      [1, 2, 4],
    );
    expect(
      DanmakuTimeline.build(
        raw,
        const DanmakuDisplaySettings(showBottom: false),
      ).map((e) => e.cid),
      [1, 3, 4],
    );
    expect(
      DanmakuTimeline.build(
        raw,
        const DanmakuDisplaySettings(showScroll: false),
      ).map((e) => e.cid),
      [2, 3],
    );
  });

  test('timeOffset shifts entry.time and may go negative', () {
    final raw = [comment(1, 2), comment(2, 30.25)];
    final shifted = DanmakuTimeline.build(
      raw,
      const DanmakuDisplaySettings(timeOffset: Duration(seconds: 5)),
    );
    expect(shifted[0].time, closeTo(7, 1e-9));
    expect(shifted[1].time, closeTo(35.25, 1e-9));
    expect(shifted[0].comment.time, 2);

    final negative = DanmakuTimeline.build(
      raw,
      const DanmakuDisplaySettings(timeOffset: Duration(seconds: -5)),
    );
    expect(negative[0].time, closeTo(-3, 1e-9));
  });

  test('blocked keywords are case-insensitive and skip merging', () {
    final timeline = DanmakuTimeline.build([
      comment(1, 0, text: 'Spoiler ahead'),
      comment(2, 1, text: 'fine'),
      comment(3, 2, text: '剧透警告'),
      comment(4, 3, text: 'fine'),
    ], const DanmakuDisplaySettings(blockedKeywords: ['spoiler', '剧透']));
    expect(timeline.map((e) => e.cid), [2]);
    expect(timeline.single.displayText, 'fine ×2');
    expect(DanmakuTimeline.isBlocked('SPOILER', ['spoiler']), isTrue);
    expect(DanmakuTimeline.isBlocked('clean', ['spoiler']), isFalse);
    expect(DanmakuTimeline.isBlocked('x', const []), isFalse);
  });

  test('display text is trimmed for merged and single entries alike', () {
    final timeline = DanmakuTimeline.build([
      comment(1, 0, text: '  solo '),
      comment(2, 1, text: ' dup'),
      comment(3, 2, text: 'dup  '),
    ], const DanmakuDisplaySettings());
    expect(timeline.map((e) => e.displayText), ['solo', 'dup ×2']);
    // 原始评论文本保持不变,仅渲染文本去空白。
    expect(timeline.first.comment.text, '  solo ');

    final unmerged = DanmakuTimeline.build([
      comment(1, 0, text: '  solo '),
    ], const DanmakuDisplaySettings(mergeDuplicates: false));
    expect(unmerged.single.displayText, 'solo');
  });

  test('unsorted input is sorted by time and the result is immutable', () {
    final timeline = DanmakuTimeline.build([
      comment(1, 9, text: 'c'),
      comment(2, 1, text: 'a'),
      comment(3, 5),
    ], const DanmakuDisplaySettings());
    expect(timeline.map((e) => e.cid), [2, 3, 1]);
    // 同一时刻按 cid 升序,排序结果确定。
    final tied = DanmakuTimeline.build([
      comment(5, 3, text: 'e'),
      comment(4, 3, text: 'd'),
      comment(1, 0, text: 'a'),
      comment(2, 3, text: 'b'),
    ], const DanmakuDisplaySettings());
    expect(tied.map((e) => e.cid), [1, 2, 4, 5]);
    expect(() => timeline.add(timeline.first), throwsUnsupportedError);
    expect(
      DanmakuTimeline.build(const [], const DanmakuDisplaySettings()),
      isEmpty,
    );
  });

  test('affectsTimeline only reacts to filter/merge/offset fields', () {
    const base = DanmakuDisplaySettings();
    expect(
      DanmakuTimeline.affectsTimeline(
        base,
        base.copyWith(
          opacity: 0.5,
          fontScale: 1.5,
          speed: 2,
          areaFraction: 1,
          colorful: false,
          preventOverlap: false,
          density: DanmakuDensity.dense,
          outline: false,
          followPlaybackRate: false,
        ),
      ),
      isFalse,
    );
    expect(DanmakuTimeline.affectsTimeline(base, base), isFalse);
    expect(
      DanmakuTimeline.affectsTimeline(base, base.copyWith(showScroll: false)),
      isTrue,
    );
    expect(
      DanmakuTimeline.affectsTimeline(base, base.copyWith(showTop: false)),
      isTrue,
    );
    expect(
      DanmakuTimeline.affectsTimeline(base, base.copyWith(showBottom: false)),
      isTrue,
    );
    expect(
      DanmakuTimeline.affectsTimeline(
        base,
        base.copyWith(mergeDuplicates: false),
      ),
      isTrue,
    );
    expect(
      DanmakuTimeline.affectsTimeline(
        base,
        base.copyWith(timeOffset: const Duration(milliseconds: 500)),
      ),
      isTrue,
    );
    expect(
      DanmakuTimeline.affectsTimeline(
        base,
        base.copyWith(blockedKeywords: ['x']),
      ),
      isTrue,
    );
  });
}
