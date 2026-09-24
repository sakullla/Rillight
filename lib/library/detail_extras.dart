import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/presentation_environment.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/app/tv_widgets.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/library/provider_marks.dart';
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
  );
}

class DetailGenreRow extends StatelessWidget {
  const DetailGenreRow({super.key, required this.item});

  final EmbyItem item;

  @override
  Widget build(BuildContext context) {
    if (item.genres.isEmpty) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.sm),
      child: Wrap(
        spacing: AppSpacing.sm,
        runSpacing: AppSpacing.xs,
        children: [
          for (final genre in item.genres)
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
  const DetailAlbumStrip({super.key, required this.item});

  final EmbyItem item;

  @override
  Widget build(BuildContext context) {
    final album = detailAlbumOf(item);
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
            height: 96,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: album.tags.length,
              separatorBuilder: (context, index) =>
                  const SizedBox(width: AppSpacing.sm),
              itemBuilder: (context, index) {
                return GestureDetector(
                  onTap: () => _open(context, album.itemId, album.tags, index),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(AppRadii.sm),
                    child: SizedBox(
                      width: 170,
                      child: _AlbumStill(
                        itemId: album.itemId,
                        tag: album.tags[index],
                        index: index,
                        maxWidth: 480,
                      ),
                    ),
                  ),
                );
              },
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
      builder: (context) {
        final page = PageController(initialPage: index);
        return Dialog(
          backgroundColor: Colors.black,
          insetPadding: const EdgeInsets.all(AppSpacing.md),
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: PageView.builder(
              controller: page,
              itemCount: tags.length,
              itemBuilder: (context, pageIndex) {
                return _AlbumStill(
                  itemId: itemId,
                  tag: tags[pageIndex],
                  index: pageIndex,
                  maxWidth: 1280,
                );
              },
            ),
          ),
        );
      },
    );
  }
}

class _AlbumStill extends StatefulWidget {
  const _AlbumStill({
    required this.itemId,
    required this.tag,
    required this.index,
    required this.maxWidth,
  });

  final String itemId;
  final String tag;
  final int index;
  final int maxWidth;

  @override
  State<_AlbumStill> createState() => _AlbumStillState();
}

class _AlbumStillState extends State<_AlbumStill> {
  Future<List<int>>? _bytes;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bytes ??= AuthScope.of(context).client.getItemImage(
      widget.itemId,
      type: 'Backdrop',
      tag: widget.tag,
      index: widget.index,
      maxWidth: widget.maxWidth,
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<int>>(
      future: _bytes,
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (bytes == null || bytes.isEmpty) {
          return ColoredBox(
            color: Theme.of(context).colorScheme.surfaceContainerHigh,
          );
        }
        return Image.memory(
          bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
          fit: BoxFit.cover,
        );
      },
    );
  }
}
