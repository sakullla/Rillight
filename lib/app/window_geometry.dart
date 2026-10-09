import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:screen_retriever/screen_retriever.dart';

/// 窗口下限,低于此无法完整展示顶栏与海报墙。
const Size kMinWindowSize = Size(960, 540);

/// 首次开窗上限(逻辑像素)。4K 工作区很大,不能按 85% 铺满。
///
/// 浏览页需要同时容纳轮播、导航与货架,采用 3:2,不套用片源比例。
const Size kMaxDefaultWindowSize = Size(1440, 960);

/// 独立播放窗介于小窗与浏览窗之间:默认约 1280×720,仍小于片库主窗。
const Size kMinPlayerWindowSize = Size(800, 450);
const Size kMaxPlayerWindowSize = Size(1280, 720);

/// 浏览窗口的首选比例;独立播放窗仍使用 16:9。
const double kAdaptiveAspect = 3 / 2;

/// 工作区越宽,占比越小:小屏接近铺满,1080p 约七成,4K 再封顶。
double adaptiveWorkAreaFraction(double workWidth) {
  if (workWidth >= 2560) {
    return 0.55;
  }
  if (workWidth >= 1920) {
    return 0.70;
  }
  if (workWidth >= 1440) {
    return 0.78;
  }
  return 0.90;
}

/// 由工作区算出开窗逻辑像素。不写死 1280×720 / 1600×900。
Size adaptiveWindowSizeFor(
  Size workArea, {
  Size minSize = kMinWindowSize,
  Size maxSize = kMaxDefaultWindowSize,
  bool playerWindow = false,
}) {
  if (!workArea.width.isFinite ||
      !workArea.height.isFinite ||
      workArea.width <= 0 ||
      workArea.height <= 0) {
    return minSize;
  }
  final fraction = adaptiveWorkAreaFraction(workArea.width);
  var width = workArea.width * fraction;
  if (width > maxSize.width) {
    width = maxSize.width;
  }
  final aspect = playerWindow ? 16 / 9 : kAdaptiveAspect;
  var height = width / aspect;
  // 浏览窗独立利用垂直空间,不再随屏幕宽度一起降低高度占比。
  var maxHeight = workArea.height * (playerWindow ? fraction : .90);
  if (maxHeight > maxSize.height) {
    maxHeight = maxSize.height;
  }
  if (height > maxHeight) {
    height = maxHeight;
    if (playerWindow) width = height * aspect;
  }
  width = width.clamp(math.min(minSize.width, workArea.width), workArea.width);
  height = height.clamp(
    math.min(minSize.height, workArea.height),
    workArea.height,
  );
  return Size(width.roundToDouble(), height.roundToDouble());
}

Size adaptivePlayerWindowSizeFor(Size workArea) {
  return adaptiveWindowSizeFor(
    workArea,
    minSize: kMinPlayerWindowSize,
    maxSize: kMaxPlayerWindowSize,
    playerWindow: true,
  );
}

/// 读主屏可见工作区;失败时退回最小窗,由调用方再 center。
Future<Size> resolveAdaptiveWindowSize({
  Size minSize = kMinWindowSize,
  Size maxSize = kMaxDefaultWindowSize,
  bool playerWindow = false,
}) async {
  try {
    final display = await screenRetriever.getPrimaryDisplay();
    final work = display.visibleSize ?? display.size;
    if (work.width >= 1 && work.height >= 1) {
      return adaptiveWindowSizeFor(
        work,
        minSize: minSize,
        maxSize: maxSize,
        playerWindow: playerWindow,
      );
    }
  } catch (_) {}
  return minSize;
}
