import 'package:flutter/widgets.dart';
import 'package:screen_retriever/screen_retriever.dart';

/// 窗口下限,低于此无法完整展示顶栏与海报墙。
const Size kMinWindowSize = Size(960, 540);

/// 首次开窗上限(逻辑像素)。4K 工作区很大,不能按 85% 铺满。
///
/// Chrome/Spotify/Discord 默认约 1200–1440 宽;媒体墙略宽取 1440×810 (16:9)。
const Size kMaxDefaultWindowSize = Size(1440, 810);

/// 独立播放窗介于小窗与浏览窗之间:默认约 1280×720,仍小于片库主窗。
const Size kMinPlayerWindowSize = Size(800, 450);
const Size kMaxPlayerWindowSize = Size(1280, 720);

/// 片源以 16:9 为主,开窗跟这个比例,避免上下黑边过大。
const double kAdaptiveAspect = 16 / 9;

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
}) {
  if (workArea.width <= 0 || workArea.height <= 0) {
    return minSize;
  }
  final fraction = adaptiveWorkAreaFraction(workArea.width);
  var width = workArea.width * fraction;
  if (width > maxSize.width) {
    width = maxSize.width;
  }
  var height = width / kAdaptiveAspect;
  var maxHeight = workArea.height * fraction;
  if (maxHeight > maxSize.height) {
    maxHeight = maxSize.height;
  }
  if (height > maxHeight) {
    height = maxHeight;
    width = height * kAdaptiveAspect;
  }
  width = width.clamp(minSize.width, workArea.width);
  height = height.clamp(minSize.height, workArea.height);
  return Size(width.roundToDouble(), height.roundToDouble());
}

Size adaptivePlayerWindowSizeFor(Size workArea) {
  return adaptiveWindowSizeFor(
    workArea,
    minSize: kMinPlayerWindowSize,
    maxSize: kMaxPlayerWindowSize,
  );
}

/// 读主屏可见工作区;失败时退回最小窗,由调用方再 center。
Future<Size> resolveAdaptiveWindowSize({
  Size minSize = kMinWindowSize,
  Size maxSize = kMaxDefaultWindowSize,
}) async {
  try {
    final display = await screenRetriever.getPrimaryDisplay();
    final work = display.visibleSize ?? display.size;
    if (work.width >= 1 && work.height >= 1) {
      return adaptiveWindowSizeFor(work, minSize: minSize, maxSize: maxSize);
    }
  } catch (_) {}
  return minSize;
}
