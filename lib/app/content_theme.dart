import 'dart:typed_data';

import 'ui/ui.dart';

import 'package:rillight/auth/auth_scope.dart';

import 'artwork_color_scope.dart';
import 'artwork_theme_source.dart';

import 'package:rillight/library/detail_source_scope.dart';
import 'package:rillight/media_server/models.dart';
import 'package:rillight/media_image/media_image.dart';

/// 从当前剧照取出的内容方案(亮度跟随当前主题)。页面局部套用，不改应用外壳。
///
/// 只对 7 个表面字段染色；主色、容器、选中态、错误与文字保持品牌色。
/// 取色来源由 [resolveThemeArtwork] 统一决定，并通过 [paletteKey] 只接受
/// 与当前画面完全一致的上报，海报、相似行和相邻页不会串色。
class ContentTheme extends StatefulWidget {
  const ContentTheme({
    super.key,
    required this.item,
    required this.child,
    this.preferBackdrop = true,
    this.preferParentBackdrop = false,
    this.fillSurface = true,
  });

  final MediaItem? item;
  final Widget child;

  /// 兼容保留:取色来源现在由 [resolveThemeArtwork] 决定。
  final bool preferBackdrop;

  /// 兼容保留:单集始终优先父级背景。
  final bool preferParentBackdrop;

  /// 为详情页铺一层主题表面。横幅叠在画面上时关掉，只给按钮换色。
  final bool fillSurface;

  static const sampleMaxWidth = 64;

  /// 7 个表面字段随剧照淡入的时长;减少动态效果时由
  /// [AppMotion.durationOf] 归零,文字与主色始终立即切换。
  static const surfaceTransition = AppMotion.slow;

  @visibleForTesting
  static void debugClear() => ArtworkMoodCache.instance.clear();

  @override
  State<ContentTheme> createState() => _ContentThemeState();
}

class _ContentThemeState extends State<ContentTheme> {
  ArtworkMood? _mood;
  String? _paletteKey;
  int _generation = 0;

  void _report(String key, Uint8List bytes) {
    final brightness =
        AppUiTheme.maybeOf(context)?.brightness ?? Brightness.dark;
    final cacheKey = artworkMoodKey(key, brightness);
    final cached = ArtworkMoodCache.instance.peek(cacheKey);
    final generation = ++_generation;
    // Reports arrive from Image.frameBuilder while this subtree is building.
    // A warm cache hit must therefore never call setState synchronously: that
    // throws when the user re-enters a detail page or returns to a cached
    // hero. Apply the mood after the frame instead, cold or warm.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || generation != _generation || _paletteKey != key) return;
      if (cached == null) {
        // Displaying the artwork takes priority over optional palette extraction.
        await MediaImageCache.instance.waitForScrollIdle();
        if (!mounted || generation != _generation || _paletteKey != key) {
          return;
        }
      }
      final mood =
          cached ?? await ArtworkMoodCache.instance.load(cacheKey, bytes);
      if (!mounted || generation != _generation || _paletteKey != key) return;
      if (!identical(_mood, mood)) {
        setState(() => _mood = mood);
      }
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final auth = AuthScope.maybeOf(context);
    final policy = DetailSourceScope.imagePolicyOf(context);
    final scope = policy != null && policy.isValid
        ? policy.scope
        : mediaImageAccountScope(auth);
    final ref = resolveThemeArtwork(widget.item);
    final key = ref == null
        ? null
        : paletteKey(scope, ref.itemId, ref.type, ref.tag);
    if (_paletteKey != key) {
      _paletteKey = key;
      _mood = null;
      ++_generation;
    }
    final base = _baseScheme(theme, theme.brightness);
    final mood = _mood;
    final scheme = mood == null
        ? base
        : composeContentPaletteFromMood(base, mood);
    return _AnimatedSurfaceScheme(
      scheme: scheme,
      builder: (context, surfaces) => AppUiTheme(
        data: theme.copyWith(
          colorScheme: surfaces,
          scaffoldBackgroundColor: surfaces.surface,
          textTheme: theme.textTheme.apply(
            bodyColor: scheme.onSurface,
            displayColor: scheme.onSurface,
          ),
        ),
        child: ArtworkColorScope(
          report: (itemId, reportedKey, bytes) {
            if (_paletteKey == reportedKey) _report(reportedKey, bytes);
          },
          child: widget.fillSurface
              ? ColoredBox(color: surfaces.surface, child: widget.child)
              : widget.child,
        ),
      ),
    );
  }
}

/// 只让剧照允许染色的 7 个表面字段过渡。
///
/// 文字、主色、错误与选中态由 [AppColorScheme.lerpSurfaces] 原样保留,
/// 因此按钮和选中态不会跟着海报慢慢变色。主题明暗切换不是取色结果,
/// 直接跳变,避免整个页面在 320ms 里处于旧亮度。
class _AnimatedSurfaceScheme extends StatefulWidget {
  const _AnimatedSurfaceScheme({required this.scheme, required this.builder});

  final AppColorScheme scheme;
  final Widget Function(BuildContext context, AppColorScheme scheme) builder;

  @override
  State<_AnimatedSurfaceScheme> createState() => _AnimatedSurfaceSchemeState();
}

class _AnimatedSurfaceSchemeState extends State<_AnimatedSurfaceScheme>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final CurvedAnimation _progress;
  late AppColorScheme _from;
  late AppColorScheme _to;

  @override
  void initState() {
    super.initState();
    _from = widget.scheme;
    _to = widget.scheme;
    _controller = AnimationController(
      vsync: this,
      duration: ContentTheme.surfaceTransition,
      value: 1,
    );
    _progress = CurvedAnimation(parent: _controller, curve: AppMotion.standard);
  }

  @override
  void didUpdateWidget(_AnimatedSurfaceScheme oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_sameSurfaces(_to, widget.scheme)) return;
    final shown = _controller.value >= 1
        ? _to
        : AppColorScheme.lerpSurfaces(_from, _to, _progress.value);
    _from = shown;
    _to = widget.scheme;
    // A brightness switch replaces the whole neutral base; blending it would
    // keep the old brightness in every descendant for the whole transition.
    final duration = oldWidget.scheme.brightness == widget.scheme.brightness
        ? AppMotion.durationOf(context, ContentTheme.surfaceTransition)
        : Duration.zero;
    if (duration == Duration.zero) {
      _from = _to;
      _controller.stop();
      return;
    }
    _controller
      ..duration = duration
      ..forward(from: 0);
  }

  @override
  void dispose() {
    _progress.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (AppMotion.durationOf(context, ContentTheme.surfaceTransition) ==
        Duration.zero) {
      // Reduce motion: snap to the resolved surfaces, keep no in-flight frame.
      _from = widget.scheme;
      _to = widget.scheme;
      if (_controller.value != 1) _controller.value = 1;
      return widget.builder(context, widget.scheme);
    }
    return AnimatedBuilder(
      animation: _progress,
      builder: (context, _) {
        final value = _progress.value;
        return widget.builder(
          context,
          value >= 1 ? _to : AppColorScheme.lerpSurfaces(_from, _to, value),
        );
      },
    );
  }
}

bool _sameSurfaces(AppColorScheme a, AppColorScheme b) =>
    a.surface == b.surface &&
    a.surfaceContainerLowest == b.surfaceContainerLowest &&
    a.surfaceContainerLow == b.surfaceContainerLow &&
    a.surfaceContainer == b.surfaceContainer &&
    a.surfaceContainerHigh == b.surfaceContainerHigh &&
    a.surfaceContainerHighest == b.surfaceContainerHighest &&
    a.surfaceBright == b.surfaceBright;

/// 取色的中性底:手机用影院黑/纸白,桌面和电视沿用各自的应用取色。
AppColorScheme _baseScheme(AppUiThemeData theme, Brightness brightness) {
  final dark = brightness == Brightness.dark;
  if (theme.phone) {
    return dark
        ? AppUiTheme.phoneDark().colorScheme
        : AppUiTheme.phoneLight().colorScheme;
  }
  return dark ? AppUiTheme.dark().colorScheme : AppUiTheme.light().colorScheme;
}
