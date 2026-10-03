import 'dart:ui' as ui;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'artwork_color_scope.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/media_image/media_image.dart';

/// 从当前海报取出的内容方案(亮度跟随当前主题)。页面局部套用，不改应用外壳。
///
/// 用 Material 的内容取色：小图量化出一个主色，再生成成对的按钮色和表面色，
/// 保证字和按钮对比度。出错色沿用应用主题，避免失败提示被海报带偏。
class ContentTheme extends StatefulWidget {
  const ContentTheme({
    super.key,
    required this.item,
    required this.child,
    this.preferBackdrop = true,
    this.preferParentBackdrop = false,
    this.fillSurface = true,
  });

  final EmbyItem? item;
  final Widget child;
  final bool preferBackdrop;
  final bool preferParentBackdrop;

  /// 为详情页铺一层主题表面。横幅叠在画面上时关掉，只给按钮换色。
  final bool fillSurface;

  static const sampleMaxWidth = 64;

  @visibleForTesting
  static void debugClear() => _schemes.clear();

  static final _schemes = <String, ColorScheme>{};
  static final _pending = <String, Future<ColorScheme>>{};

  @override
  State<ContentTheme> createState() => _ContentThemeState();
}

class _ContentThemeState extends State<ContentTheme> {
  ColorScheme? _scheme;
  String? _identity, _owner;
  int _generation = 0;

  void _report(String itemId, String identity, Uint8List bytes) {
    if (itemId != widget.item?.id) return;
    final brightness = Theme.of(context).brightness;
    final token = '$identity/${brightness.name}';
    if (_identity == token) return;
    final base = brightness == Brightness.dark
        ? AppTheme.dark().colorScheme
        : AppTheme.light().colorScheme;
    _identity = token;
    final generation = ++_generation;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || generation != _generation) return;
      // Displaying the poster takes priority over optional palette extraction.
      // Disposed content must not start another decode after the wait.
      if (!ContentTheme._schemes.containsKey(token)) {
        await MediaImageCache.instance.waitForScrollIdle();
        if (!mounted || generation != _generation) return;
      }
      final scheme =
          ContentTheme._schemes[token] ??
          await ContentTheme._pending.putIfAbsent(
            token,
            () => contentSchemeFromBytes(bytes, base).whenComplete(() {
              ContentTheme._pending.remove(token);
            }),
          );
      if (!mounted || generation != _generation) return;
      _remember(token, scheme);
      setState(() => _scheme = scheme);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final auth = AuthScope.maybeOf(context);
    final item = widget.item;
    final refs =
        item?.imageCandidates(
          preferBackdrop: widget.preferBackdrop,
          preferParentBackdrop: widget.preferParentBackdrop,
        ) ??
        const <ItemImageRef>[];
    final preferred = refs.firstOrNull;
    // Episodes commonly share a series backdrop. Keep its palette through an
    // episode change; only a different artwork source invalidates the theme.
    final source = preferred == null
        ? 'item:${item?.id}'
        : '${preferred.itemId}:${preferred.type}:${preferred.tag}';
    final owner = '${mediaImageAccountScope(auth)}/${theme.brightness}/$source';
    final sourceChanged = _owner != owner;
    if (sourceChanged) {
      _owner = owner;
      _identity = null;
      _scheme = null;
      ++_generation;
    }
    final scheme =
        _scheme ??
        (theme.brightness == Brightness.dark
            ? AppTheme.dark().colorScheme
            : AppTheme.light().colorScheme);
    final data = theme.copyWith(
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      // 顶栏跟随内容主题:详情页滚动收起的 AppBar 与页面同色,
      // 不再露出应用中性底色(与海报动态色拼接的异色条)。
      appBarTheme: theme.appBarTheme.copyWith(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
      ),
      textTheme: theme.textTheme.apply(
        bodyColor: scheme.onSurface,
        displayColor: scheme.onSurface,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: theme.filledButtonTheme.style?.copyWith(
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.disabled)
                ? scheme.surfaceContainerHighest
                : scheme.primary,
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.disabled)
                ? scheme.onSurfaceVariant
                : scheme.onPrimary,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: theme.textButtonTheme.style?.copyWith(
          foregroundColor: WidgetStatePropertyAll(scheme.primary),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: theme.iconButtonTheme.style?.copyWith(
          foregroundColor: WidgetStatePropertyAll(scheme.onSurface),
        ),
      ),
      chipTheme: theme.chipTheme.copyWith(
        // A flat ActionChip otherwise paints the inherited canvas color,
        // which still belongs to the application rather than this artwork.
        backgroundColor: scheme.surfaceContainerHigh,
        disabledColor: scheme.surfaceContainer,
        selectedColor: scheme.primaryContainer,
        labelStyle: theme.textTheme.labelLarge?.copyWith(
          color: WidgetStateColor.resolveWith((states) {
            if (states.contains(WidgetState.disabled)) {
              return scheme.onSurface.withValues(alpha: .38);
            }
            return states.contains(WidgetState.selected)
                ? scheme.onPrimaryContainer
                : scheme.onSurface;
          }),
        ),
        side: WidgetStateBorderSide.resolveWith((states) {
          if (states.contains(WidgetState.focused)) {
            return BorderSide(color: scheme.primary, width: 2);
          }
          return BorderSide(
            color: states.contains(WidgetState.disabled)
                ? scheme.onSurface.withValues(alpha: .12)
                : scheme.outlineVariant,
          );
        }),
        checkmarkColor: scheme.onPrimaryContainer,
        surfaceTintColor: Colors.transparent,
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: theme.outlinedButtonTheme.style?.copyWith(
          foregroundColor: WidgetStatePropertyAll(scheme.onSurface),
          side: WidgetStatePropertyAll(BorderSide(color: scheme.outline)),
        ),
      ),
    );
    return AnimatedTheme(
      data: data,
      duration: sourceChanged
          ? Duration.zero
          : AppMotion.durationOf(context, AppMotion.slow),
      child: ArtworkColorScope(
        report: (itemId, identity, bytes) {
          if (_owner == owner) _report(itemId, identity, bytes);
        },
        child: Builder(
          builder: (context) => widget.fillSurface
              ? ColoredBox(
                  color: Theme.of(context).colorScheme.surface,
                  child: widget.child,
                )
              : widget.child,
        ),
      ),
    );
  }
}

void _remember(String token, ColorScheme scheme) {
  ContentTheme._schemes[token] = scheme;
  if (ContentTheme._schemes.length > 48) {
    ContentTheme._schemes.remove(ContentTheme._schemes.keys.first);
  }
}

/// 把图片字节收成随当前亮度的 [ColorScheme]:跟随应用主题的
/// [ColorScheme.brightness],浅色主题派生浅色内容色。出错色、表面着色
/// 保持应用自己的约定;海报与视频画面本身不受影响。
@visibleForTesting
Future<ColorScheme> contentSchemeFromBytes(
  Uint8List bytes,
  ColorScheme fallback,
) async {
  try {
    final codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: 32,
      targetHeight: 32,
      allowUpscaling: false,
    );
    final frame = await codec.getNextFrame();
    final data = await frame.image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    );
    frame.image.dispose();
    codec.dispose();
    var colorful = 0;
    if (data != null) {
      final rgba = data.buffer.asUint8List();
      for (var i = 0; i + 3 < rgba.length; i += 4) {
        final rgb = [rgba[i], rgba[i + 1], rgba[i + 2]]..sort();
        if (rgba[i + 3] > 128 &&
            rgb.last - rgb.first > 24 &&
            rgb.last > 32 &&
            rgb.first < 235) {
          colorful++;
        }
      }
    }
    if (colorful < 32) return fallback;
    final extracted = await ColorScheme.fromImageProvider(
      provider: ResizeImage(MemoryImage(bytes), width: 64),
      brightness: fallback.brightness,
      dynamicSchemeVariant: DynamicSchemeVariant.content,
    );
    return composeContentScheme(fallback, extracted);
  } catch (_) {
    return fallback;
  }
}

/// Tonal pairs from the selected artwork own the local content surface. Global
/// navigation and semantic errors retain their application theme.
@visibleForTesting
ColorScheme composeContentScheme(ColorScheme base, ColorScheme artwork) {
  Color tone(Color surface) =>
      Color.lerp(surface, artwork.primaryContainer, .38)!;
  return artwork.copyWith(
    surface: tone(artwork.surface),
    surfaceContainerLow: tone(artwork.surfaceContainerLow),
    surfaceContainer: tone(artwork.surfaceContainer),
    surfaceContainerHigh: tone(artwork.surfaceContainerHigh),
    error: base.error,
    onError: base.onError,
    errorContainer: base.errorContainer,
    onErrorContainer: base.onErrorContainer,
    surfaceTint: Colors.transparent,
  );
}
