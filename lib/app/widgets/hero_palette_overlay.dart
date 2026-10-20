import 'dart:typed_data';

import 'package:rillight/app/artwork_color_scope.dart';
import 'package:rillight/app/artwork_theme_source.dart' as theme_source;
import 'package:rillight/app/ui/ui.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/library/detail_source_scope.dart';
import 'package:rillight/media_image/media_image.dart';
import 'package:rillight/media_server/models.dart';

/// 首页头图与详情头部的单层氛围覆盖层。
///
/// 它必须叠在画面之上、可读性遮罩之下:全幅图用 [BoxFit.cover] 铺满,
/// 画在图片后面的氛围不可见。整层 [IgnorePointer],不拦截点击与滑动。
///
/// 渐变只有一层 [AppBrandGradient.ambientFor] 的 4 个 stop:剧照 mood 色
/// → 透明 → 固定品牌天青 → 透明。底部回到透明,页面用
/// [AppUiThemeData.scaffoldBackgroundColor] 继续向下,不会出现
/// “头图染色、页面不染”的硬切边。
///
/// 取色只接受 [paletteKey] 完全匹配的上报。手机 PageView 的相邻页也会
/// 上报,预取只减少首帧,不能作为不串色的理由。
class HeroPaletteOverlay extends StatefulWidget {
  const HeroPaletteOverlay({
    super.key,
    required this.paletteKey,
    required this.child,
  });

  /// 当前可见画面与详情页共用的规范取色标识;为 null 时保持中性氛围。
  final String? paletteKey;

  /// 被观察的画面子树。上报会继续转发给外层 [ArtworkColorScope]。
  final Widget child;

  static const Key overlayKey = Key('hero-palette-overlay');

  /// 首页与详情共用的规范 key,来自 [resolveThemeArtwork]。
  ///
  /// 单仓/多服务器都必须先解析账号作用域,否则同一个条目在不同服务器上
  /// 会命中同一张缓存图。
  static String? paletteKeyFor(
    BuildContext context,
    MediaItem? item, {
    List<MediaItem> series = const [],
  }) {
    MediaItem? parent;
    final seriesId = item?.seriesId;
    if (seriesId != null) {
      for (final entry in series) {
        if (entry.id == seriesId) {
          parent = entry;
          break;
        }
      }
    }
    final ref = theme_source.resolveThemeArtwork(item, parent);
    if (ref == null) return null;
    // 详情页的图片范围由 [DetailSourceScope] 提供。覆盖层必须和 MediaImage、
    // ContentTheme 用同一个范围,否则同一个条目在聚合页会取到登录服务器的缓存。
    final policy = DetailSourceScope.imagePolicyOf(context);
    final scope = policy != null && policy.isValid
        ? policy.scope
        : mediaImageAccountScope(AuthScope.maybeOf(context));
    return theme_source.paletteKey(scope, ref.itemId, ref.type, ref.tag);
  }

  /// 渲染用的 4-stop 氛围渐变。首页覆盖层与详情头部都调用它,
  /// 保证同一剧照的第一 stop 颜色一致。
  static LinearGradient gradientFor(Brightness brightness, ArtworkMood? mood) {
    if (mood == null || mood.neutral || mood.confidence <= 0) {
      return AppBrandGradient.ambientFor(brightness, AppBrand.pink, alpha: .10);
    }
    final hsl = HSLColor.fromColor(mood.seed);
    final stop = HSLColor.fromAHSL(
      1,
      hsl.hue,
      hsl.saturation.clamp(.28, .50),
      brightness == Brightness.dark ? .22 : .90,
    ).toColor();
    final peak = brightness == Brightness.dark ? .18 : .16;
    return AppBrandGradient.ambientFor(
      brightness,
      stop,
      alpha: (peak * mood.confidence).clamp(0.0, peak),
    );
  }

  @override
  State<HeroPaletteOverlay> createState() => _HeroPaletteOverlayState();
}

class _HeroPaletteOverlayState extends State<HeroPaletteOverlay> {
  ArtworkMood? _mood;
  Uint8List? _bytes;
  Brightness? _brightness;
  int _generation = 0;

  void _report(String itemId, String key, Uint8List bytes) {
    // 外层 ContentTheme 仍需要用同一份上报染色表面。
    _outerReport?.call(itemId, key, bytes);
    if (key != widget.paletteKey) return;
    _bytes = bytes;
    _resolve(key, bytes);
  }

  void _resolve(String key, Uint8List bytes) {
    final brightness = AppUiTheme.maybeOf(context)?.brightness;
    if (brightness == null) return;
    final moodKey = theme_source.artworkMoodKey(key, brightness);
    final cached = ArtworkMoodCache.instance.peek(moodKey);
    final generation = ++_generation;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted ||
          generation != _generation ||
          key != widget.paletteKey ||
          brightness != _brightness) {
        return;
      }
      if (cached == null) {
        // 滚动中的取色让位给可见画面,和解码路径保持一致。
        await MediaImageCache.instance.waitForScrollIdle();
        if (!mounted ||
            generation != _generation ||
            key != widget.paletteKey ||
            brightness != _brightness) {
          return;
        }
      }
      final mood =
          cached ?? await ArtworkMoodCache.instance.load(moodKey, bytes);
      if (!mounted ||
          generation != _generation ||
          key != widget.paletteKey ||
          brightness != _brightness) {
        return;
      }
      if (!identical(_mood, mood)) setState(() => _mood = mood);
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  void Function(String, String, Uint8List)? _outerReport;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _outerReport = ArtworkColorScope.maybeOf(context)?.report;
    final brightness = AppUiTheme.of(context).brightness;
    if (_brightness == brightness) return;
    _brightness = brightness;
    // 氛围色按渲染主题缓存;主题切换后必须用同一份字节重新取色。
    _mood = null;
    ++_generation;
    final key = widget.paletteKey;
    final bytes = _bytes;
    if (key != null && bytes != null) _resolve(key, bytes);
  }

  @override
  void didUpdateWidget(HeroPaletteOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.paletteKey != widget.paletteKey) {
      // Keep the previous mood until the next frame resolves; clearing it
      // here would flash the neutral fallback between slides. A null key has
      // no artwork at all, so it does fall back to the brand neutral.
      _bytes = null;
      ++_generation;
      if (widget.paletteKey == null) _mood = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final brightness = AppUiTheme.of(context).brightness;
    return ArtworkColorScope(
      report: _report,
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.child,
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedContainer(
                key: HeroPaletteOverlay.overlayKey,
                duration: AppMotion.durationOf(context, AppMotion.slow),
                curve: AppMotion.standard,
                decoration: BoxDecoration(
                  gradient: HeroPaletteOverlay.gradientFor(brightness, _mood),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
