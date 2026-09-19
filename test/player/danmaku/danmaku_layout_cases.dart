import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/player/danmaku/danmaku_layout.dart';
import 'package:rillight/player/danmaku/danmaku_timeline.dart';
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

DanmakuEntry entryOf(
  DanmakuComment source, {
  int mergedCount = 1,
  String? displayText,
}) {
  return DanmakuEntry(
    comment: source,
    time: source.time,
    mergedCount: mergedCount,
    renderMode: source.renderMode,
    displayText: displayText ?? source.text,
  );
}

double measure(String text, double fontSize) => text.length * fontSize * 0.6;

int fontPxFor(Size size, {double fontScale = 1}) {
  final viewScale = (size.height / kDanmakuViewportReferenceHeight).clamp(
    kDanmakuViewportScaleMin,
    kDanmakuViewportScaleMax,
  );
  return (kDanmakuBaseFontSize * fontScale * viewScale).round();
}

int laneCountFor(Size size, {double areaFraction = 0.5, double fontScale = 1}) {
  final fontPx = fontPxFor(size, fontScale: fontScale);
  final lineHeight = fontPx * kDanmakuLineHeightFactor;
  return (size.height * areaFraction / lineHeight).floor();
}

DanmakuLayout layoutWith({
  List<DanmakuComment>? comments,
  List<DanmakuEntry>? entries,
  DanmakuDisplaySettings settings = const DanmakuDisplaySettings(),
}) {
  final layout = DanmakuLayout(measurer: measure);
  if (entries != null) {
    layout.entries = entries;
  }
  if (comments != null) {
    layout.comments = comments;
  }
  layout.settings = settings;
  return layout;
}

const size = Size(800, 400);

void expectNoSameLaneXOverlap(List<DanmakuActive> active) {
  for (var i = 0; i < active.length; i++) {
    for (var j = i + 1; j < active.length; j++) {
      final a = active[i];
      final b = active[j];
      if (a.mode != b.mode || a.lane != b.lane) {
        continue;
      }
      final aRight = a.left + a.width;
      final bRight = b.left + b.width;
      final disjoint = aRight <= b.left || bRight <= a.left;
      expect(
        disjoint,
        isTrue,
        reason: 'cid ${a.id} and ${b.id} overlap on lane ${a.lane}',
      );
    }
  }
}

void main() {
  test('display settings clamp opacity and snap steps to legal ranges', () {
    // 构造保留原值,copyWith/fromJson 收敛:不透明度夹到 0.2–1,
    // 字号/速度/区域吸附到最近档位。
    const raw = DanmakuDisplaySettings(
      opacity: 3,
      fontScale: 0.1,
      speed: 10,
      areaFraction: 0,
    );
    final clamped = raw.copyWith();
    expect(clamped.opacity, 1);
    expect(clamped.fontScale, 0.75);
    expect(clamped.speed, 2);
    expect(clamped.areaFraction, 0.25);
    final parsed = DanmakuDisplaySettings.fromJson({'opacity': 0});
    expect(parsed.opacity, 0.2);
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
      expect(frames.single.fontSize, fontPxFor(size));

      // 半个滚动周期后处于画面中部(progress 0.5)。
      frames = layout.update(const Duration(seconds: 7), size);
      final width = measure('hello', fontPxFor(size).toDouble());
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
    final width = measure('hello', fontPxFor(size).toDouble());
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
    final width = measure('hello', fontPxFor(size).toDouble());
    expect(frames.single.left, closeTo(800 - (0.2 / 12) * (800 + width), 0.5));
  });

  test('seek backward rebuilds earlier comments', () {
    final layout = layoutWith(comments: [comment(1, 1), comment(2, 300)]);
    layout.update(const Duration(milliseconds: 300100), size);
    final frames = layout.update(const Duration(seconds: 2), size);
    expect(frames.map((f) => f.id), [1]);
    final width = measure('hello', fontPxFor(size).toDouble());
    expect(frames.single.left, closeTo(800 - (1 / 12) * (800 + width), 0.5));
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
    expect(frames.single.fontSize, fontPxFor(size, fontScale: 2));
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
    final lineHeight = fontPxFor(size) * kDanmakuLineHeightFactor;
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

  group('density cap = multiplier × lane count', () {
    // 800×400、areaFraction 0.5:字号随 400px 视口夹到 0.6 倍后取整。
    final laneCount = laneCountFor(size);
    List<DanmakuComment> stream() => [
      for (var i = 0; i < 10; i++) comment(i + 1, 1 + i * 1.2),
    ];

    int visible(DanmakuDensity density) {
      final layout = layoutWith(
        comments: stream(),
        settings: DanmakuDisplaySettings(density: density),
      );
      final frames = layout.update(const Duration(seconds: 12), size);
      expect(layout.activeCount, frames.length);
      return frames.length;
    }

    test('sparse never exceeds the lane count', () {
      expect(visible(DanmakuDensity.sparse), laneCount);
    });

    test('auto allows up to twice the lane count', () {
      expect(visible(DanmakuDensity.auto), 10);
      final layout = layoutWith(
        comments: [for (var i = 0; i < 30; i++) comment(i + 1, 1 + i * 0.3)],
        settings: const DanmakuDisplaySettings(),
      );
      layout.update(const Duration(seconds: 10), size);
      expect(layout.activeCount, lessThanOrEqualTo(laneCount * 2));
    });

    test('dense allows up to four times the lane count', () {
      final layout = layoutWith(
        comments: [for (var i = 0; i < 60; i++) comment(i + 1, 1 + i * 0.15)],
        settings: const DanmakuDisplaySettings(density: DanmakuDensity.dense),
      );
      layout.update(const Duration(seconds: 10), size);
      expect(layout.activeCount, lessThanOrEqualTo(laneCount * 4));
      expect(layout.activeCount, greaterThan(laneCount * 2));
    });

    test('unlimited is not capped', () {
      expect(visible(DanmakuDensity.unlimited), 10);
    });
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
    final ids = [for (final item in stable) item.id];
    final tops = [for (final item in stable) item.top];
    final lefts = [for (final item in stable) item.left];
    final jittered = layout.update(const Duration(milliseconds: 2800), size);
    expect(jittered.map((f) => f.id), ids);
    for (var i = 0; i < ids.length; i++) {
      expect(jittered[i].id, ids[i]);
      expect(jittered[i].top, tops[i]);
      expect(jittered[i].left, closeTo(lefts[i], 0.01));
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

  test(
    '200 simultaneous scroll comments do not overlap when preventOverlap',
    () {
      const viewport = Size(1920, 1080);
      final layout = layoutWith(
        comments: [
          for (var i = 0; i < 200; i++) comment(i + 1, 1, text: 'xxxxxxxxxx'),
        ],
      );
      layout.update(const Duration(milliseconds: 1000), viewport);
      final active = layout.activeEntries;
      expect(active.length, lessThan(200));
      expect(active.length, lessThanOrEqualTo(layout.laneCount));
      expectNoSameLaneXOverlap(active);
    },
  );

  test('preventOverlap false sparse caps at lane count; unlimited stacks', () {
    const viewport = Size(1920, 1080);
    final comments = [
      for (var i = 0; i < 200; i++) comment(i + 1, 1, text: 'xxxxxxxxxx'),
    ];
    final sparse = layoutWith(
      comments: comments,
      settings: const DanmakuDisplaySettings(
        preventOverlap: false,
        density: DanmakuDensity.sparse,
      ),
    );
    sparse.update(const Duration(milliseconds: 1000), viewport);
    expect(sparse.activeEntries.length, lessThanOrEqualTo(sparse.laneCount));

    final stacked = layoutWith(
      comments: comments,
      settings: const DanmakuDisplaySettings(
        preventOverlap: false,
        density: DanmakuDensity.unlimited,
      ),
    );
    stacked.update(const Duration(milliseconds: 1000), viewport);
    expect(stacked.activeEntries.length, greaterThan(stacked.laneCount));
    var overlapped = false;
    final active = stacked.activeEntries;
    for (var i = 0; i < active.length; i++) {
      for (var j = i + 1; j < active.length; j++) {
        final a = active[i];
        final b = active[j];
        if (a.mode != b.mode || a.lane != b.lane) {
          continue;
        }
        final aRight = a.left + a.width;
        final bRight = b.left + b.width;
        if (aRight > b.left && bRight > a.left) {
          overlapped = true;
        }
      }
    }
    expect(overlapped, isTrue);
  });

  test('fontPx at 720 vs 1080 follows viewport ratio within 1px', () {
    final comments = [comment(1, 1)];
    final short = layoutWith(comments: comments);
    short.update(const Duration(milliseconds: 1000), const Size(1280, 720));
    final tall = layoutWith(comments: comments);
    tall.update(const Duration(milliseconds: 1000), const Size(1920, 1080));
    expect(tall.fontPx, 26);
    expect(
      (short.fontPx - tall.fontPx * 720 / 1080).abs(),
      lessThanOrEqualTo(1),
    );
  });

  test('resize keeps on-screen count, lanes and progress-scaled x', () {
    const small = Size(1280, 720);
    const large = Size(1920, 1080);
    final layout = layoutWith(
      comments: [for (var i = 0; i < 8; i++) comment(i + 1, 1, text: 'hello')],
    );
    layout.update(const Duration(seconds: 2), small);
    final before = [
      for (final item in layout.activeEntries)
        (id: item.id, lane: item.lane, spawn: item.spawn, life: item.lifespan),
    ];
    expect(before, isNotEmpty);
    final generation = layout.styleGeneration;
    layout.update(const Duration(seconds: 2), large);
    expect(layout.activeEntries.length, before.length);
    expect(layout.styleGeneration, greaterThan(generation));
    final fp = fontPxFor(large);
    for (var i = 0; i < before.length; i++) {
      final item = layout.activeEntries[i];
      expect(item.id, before[i].id);
      expect(item.lane, before[i].lane);
      final progress =
          (const Duration(seconds: 2) - before[i].spawn).inMicroseconds /
          before[i].life.inMicroseconds;
      final width = measure('hello', fp.toDouble());
      expect(
        item.left,
        closeTo(large.width - progress * (large.width + width), 0.5),
      );
    }
  });

  test('followPlaybackRate false stretches spawn lifespan by rate', () {
    Duration life({required bool follow, required double rate}) {
      final layout = layoutWith(
        comments: [comment(1, 1)],
        settings: DanmakuDisplaySettings(followPlaybackRate: follow),
      );
      layout.playbackRate = rate;
      layout.update(const Duration(milliseconds: 1000), size);
      return layout.activeEntries.single.lifespan;
    }

    final base = life(follow: true, rate: 1);
    expect(life(follow: true, rate: 2), base);
    expect(
      life(follow: false, rate: 2).inMicroseconds,
      base.inMicroseconds * 2,
    );
  });

  test('consecutive updates reuse the same activeEntries list', () {
    final layout = layoutWith(comments: [comment(1, 1)]);
    final first = layout.update(const Duration(milliseconds: 1000), size);
    final previous = layout.activeEntries;
    expect(identical(first, previous), isTrue);
    final second = layout.update(const Duration(milliseconds: 1100), size);
    expect(identical(second, previous), isTrue);
    expect(identical(layout.activeEntries, previous), isTrue);
  });

  test('seek expires dead fixed comments before seeding live scroll', () {
    // sparse 上限 = 车道数。若先播种已过期的顶部弹幕再过期,它们会占满密度槽,
    // 12s 滚动窗口内仍存活的滚动弹幕会被挤掉。
    final tops = [
      for (var i = 0; i < 40; i++)
        comment(1000 + i, i * 0.05, mode: 5, text: 'top$i'),
    ];
    final scrolls = [
      for (var i = 0; i < 8; i++) comment(i + 1, 10 + i * 0.02, text: 'live$i'),
    ];
    final layout = layoutWith(
      comments: [...tops, ...scrolls],
      settings: const DanmakuDisplaySettings(density: DanmakuDensity.sparse),
    );
    layout.update(const Duration(milliseconds: 12000), size);
    expect(layout.activeEntries, isNotEmpty);
    expect(
      layout.activeEntries.every((item) => item.mode == DanmakuMode.scroll),
      isTrue,
    );
    expect(
      layout.activeEntries.map((item) => item.id),
      everyElement(lessThan(1000)),
    );
  });

  test('entries setter wins over comments shim', () {
    final layout = layoutWith(
      comments: [comment(1, 1, text: 'from-comments')],
      entries: [entryOf(comment(2, 1, text: 'from-entries'))],
    );
    layout.update(const Duration(milliseconds: 1000), size);
    expect(layout.activeEntries.single.id, 2);
    expect(layout.activeEntries.single.text, 'from-entries');
  });
}
