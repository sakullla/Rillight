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
    if (cached != null) {
      if (!identical(_mood, cached)) {
        setState(() => _mood = cached);
      }
      return;
    }
    final generation = ++_generation;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || generation != _generation || _paletteKey != key) return;
      // Displaying the artwork takes priority over optional palette extraction.
      await MediaImageCache.instance.waitForScrollIdle();
      if (!mounted || generation != _generation || _paletteKey != key) return;
      final mood = await ArtworkMoodCache.instance.load(cacheKey, bytes);
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
    return AppUiTheme(
      data: theme.copyWith(
        colorScheme: scheme,
        scaffoldBackgroundColor: scheme.surface,
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
            ? ColoredBox(color: scheme.surface, child: widget.child)
            : widget.child,
      ),
    );
  }
}

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
