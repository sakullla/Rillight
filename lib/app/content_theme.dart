import 'dart:typed_data';

import 'ui/ui.dart';

import 'package:rillight/auth/auth_scope.dart';

import 'artwork_color_scope.dart';

import 'package:rillight/media_server/models.dart';
import 'package:rillight/media_image/media_image.dart';

/// 从当前海报取出的内容方案(亮度跟随当前主题)。页面局部套用，不改应用外壳。
///
/// 从可见彩色像素提取主色，再生成成对的按钮色和中性表面色，
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

  final MediaItem? item;
  final Widget child;
  final bool preferBackdrop;
  final bool preferParentBackdrop;

  /// 为详情页铺一层主题表面。横幅叠在画面上时关掉，只给按钮换色。
  final bool fillSurface;

  static const sampleMaxWidth = 64;

  @visibleForTesting
  static void debugClear() => _schemes.clear();

  static final _schemes = <String, AppColorScheme>{};
  static final _pending = <String, Future<AppColorScheme>>{};

  @override
  State<ContentTheme> createState() => _ContentThemeState();
}

class _ContentThemeState extends State<ContentTheme> {
  AppColorScheme? _scheme;
  String? _identity, _owner;
  int _generation = 0;

  void _report(String itemId, String identity, Uint8List bytes) {
    if (itemId != widget.item?.id) return;
    final brightness =
        AppUiTheme.maybeOf(context)?.brightness ??
        AppUiTheme.of(context).brightness;
    final token = '$identity/${brightness.name}';
    if (_identity == token) return;
    final base = brightness == Brightness.dark
        ? AppUiTheme.dark().colorScheme
        : AppUiTheme.light().colorScheme;
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
            () => contentPaletteFromBytes(bytes, base).whenComplete(() {
              ContentTheme._pending.remove(token);
            }),
          );
      if (!mounted || generation != _generation) return;
      _remember(token, scheme);
      setState(() => _scheme = scheme);
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
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
    if (_owner != owner) {
      _owner = owner;
      _identity = null;
      _scheme = null;
      ++_generation;
    }
    final scheme =
        _scheme ??
        (theme.brightness == Brightness.dark
            ? AppUiTheme.dark().colorScheme
            : AppUiTheme.light().colorScheme);
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
        report: (itemId, identity, bytes) {
          if (_owner == owner) _report(itemId, identity, bytes);
        },
        child: widget.fillSurface
            ? ColoredBox(color: scheme.surface, child: widget.child)
            : widget.child,
      ),
    );
  }
}

void _remember(String token, AppColorScheme scheme) {
  ContentTheme._schemes[token] = scheme;
  if (ContentTheme._schemes.length > 48) {
    ContentTheme._schemes.remove(ContentTheme._schemes.keys.first);
  }
}
