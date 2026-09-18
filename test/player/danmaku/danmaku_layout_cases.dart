import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/player/danmaku/danmaku_layout.dart';
import 'package:rillight/player/danmaku/dandanplay_models.dart';

DanmakuComment comment(
  int cid,
  double time, {
  int mode = 1,
  int color = 0xFFFFFF,
  String text = 'hello',
}) {
  return DanmakuComment(
    cid: cid,
    time: time,
    mode: mode,
    color: color,
    text: text,
  );
}

double measure(String text, double fontSize) => text.length * fontSize * 0.6;

DanmakuLayout layoutWith({
  required List<DanmakuComment> comments,
  DanmakuDisplaySettings settings = const DanmakuDisplaySettings(),
}) {
  final layout = DanmakuLayout(measurer: measure);
  layout.comments = comments;
  layout.settings = settings;
  return layout;
}

const size = Size(800, 400);

void main() {
  test('display settings clamp to legal ranges', () {
    // 构造保留原值,copyWith/fromJson 收敛到合法区间。
    const raw = DanmakuDisplaySettings(
      opacity: 3,
      fontScale: 0.1,
      speed: 10,
      areaFraction: 0,
    );
    final clamped = raw.copyWith();
    expect(clamped.opacity, 1);
    expect(clamped.fontScale, 0.5);
    expect(clamped.speed, 2);
    expect(clamped.areaFraction, 0.1);
    final parsed = DanmakuDisplaySettings.fromJson({'opacity': 0});
    expect(parsed.opacity, 0.1);
  });

  test(
    'comments enter on their timeline slot and exit after lifespan',
    () async {
      final layout = layoutWith(comments: [comment(1, 1)]);
      var frames = layout.update(const Duration(milliseconds: 1000), size);
      expect(frames, hasLength(1));
      // 出生时刻贴右沿。
      expect(frames.single.left, closeTo(800, 0.01));
      expect(frames.single.id, 1);
      expect(frames.single.fontSize, kDanmakuBaseFontSize);

      // 半个滚动周期后处于画面中部(progress 0.5)。
      frames = layout.update(const Duration(seconds: 7), size);
      final width = measure('hello', kDanmakuBaseFontSize);
      expect(frames.single.left, closeTo(800 - 0.5 * (800 + width), 0.01));

      // 周期结束退出。
      frames = layout.update(const Duration(seconds: 14), size);
      expect(frames, isEmpty);
    },
  );

  test('first update mid-timeline positions by real timestamps', () {
    final layout = layoutWith(comments: [comment(1, 10)]);
    final frames = layout.update(const Duration(milliseconds: 10500), size);
    // 出现在 10s,当前 10.5s:滚动进度 0.5/12。
    expect(frames, hasLength(1));
    final width = measure('hello', kDanmakuBaseFontSize);
    expect(frames.single.left, closeTo(800 - (0.5 / 12) * (800 + width), 0.5));
  });

  test('seek forward rebuilds the visible set at the new position', () {
    final layout = layoutWith(comments: [comment(1, 1), comment(2, 300)]);
    var frames = layout.update(const Duration(milliseconds: 1000), size);
    expect(frames.map((f) => f.id), [1]);
    frames = layout.update(const Duration(seconds: 2), size);
    expect(frames.map((f) => f.id), [1]);
    // 前跳到 300.2s:清屏重建,只保留 300s 那条,进度按真实时刻复位。
    frames = layout.update(const Duration(milliseconds: 300200), size);
    expect(frames.map((f) => f.id), [2]);
    final width = measure('hello', kDanmakuBaseFontSize);
    expect(frames.single.left, closeTo(800 - (0.2 / 12) * (800 + width), 0.5));
  });

  test('seek backward rebuilds earlier comments', () {
    final layout = layoutWith(comments: [comment(1, 1), comment(2, 300)]);
    layout.update(const Duration(milliseconds: 300100), size);
    final frames = layout.update(const Duration(seconds: 2), size);
    expect(frames.map((f) => f.id), [1]);
    expect(
      frames.single.left,
      closeTo(800 - (1 / 12) * (800 + measure('hello', 24)), 0.5),
    );
  });

  test('font scale, opacity and speed settings take effect', () {
    final layout = layoutWith(
      comments: [comment(1, 1)],
      settings: const DanmakuDisplaySettings(
        fontScale: 2,
        opacity: 0.5,
        speed: 2,
      ),
    );
    var frames = layout.update(const Duration(milliseconds: 1000), size);
    expect(frames.single.fontSize, kDanmakuBaseFontSize * 2);
    expect(frames.single.opacity, 0.5);
    // speed=2:滚动周期 6s。连续小步推进避免触发 seek 重建。
    for (var t = 1; t <= 6; t++) {
      frames = layout.update(Duration(milliseconds: t * 1000 + 100), size);
    }
    expect(frames, isNotEmpty);
    // 7.1s 时 1+6s 生命周期已过,弹幕退出。
    frames = layout.update(const Duration(milliseconds: 7100), size);
    expect(frames, isEmpty);
  });

  test('display area constrains lanes for scroll and bottom comments', () {
    final layout = layoutWith(
      comments: [
        for (var i = 0; i < 30; i++)
          comment(100 + i, 1 + i * 0.01, text: 'aaaa'),
        comment(1, 1.5, mode: 4),
      ],
      settings: const DanmakuDisplaySettings(areaFraction: 0.25),
    );
    // 一次性推进:seek 重建从新位置回看播种,车道在 100px 区域内分配。
    final frames = layout.update(const Duration(seconds: 2), size);
    final lineHeight = kDanmakuBaseFontSize * 1.35;
    for (final frame in frames) {
      expect(frame.top, lessThan(100 + lineHeight));
      expect(frame.top, greaterThanOrEqualTo(0));
    }
    // 底部固定弹幕贴显示区域下沿(第 0 车道)。
    final bottom = frames.singleWhere((frame) => frame.id == 1);
    expect(bottom.top, closeTo(100 - lineHeight, 0.1));
  });

  test('blocked keywords filter matching comments (case-insensitive)', () {
    final layout = layoutWith(
      comments: [
        comment(1, 1, text: 'keep this'),
        comment(2, 1.1, text: 'skip BAD stuff'),
        comment(3, 1.2, text: 'unrelated'),
      ],
      settings: const DanmakuDisplaySettings(blockedKeywords: ['bad']),
    );
    final frames = layout.update(const Duration(seconds: 2), size);
    expect(frames.map((f) => f.id), isNot(contains(2)));
    expect(frames.map((f) => f.id), containsAll([1, 3]));
  });

  test('density cap limits simultaneous comments', () {
    final layout = layoutWith(
      comments: [for (var i = 0; i < 8; i++) comment(i + 1, 1 + i * 0.05)],
      settings: const DanmakuDisplaySettings(maxVisibleCount: 3),
    );
    final frames = layout.update(const Duration(seconds: 2), size);
    expect(frames, hasLength(3));
    expect(layout.activeCount, 3);
  });

  test('empty comments list is a no-op', () {
    final layout = layoutWith(comments: const []);
    expect(layout.update(const Duration(seconds: 5), size), isEmpty);
  });

  test('small position rewind does not reshuffle lanes or x', () {
    final layout = layoutWith(
      comments: [
        comment(1, 1, text: 'aaaa'),
        comment(2, 1.02, text: 'bbbb'),
        comment(3, 1.04, text: 'cccc'),
      ],
    );
    layout.update(const Duration(milliseconds: 1000), size);
    final stable = layout.update(const Duration(milliseconds: 3000), size);
    expect(stable, isNotEmpty);
    final jittered = layout.update(const Duration(milliseconds: 2800), size);
    expect(jittered.map((f) => f.id), stable.map((f) => f.id));
    for (var i = 0; i < stable.length; i++) {
      expect(jittered[i].id, stable[i].id);
      expect(jittered[i].top, stable[i].top);
      expect(jittered[i].left, closeTo(stable[i].left, 0.01));
    }
  });

  test('simultaneous comments take different lanes instead of overlapping', () {
    final layout = layoutWith(
      comments: [
        comment(1, 1, text: 'same-time-a'),
        comment(2, 1, text: 'same-time-b'),
      ],
    );
    final frames = layout.update(const Duration(milliseconds: 1000), size);
    expect(frames, hasLength(2));
    expect(frames[0].top, isNot(frames[1].top));
    expect((frames[0].left - frames[1].left).abs(), lessThan(1));
  });

  test('busy lane rejects a new comment until the previous fully entered', () {
    final layout = layoutWith(
      comments: [
        comment(1, 1, text: 'xxxxxxxxxx'),
        comment(2, 1.05, text: 'yyyyyyyyyy'),
      ],
    );
    final frames = layout.update(const Duration(milliseconds: 1050), size);
    expect(frames.map((f) => f.id), contains(1));
    final first = frames.singleWhere((f) => f.id == 1);
    final second = frames.where((f) => f.id == 2);
    if (second.isNotEmpty) {
      expect(second.single.top, isNot(first.top));
    }
  });
}
