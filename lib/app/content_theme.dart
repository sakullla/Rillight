import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/media_image/media_image.dart';

/// 从当前海报取出的深色方案。页面局部套用，不改应用外壳。
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

  @override
  State<ContentTheme> createState() => _ContentThemeState();
}

class _ContentThemeState extends State<ContentTheme> {
  ColorScheme? _scheme;
  String? _token;
  int _generation = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _schedule();
  }

  @override
  void didUpdateWidget(ContentTheme oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item?.id != widget.item?.id ||
        oldWidget.item?.primaryImageTag != widget.item?.primaryImageTag ||
        oldWidget.item?.backdropImageTag != widget.item?.backdropImageTag ||
        oldWidget.item?.parentBackdropImageTag !=
            widget.item?.parentBackdropImageTag ||
        oldWidget.preferBackdrop != widget.preferBackdrop ||
        oldWidget.preferParentBackdrop != widget.preferParentBackdrop) {
      _schedule();
    }
  }

  void _schedule() {
    // 测试里图片解码会留下取色超时计时器，页面卸载后测试无法收干净。
    if (Platform.environment['FLUTTER_TEST'] == 'true') {
      return;
    }
    final item = widget.item;
    final auth = AuthScope.maybeOf(context);
    if (item == null || auth == null) {
      _token = null;
      if (_scheme != null) {
        setState(() => _scheme = null);
      }
      return;
    }
    final candidates = item.imageCandidates(
      preferBackdrop: widget.preferBackdrop,
      preferParentBackdrop: widget.preferParentBackdrop,
    );
    if (candidates.isEmpty) {
      return;
    }
    final ref = candidates.first;
    final serverId = auth.session?.server.id ?? '';
    final token = MediaImageCache.key(
      serverId: serverId,
      itemId: ref.itemId,
      type: ref.type,
      tag: ref.tag,
      maxWidth: ContentTheme.sampleMaxWidth,
    );
    if (token == _token) {
      return;
    }
    _token = token;
    final cached = ContentTheme._schemes[token];
    if (cached != null) {
      setState(() => _scheme = cached);
      return;
    }
    final generation = ++_generation;
    final client = auth.client;
    unawaited(_load(generation, token, serverId, ref, client));
  }

  Future<void> _load(
    int generation,
    String token,
    String serverId,
    ItemImageRef ref,
    EmbyClient client,
  ) async {
    try {
      final bytes = await MediaImageCache.instance.load(
        serverId: serverId,
        itemId: ref.itemId,
        type: ref.type,
        tag: ref.tag,
        maxWidth: ContentTheme.sampleMaxWidth,
        fetch: () async {
          final data = await client.getItemImage(
            ref.itemId,
            type: ref.type,
            tag: ref.tag,
            maxWidth: ContentTheme.sampleMaxWidth,
          );
          return Uint8List.fromList(data);
        },
      );
      if (!mounted || generation != _generation || bytes == null) {
        return;
      }
      final fallback = Theme.of(context).colorScheme;
      final scheme = await contentSchemeFromBytes(bytes, fallback);
      if (!mounted || generation != _generation) {
        return;
      }
      _remember(token, scheme);
      setState(() => _scheme = scheme);
    } catch (_) {
      // 取色失败就留在应用主题上，页面照常显示。
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = _scheme;
    final data = scheme == null
        ? theme
        : theme.copyWith(
            colorScheme: scheme,
            scaffoldBackgroundColor: scheme.surface,
            filledButtonTheme: FilledButtonThemeData(
              style: theme.filledButtonTheme.style?.copyWith(
                backgroundColor: WidgetStateProperty.resolveWith((states) {
                  if (states.contains(WidgetState.disabled)) {
                    return scheme.onSurface.withValues(alpha: 0.12);
                  }
                  return scheme.primary;
                }),
                foregroundColor: WidgetStateProperty.resolveWith((states) {
                  if (states.contains(WidgetState.disabled)) {
                    return scheme.onSurface.withValues(alpha: 0.38);
                  }
                  return scheme.onPrimary;
                }),
                iconColor: WidgetStateProperty.resolveWith((states) {
                  if (states.contains(WidgetState.disabled)) {
                    return scheme.onSurface.withValues(alpha: 0.38);
                  }
                  return scheme.onPrimary;
                }),
              ),
            ),
          );
    return AnimatedTheme(
      data: data,
      duration: AppMotion.slow,
      child: Builder(
        builder: (context) {
          final child = widget.child;
          if (!widget.fillSurface) {
            return child;
          }
          return ColoredBox(
            color: Theme.of(context).colorScheme.surface,
            child: child,
          );
        },
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

/// 把图片字节收成深色 [ColorScheme]。出错色、表面着色保持应用自己的约定。
@visibleForTesting
Future<ColorScheme> contentSchemeFromBytes(
  Uint8List bytes,
  ColorScheme fallback,
) async {
  final extracted = await ColorScheme.fromImageProvider(
    provider: MemoryImage(bytes),
    brightness: Brightness.dark,
    dynamicSchemeVariant: DynamicSchemeVariant.content,
  );
  return extracted.copyWith(
    error: fallback.error,
    onError: fallback.onError,
    errorContainer: fallback.errorContainer,
    onErrorContainer: fallback.onErrorContainer,
    onSurface: fallback.onSurface,
    onSurfaceVariant: fallback.onSurfaceVariant,
    surfaceTint: Colors.transparent,
  );
}
