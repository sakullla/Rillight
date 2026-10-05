import 'dart:io';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/presentation_environment.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/app/tv_widgets.dart';
import 'package:rillight/app/widgets/scrim_icon_button.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/library/provider_marks.dart';
import 'detail_source_scope.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// 详情页相册用的剧照。优先本条目的多张背景图，单集没有时用剧集背景图。
({String itemId, List<String> tags})? detailAlbumOf(EmbyItem item) {
  if (item.backdropImageTags.length > 1) {
    return (itemId: item.id, tags: item.backdropImageTags);
  }
  final parentId = item.parentBackdropItemId;
  if (item.isEpisode &&
      parentId != null &&
      item.parentBackdropImageTags.length > 1) {
    return (itemId: parentId, tags: item.parentBackdropImageTags);
  }
  return null;
}

void openGenreShelf(BuildContext context, EmbyItem item, String genre) {
  final types = item.isSeries || item.isEpisode ? 'Series' : 'Movie';
  final parent = item.isEpisode ? null : item.parentId;
  context.push(
    AppRoutes.shelfItems(
      parentId: parent,
      includeItemTypes: types,
      title: genre,
      recursive: true,
      genre: genre,
    ),
    extra: DetailSourceScope.command(context, item.id),
  );
}

class DetailGenreRow extends StatelessWidget {
  const DetailGenreRow({super.key, required this.item, this.genres});

  final EmbyItem item;

  /// 切集的列表条目经常不带流派。传入后沿用已经显示的名称，避免芯片先消失。
  final List<String>? genres;

  @override
  Widget build(BuildContext context) {
    final genres = this.genres ?? item.genres;
    if (genres.isEmpty) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.sm),
      child: Wrap(
        spacing: AppSpacing.sm,
        runSpacing: AppSpacing.xs,
        children: [
          for (final genre in genres)
            ActionChip(
              label: Text(genre),
              onPressed: () => openGenreShelf(context, item, genre),
            ),
        ],
      ),
    );
  }
}

/// Trakt 公开站的 `/search/{id_type}/{id}` 会 404。改成还能打开的标题搜索。
Uri? resolveExternalLink(String raw, {String? title}) {
  final uri = Uri.tryParse(raw.trim());
  if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http')) {
    return null;
  }
  final host = uri.host.toLowerCase();
  final trakt =
      host == 'trakt.tv' || host == 'www.trakt.tv' || host == 'app.trakt.tv';
  if (!trakt) {
    return uri;
  }
  final parts = uri.pathSegments.where((part) => part.isNotEmpty).toList();
  if (parts.length >= 3 && parts.first == 'search') {
    final query = title?.trim();
    if (query == null || query.isEmpty) {
      return null;
    }
    return Uri.https('trakt.tv', '/search', {'query': query});
  }
  if (host != 'trakt.tv') {
    return uri.replace(host: 'trakt.tv');
  }
  return uri;
}

class DetailExternalLinks extends StatelessWidget {
  const DetailExternalLinks({super.key, required this.links, this.title});

  final List<ItemExternalUrl> links;
  final String? title;

  @override
  Widget build(BuildContext context) {
    final visible = [
      for (final link in links)
        if (resolveExternalLink(link.url, title: title) != null) link,
    ];
    if (visible.isEmpty) {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.externalLinks,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              for (final link in visible)
                _ExternalLinkButton(link: link, title: title),
            ],
          ),
        ],
      ),
    );
  }
}

class _ExternalLinkButton extends StatelessWidget {
  const _ExternalLinkButton({required this.link, required this.title});

  final ItemExternalUrl link;
  final String? title;

  @override
  Widget build(BuildContext context) {
    final label = link.name.isEmpty ? link.url : link.name;
    final mark = ProviderMark.match(link.name, link.url);
    final scheme = Theme.of(context).colorScheme;
    final name = mark?.shortName ?? label;
    // 低调化:文字/短标/缺省图标统一 onSurfaceVariant 单色,
    // 品牌色只保留在 16px 图形标志的 tint,不再给文字铺色。
    final content = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (mark?.svg != null) ...[
          ProviderMarkIcon(mark: mark!, size: 16),
          const SizedBox(width: AppSpacing.xs),
        ] else if (mark != null) ...[
          ProviderMarkIcon(
            mark: mark,
            size: 16,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: AppSpacing.xs),
        ] else ...[
          Icon(Icons.link, size: 16, color: scheme.onSurfaceVariant),
          const SizedBox(width: AppSpacing.xs),
        ],
        Text(
          name,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
            color: scheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
    if (PresentationScope.of(context).isTv) {
      // TV:走 TvAction 纳入 D-pad 焦点序列,焦点视觉由 tv_widgets 统一。
      return Tooltip(
        message: label,
        child: TvAction(
          key: ValueKey('external-link-${link.url}'),
          onPressed: () => _open(context),
          child: content,
        ),
      );
    }
    return Tooltip(
      message: label,
      child: Material(
        key: ValueKey('external-link-${link.url}'),
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(AppRadii.sm),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _open(context),
          // 悬停/焦点仅轻微提亮,不出现高饱和色块。
          hoverColor: scheme.onSurface.withValues(alpha: 0.06),
          focusColor: scheme.onSurface.withValues(alpha: 0.08),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.sm,
              vertical: AppSpacing.xs,
            ),
            child: content,
          ),
        ),
      ),
    );
  }

  Future<void> _open(BuildContext context) async {
    final uri = resolveExternalLink(link.url, title: title);
    if (uri == null) {
      _showFailure(context);
      return;
    }
    final platform = Theme.of(context).platform;
    final mobile =
        platform == TargetPlatform.android || platform == TargetPlatform.iOS;
    if (mobile) {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (context) => ExternalLinkPage(
            title: link.name.isEmpty ? uri.host : link.name,
            uri: uri,
          ),
        ),
      );
      return;
    }
    try {
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!launched && context.mounted) {
        _showFailure(context);
      }
    } catch (_) {
      if (context.mounted) {
        _showFailure(context);
      }
    }
  }

  void _showFailure(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text('${l10n.externalLinks} · ${l10n.errorLoadFailed}'),
        ),
      );
  }
}

class ExternalLinkPage extends StatefulWidget {
  const ExternalLinkPage({super.key, required this.title, required this.uri});

  final String title;
  final Uri uri;

  @override
  State<ExternalLinkPage> createState() => _ExternalLinkPageState();
}

class _ExternalLinkPageState extends State<ExternalLinkPage> {
  late final WebViewController _controller;
  var _loading = true;
  var _backgroundApplied = false;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            if (mounted) {
              setState(() => _loading = false);
            }
          },
        ),
      )
      ..loadRequest(widget.uri);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_backgroundApplied) {
      return;
    }
    _backgroundApplied = true;
    _controller.setBackgroundColor(Theme.of(context).colorScheme.surface);
  }

  @override
  Widget build(BuildContext context) {
    final surface = Theme.of(context).colorScheme.surface;
    return Scaffold(
      appBar: AppBar(leading: const BackButton(), title: Text(widget.title)),
      body: ColoredBox(
        color: surface,
        child: Stack(
          children: [
            WebViewWidget(controller: _controller),
            if (_loading) const Center(child: CircularProgressIndicator()),
          ],
        ),
      ),
    );
  }
}

class DetailAlbumStrip extends StatelessWidget {
  const DetailAlbumStrip({
    super.key,
    required this.item,
    this.thumbnailWidth = 170,
    this.album,
  });

  final EmbyItem item;
  final double thumbnailWidth;

  /// 切集时列表条目往往没有剧照。调用方可以沿用上一集已经显示的相册。
  final ({String itemId, List<String> tags})? album;

  @override
  Widget build(BuildContext context) {
    final album = this.album ?? detailAlbumOf(item);
    if (album == null) {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.phoneAlbum, style: theme.textTheme.titleMedium),
          const SizedBox(height: AppSpacing.sm),
          SizedBox(
            height: thumbnailWidth * 9 / 16,
            child: _AlbumRail(
              key: ValueKey(album.itemId),
              itemId: album.itemId,
              tags: album.tags,
              thumbnailWidth: thumbnailWidth,
              onOpen: (index) =>
                  _open(context, album.itemId, album.tags, index),
            ),
          ),
        ],
      ),
    );
  }

  void _open(
    BuildContext context,
    String itemId,
    List<String> tags,
    int index,
  ) {
    showDialog<void>(
      context: context,
      useRootNavigator: false,
      builder: (context) =>
          _AlbumViewer(itemId: itemId, tags: tags, initialIndex: index),
    );
  }
}

/// 相册横条。桌面默认不能用鼠标拖动横向列表，滚轮又只滚整页，
/// 所以这里同时接受鼠标拖动，并用滚轮和两侧按钮左右移动。
class _AlbumRail extends StatefulWidget {
  const _AlbumRail({
    super.key,
    required this.itemId,
    required this.tags,
    required this.thumbnailWidth,
    required this.onOpen,
  });

  final String itemId;
  final List<String> tags;
  final double thumbnailWidth;
  final ValueChanged<int> onOpen;

  @override
  State<_AlbumRail> createState() => _AlbumRailState();
}

class _AlbumRailState extends State<_AlbumRail> {
  final _controller = ScrollController();
  var _canScrollLeft = false;
  var _canScrollRight = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_updateButtons);
  }

  @override
  void dispose() {
    _controller.removeListener(_updateButtons);
    _controller.dispose();
    super.dispose();
  }

  void _updateButtons() {
    if (!_controller.hasClients) {
      if (_canScrollLeft || _canScrollRight) {
        setState(() {
          _canScrollLeft = false;
          _canScrollRight = false;
        });
      }
      return;
    }
    final position = _controller.position;
    if (!position.hasContentDimensions) {
      return;
    }
    final overflowing = position.maxScrollExtent > 0.5;
    final canLeft = overflowing && position.pixels > 0.5;
    final canRight =
        overflowing && position.pixels < position.maxScrollExtent - 0.5;
    if (canLeft != _canScrollLeft || canRight != _canScrollRight) {
      setState(() {
        _canScrollLeft = canLeft;
        _canScrollRight = canRight;
      });
    }
  }

  void _page(int direction) {
    if (!_controller.hasClients) {
      return;
    }
    final position = _controller.position;
    final target =
        (position.pixels + position.viewportDimension * 0.9 * direction).clamp(
          0.0,
          position.maxScrollExtent,
        );
    final duration = AppMotion.durationOf(context);
    if (duration == Duration.zero) {
      _controller.jumpTo(target);
      return;
    }
    _controller.animateTo(
      target,
      duration: duration,
      curve: AppMotion.standard,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final ratio = MediaQuery.devicePixelRatioOf(context);
    return Stack(
      children: [
        NotificationListener<ScrollMetricsNotification>(
          onNotification: (_) {
            _updateButtons();
            return false;
          },
          child: ScrollConfiguration(
            behavior: const _AlbumScrollBehavior(),
            child: ListView.separated(
              controller: _controller,
              scrollDirection: Axis.horizontal,
              itemCount: widget.tags.length,
              separatorBuilder: (context, index) =>
                  const SizedBox(width: AppSpacing.sm),
              itemBuilder: (context, index) {
                return Material(
                  clipBehavior: Clip.antiAlias,
                  borderRadius: BorderRadius.circular(AppRadii.sm),
                  child: InkWell(
                    onTap: () => widget.onOpen(index),
                    borderRadius: BorderRadius.circular(AppRadii.sm),
                    child: SizedBox(
                      width: widget.thumbnailWidth,
                      child: _AlbumStill(
                        itemId: widget.itemId,
                        tag: widget.tags[index],
                        index: index,
                        maxWidth: (widget.thumbnailWidth * ratio).ceil().clamp(
                          480,
                          1280,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        if (_canScrollLeft)
          Align(
            alignment: Alignment.centerLeft,
            child: ScrimIconButton(
              key: CatalogKeys.shelfScrollLeft(CatalogKeys.shelfAlbum),
              tooltip: l10n.scrollLeft,
              icon: const Icon(Icons.chevron_left),
              onPressed: () => _page(-1),
            ),
          ),
        if (_canScrollRight)
          Align(
            alignment: Alignment.centerRight,
            child: ScrimIconButton(
              key: CatalogKeys.shelfScrollRight(CatalogKeys.shelfAlbum),
              tooltip: l10n.scrollRight,
              icon: const Icon(Icons.chevron_right),
              onPressed: () => _page(1),
            ),
          ),
      ],
    );
  }
}

class _AlbumScrollBehavior extends MaterialScrollBehavior {
  const _AlbumScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => const {
    PointerDeviceKind.mouse,
    PointerDeviceKind.touch,
    PointerDeviceKind.stylus,
    PointerDeviceKind.trackpad,
    PointerDeviceKind.invertedStylus,
  };
}

class _AlbumStill extends StatefulWidget {
  const _AlbumStill({
    required this.itemId,
    required this.tag,
    required this.index,
    required this.maxWidth,
    this.fit = BoxFit.cover,
    this.load,
  });

  final String itemId;
  final String tag;
  final int index;
  final int? maxWidth;
  final BoxFit fit;
  final Future<List<int>> Function()? load;

  @override
  State<_AlbumStill> createState() => _AlbumStillState();
}

class _AlbumStillState extends State<_AlbumStill> {
  Future<List<int>>? _bytes;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bytes ??= _load();
  }

  @override
  void didUpdateWidget(_AlbumStill oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.itemId != widget.itemId ||
        oldWidget.tag != widget.tag ||
        oldWidget.index != widget.index ||
        oldWidget.maxWidth != widget.maxWidth) {
      _bytes = _load();
    }
  }

  Future<List<int>> _load() {
    if (widget.load != null) return widget.load!();
    final client = AuthScope.of(context).client;
    return widget.maxWidth == null
        ? client.getOriginalItemImage(
            widget.itemId,
            type: 'Backdrop',
            tag: widget.tag,
            index: widget.index,
          )
        : client.getItemImage(
            widget.itemId,
            type: 'Backdrop',
            tag: widget.tag,
            index: widget.index,
            maxWidth: widget.maxWidth!,
          );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<int>>(
      future: _bytes,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          final l10n = AppLocalizations.of(context);
          return Center(
            child: TextButton.icon(
              onPressed: () {
                final next = _load();
                setState(() {
                  _bytes = next;
                });
              },
              icon: const Icon(Icons.refresh_rounded),
              label: Text('${l10n.errorLoadFailed} · ${l10n.retry}'),
            ),
          );
        }
        final bytes = snapshot.data;
        if (bytes == null || bytes.isEmpty) {
          return ColoredBox(
            color: Theme.of(context).colorScheme.surfaceContainerHigh,
            child: const Center(
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }
        return Image.memory(
          bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
          fit: widget.fit,
          errorBuilder: (context, error, stack) =>
              Center(child: Text(AppLocalizations.of(context).errorLoadFailed)),
        );
      },
    );
  }
}

class _AlbumViewer extends StatefulWidget {
  const _AlbumViewer({
    required this.itemId,
    required this.tags,
    required this.initialIndex,
  });
  final String itemId;
  final List<String> tags;
  final int initialIndex;
  @override
  State<_AlbumViewer> createState() => _AlbumViewerState();
}

class _AlbumViewerState extends State<_AlbumViewer> {
  late final PageController _pages = PageController(
    initialPage: widget.initialIndex,
  );
  late int _index = widget.initialIndex;
  bool _saving = false;
  final _originals = <int, Future<List<int>>>{};

  Future<List<int>> _loadOriginal(int index) =>
      _originals.putIfAbsent(index, () async {
        try {
          return await AuthScope.of(context).client.getOriginalItemImage(
            widget.itemId,
            type: 'Backdrop',
            index: index,
            tag: widget.tags[index],
          );
        } catch (_) {
          _originals.remove(index);
          rethrow;
        }
      });

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  Future<void> _download() async {
    if (_saving) return;
    final index = _index;
    final l10n = AppLocalizations.of(context);
    setState(() => _saving = true);
    try {
      final bytes = Uint8List.fromList(await _loadOriginal(index));
      if (!mounted) return;
      final (extension, mime) = _imageFormat(bytes);
      final name = 'rillight-${widget.itemId}-${index + 1}.$extension';
      if (Platform.isAndroid) {
        final saved = await const MethodChannel('rillight/android_core')
            .invokeMethod<bool>('saveAlbumImage', {
              'bytes': bytes,
              'name': name,
              'mime': mime,
            });
        if (saved != true) return;
      } else {
        final location = await getSaveLocation(
          suggestedName: name,
          acceptedTypeGroups: [
            XTypeGroup(label: extension.toUpperCase(), extensions: [extension]),
          ],
        );
        if (location == null) return;
        await XFile.fromData(
          bytes,
          name: name,
          mimeType: mime,
        ).saveTo(location.path);
      }
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l10n.albumDownloadSaved)));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l10n.albumDownloadFailed)));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  (String, String) _imageFormat(Uint8List bytes) {
    bool startsWith(List<int> signature, [int offset = 0]) {
      if (bytes.length < offset + signature.length) return false;
      for (var i = 0; i < signature.length; i++) {
        if (bytes[offset + i] != signature[i]) return false;
      }
      return true;
    }

    if (startsWith([137, 80, 78, 71, 13, 10, 26, 10])) {
      return ('png', 'image/png');
    }
    if (startsWith([82, 73, 70, 70]) && startsWith([87, 69, 66, 80], 8)) {
      return ('webp', 'image/webp');
    }
    if (startsWith([255, 216, 255])) return ('jpg', 'image/jpeg');
    if (startsWith([71, 73, 70, 56, 55, 97]) ||
        startsWith([71, 73, 70, 56, 57, 97])) {
      return ('gif', 'image/gif');
    }
    if (startsWith([66, 77])) return ('bmp', 'image/bmp');
    throw const FormatException('Unsupported image response');
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Theme(
      data: ThemeData.dark(useMaterial3: true),
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.arrowLeft): () {
            if (_index > 0) {
              _pages.previousPage(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
              );
            }
          },
          const SingleActivator(LogicalKeyboardKey.arrowRight): () {
            if (_index + 1 < widget.tags.length) {
              _pages.nextPage(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
              );
            }
          },
        },
        child: Focus(
          autofocus: true,
          child: Dialog(
            backgroundColor: Colors.black,
            insetPadding: const EdgeInsets.all(16),
            clipBehavior: Clip.antiAlias,
            child: SizedBox(
              width: AppViewport.fit(
                1200,
                MediaQuery.sizeOf(context).width - 32,
                MediaQuery.sizeOf(context),
              ),
              height: MediaQuery.sizeOf(context).height * .85,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${_index + 1} / ${widget.tags.length}',
                            style: const TextStyle(color: Colors.white70),
                          ),
                        ),
                        TextButton.icon(
                          onPressed: _saving ? null : _download,
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.white,
                          ),
                          icon: _saving
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.download_rounded),
                          label: Text(l10n.albumDownload),
                        ),
                        IconButton(
                          color: Colors.white,
                          tooltip: MaterialLocalizations.of(
                            context,
                          ).closeButtonTooltip,
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Stack(
                      children: [
                        PageView.builder(
                          controller: _pages,
                          itemCount: widget.tags.length,
                          onPageChanged: (value) =>
                              setState(() => _index = value),
                          itemBuilder: (context, index) => InteractiveViewer(
                            minScale: 1,
                            maxScale: 5,
                            child: _AlbumStill(
                              itemId: widget.itemId,
                              tag: widget.tags[index],
                              index: index,
                              maxWidth: null,
                              fit: BoxFit.contain,
                              load: () => _loadOriginal(index),
                            ),
                          ),
                        ),
                        if (_index > 0)
                          Align(
                            alignment: Alignment.centerLeft,
                            child: IconButton.filledTonal(
                              tooltip: l10n.albumPrevious,
                              onPressed: () => _pages.previousPage(
                                duration: const Duration(milliseconds: 200),
                                curve: Curves.easeOut,
                              ),
                              icon: const Icon(Icons.chevron_left_rounded),
                            ),
                          ),
                        if (_index + 1 < widget.tags.length)
                          Align(
                            alignment: Alignment.centerRight,
                            child: IconButton.filledTonal(
                              tooltip: l10n.albumNext,
                              onPressed: () => _pages.nextPage(
                                duration: const Duration(milliseconds: 200),
                                curve: Curves.easeOut,
                              ),
                              icon: const Icon(Icons.chevron_right_rounded),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
