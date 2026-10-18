import '../auth/server_content_entry.dart';
import '../auth/source_sessions.dart';

import 'package:rillight/media_server/media_server_client.dart';

import 'dart:async';

import 'package:rillight/app/app_shell.dart';

import 'package:rillight/app/ui/app_icons.dart';
import 'package:rillight/app/ui/ui.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;

import 'package:go_router/go_router.dart';

import '../aggregation/view/server_sections.dart';

import '../auth/auth_scope.dart';
import '../auth/server_selection_page.dart';

import '../app/l10n/app_localizations.dart';
import '../app/mobile_chrome.dart';
import '../app/phone_bottom_nav.dart';
import '../app/phone_nav_style.dart';
import '../app/presentation_environment.dart';
import '../app/routes.dart';
import '../app/widgets/skeleton.dart';
import '../app/tv_top_nav.dart';
import '../app/tv_widgets.dart';
import '../app/window_chrome.dart';
import '../app/widgets/app_empty_view.dart';
import '../app/widgets/option_pill.dart';
import '../auth/auth_controller.dart';
import '../auth/server_list_store.dart';
import '../media_server/errors.dart';
import '../home/media_shelf.dart';
import '../search/recent_searches.dart';

import '../search/search_overlay.dart';
import '../media_image/media_image.dart';

import 'detail_source_scope.dart';

import 'poster_card.dart';
import '../app/mobile_widgets.dart';
import '../home/catalog_failure.dart';
import '../home/catalog_keys.dart';
import 'server_library_page.dart';

/// 手机壳已经把聚合/搜索顶到顶栏下面时为 true，页内不再重复避开状态栏。
class PhoneShellContentInset extends InheritedWidget {
  const PhoneShellContentInset({
    super.key,
    required this.cleared,
    required super.child,
  });

  final bool cleared;

  static bool clearedOf(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<PhoneShellContentInset>();
    return scope?.cleared ?? false;
  }

  @override
  bool updateShouldNotify(PhoneShellContentInset oldWidget) =>
      cleared != oldWidget.cleared;
}

class AggregationPage extends StatelessWidget {
  const AggregationPage({
    super.key,
    this.search = false,
    this.searchFocusNode,
    this.searchClearsTopBar = true,
    this.onCloseSearch,
  });
  final bool search;
  final FocusNode? searchFocusNode;
  final bool searchClearsTopBar;
  final VoidCallback? onCloseSearch;

  @override
  Widget build(BuildContext context) => search
      ? _AggregationSearch(
          focusNode: searchFocusNode,
          clearOfDesktopBar: searchClearsTopBar,
          onClose: onCloseSearch,
        )
      : const _AggregationBrowse();
}

enum _AggregationSegment { continueWatching, favorites, libraries }

class _AggregationBrowse extends StatefulWidget {
  const _AggregationBrowse();

  @override
  State<_AggregationBrowse> createState() => _AggregationBrowseState();
}

class _AggregationBrowseState extends State<_AggregationBrowse> {
  ServerSectionsLoader? _loader;
  var _started = false;
  var _segment = _AggregationSegment.continueWatching;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final auth = AuthScope.of(context);
    if (_loader == null || !identical(_loader!.registry, auth.sources)) {
      _loader?.removeListener(_onLoader);
      _loader?.dispose();
      _loader = ServerSectionsLoader(registry: auth.sources)
        ..addListener(_onLoader);
      _started = false;
    }
    if (_started) return;
    _started = true;
    final loader = _loader!;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) loader.load();
    });
  }

  void _onLoader() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _loader?.removeListener(_onLoader);
    _loader?.dispose();
    super.dispose();
  }

  ServerSectionSlice _slice(ServerSections section) => switch (_segment) {
    _AggregationSegment.continueWatching => section.continueWatching,
    _AggregationSegment.favorites => section.favorites,
    _AggregationSegment.libraries => section.libraries,
  };

  String _moreLocation(String id) => _segment == _AggregationSegment.favorites
      ? '${AppRoutes.serverResume(id)}?section=favorites'
      : AppRoutes.serverResume(id);

  Future<void> _open(ServerSections section, MediaItem item) async {
    if (!await enterServerContent(
          context,
          AuthScope.of(context),
          section.serverId,
        ) ||
        !mounted) {
      return;
    }
    if (_segment == _AggregationSegment.libraries) {
      final current = AuthScope.of(context).session?.server.id;
      if (current == section.serverId) {
        context.push(AppRoutes.library(item.id));
      } else {
        context.push(
          '/server/${Uri.encodeComponent(section.serverId)}/library/${Uri.encodeComponent(item.id)}',
        );
      }
      return;
    }
    final account = section.account;
    if (account == null) return;
    openServerItem(context, account: account, item: item);
  }

  Widget _segments(AppLocalizations l) {
    final scheme = AppUiTheme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.65),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _segmentButton(
              l.resumePlay,
              'aggregation-segment-continue',
              _AggregationSegment.continueWatching,
            ),
            _segmentButton(
              l.filterFavorite,
              'aggregation-segment-favorites',
              _AggregationSegment.favorites,
            ),
            _segmentButton(
              l.libraries,
              'aggregation-segment-libraries',
              _AggregationSegment.libraries,
            ),
          ],
        ),
      ),
    );
  }

  Widget _segmentButton(
    String label,
    String keyName,
    _AggregationSegment value,
  ) {
    final selected = _segment == value;
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    return AppButton(
      key: Key(keyName),
      onPressed: () => setState(() => _segment = value),
      style: AppButtonStyle(
        foregroundColor: selected
            ? scheme.onPrimaryContainer
            : scheme.onSurfaceVariant,
        backgroundColor: selected
            ? scheme.primaryContainer
            : const Color(0x00000000),
        side: selected
            ? BorderSide(color: scheme.primary.withValues(alpha: 0.35))
            : null,
        textStyle: theme.textTheme.labelLarge?.copyWith(
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        minimumSize: const Size(0, 34),
        shape: const StadiumBorder(),
      ),
      variant: AppButtonVariant.plain,
      child: Text(label),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final loader = _loader;
    final servers = loader?.servers ?? const <ServerSections>[];
    final desktop = PresentationScope.of(context).isDesktop;
    final rows = servers;
    if (PresentationScope.of(context).isTv) {
      return _tvBuild(context, loader, servers, rows);
    }
    if (!desktop) return _phoneBuild(context, loader, servers, rows);
    return Container(
      decoration: BoxDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(
              desktop ? AppSpacing.page : AppSpacing.md,
              desktop ? AppShell.topBarHeight + AppSpacing.sm : 6,
              desktop ? AppSpacing.page : AppSpacing.md,
              4,
            ),
            child: Row(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: _segments(l),
                  ),
                ),
                AppIconButton(
                  key: const Key('aggregation-source-management'),
                  tooltip: l.serversTitle,
                  onPressed: () =>
                      showServerSelection(context, auth: AuthScope.of(context)),
                  icon: const Icon(CupertinoIcons.slider_horizontal_3),
                ),
              ],
            ),
          ),
          Expanded(child: _body(context, loader, servers, rows)),
        ],
      ),
    );
  }

  Widget _body(
    BuildContext context,
    ServerSectionsLoader? loader,
    List<ServerSections> servers,
    List<ServerSections> rows,
  ) {
    final l = AppLocalizations.of(context);
    if (loader == null || (loader.loading && servers.isEmpty)) {
      return const Center(child: CupertinoActivityIndicator());
    }
    if (servers.isEmpty) {
      return AppEmptyView(
        message: '没有已登录的服务器',
        actionLabel: l.addServer,
        onAction: () => context.push('${AppRoutes.connect}?add=1'),
      );
    }
    if (rows.isEmpty) {
      return AppEmptyView(message: l.aggregationEmpty);
    }
    final captioned = _segment == _AggregationSegment.continueWatching;
    final libraries = _segment == _AggregationSegment.libraries;
    final indices = {for (var i = 0; i < rows.length; i++) rows[i].serverId: i};
    return MediaImageScrollListener(
      key: const PageStorageKey('aggregation'),
      child: ListView.builder(
        key: PageStorageKey('aggregation-$_segment'),
        scrollCacheExtent: const ScrollCacheExtent.viewport(0.5),
        itemCount: rows.length,
        findChildIndexCallback: (key) =>
            indices[(key as ValueKey<String>).value],
        itemBuilder: (context, index) {
          final section = rows[index];
          final slice = _slice(section);
          if (section.locked ||
              section.needsLogin ||
              (!slice.loading && slice.error == null && slice.items.isEmpty)) {
            return _serverPlaceholder(context, section);
          }
          return KeyedSubtree(
            key: ValueKey(section.serverId),
            child: scopeServerPosters(
              account: section.account,
              serverId: section.serverId,
              child: MediaShelf(
                key: ValueKey('aggregation-server-${section.serverId}'),
                shelfId: 'aggregation-${section.serverId}-$_segment',
                title: section.serverName,
                items: slice.items,
                loading: slice.loading,
                error: slice.error,
                onRetry: slice.error == null
                    ? null
                    : () => loader.retry(section.serverId),
                onTap: (item) => _open(section, item),
                wide: captioned || libraries,
                showProgress: captioned,
                onMore: !libraries && slice.items.isNotEmpty
                    ? () => context.push(_moreLocation(section.serverId))
                    : null,
                extent: libraries ? _libraryExtent(context) : null,
                itemBuilder: libraries
                    ? (context, item) => _libraryCard(context, section, item)
                    : null,
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _serverPlaceholder(BuildContext context, ServerSections section) {
    final l = AppLocalizations.of(context);
    final message = section.locked
        ? l.serversLocked
        : section.needsLogin
        ? l.serversAccount
        : l.aggregationEmpty;
    Future<void> enter() async {
      if (await enterServerContent(
            context,
            AuthScope.of(context),
            section.serverId,
          ) &&
          mounted) {
        await _loader?.retry(section.serverId);
      }
    }

    final action = section.locked || section.needsLogin;
    return Padding(
      key: ValueKey('aggregation-server-${section.serverId}'),
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            section.serverName,
            style: AppUiTheme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              if (section.locked) const Icon(CupertinoIcons.lock),
              const SizedBox(width: 8),
              Expanded(child: Text(message)),
              if (action)
                PresentationScope.of(context).isTv
                    ? TvAction(onPressed: enter, child: Text(l.serversEnter))
                    : AppButton(onPressed: enter, child: Text(l.serversEnter)),
            ],
          ),
        ],
      ),
    );
  }

  /// 手机聚合：分段与每台服务器的海报行，失败只影响当前行。
  Widget _phoneBuild(
    BuildContext context,
    ServerSectionsLoader? loader,
    List<ServerSections> servers,
    List<ServerSections> rows,
  ) {
    final l = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.xs,
            AppSpacing.xs,
            AppSpacing.xs,
          ),
          child: Row(
            children: [
              Expanded(child: _phoneSegments(l)),
              const SizedBox(width: AppSpacing.xxs),
              AppIconButton(
                key: const Key('aggregation-source-management'),
                tooltip: l.serversTitle,
                minimumSize: const Size(48, 48),
                onPressed: () =>
                    showServerSelection(context, auth: AuthScope.of(context)),
                icon: const Icon(CupertinoIcons.slider_horizontal_3),
              ),
            ],
          ),
        ),
        Expanded(child: _phoneBody(context, loader, servers, rows)),
      ],
    );
  }

  Widget _phoneSegments(AppLocalizations l) {
    final scheme = AppUiTheme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.65),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(3),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              _phoneSegmentButton(
                l.resumePlay,
                'aggregation-segment-continue',
                _AggregationSegment.continueWatching,
              ),
              _phoneSegmentButton(
                l.filterFavorite,
                'aggregation-segment-favorites',
                _AggregationSegment.favorites,
              ),
              _phoneSegmentButton(
                l.libraries,
                'aggregation-segment-libraries',
                _AggregationSegment.libraries,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _phoneSegmentButton(
    String label,
    String keyName,
    _AggregationSegment value,
  ) {
    final selected = _segment == value;
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    return AppButton(
      key: Key(keyName),
      onPressed: () => setState(() => _segment = value),
      style: AppButtonStyle(
        foregroundColor: selected
            ? scheme.onPrimaryContainer
            : scheme.onSurfaceVariant,
        backgroundColor: selected
            ? scheme.primaryContainer
            : const Color(0x00000000),
        side: selected
            ? BorderSide(color: scheme.primary.withValues(alpha: 0.35))
            : null,
        textStyle: theme.textTheme.labelLarge?.copyWith(
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        minimumSize: const Size(48, 48),
        shape: const StadiumBorder(),
      ),
      variant: AppButtonVariant.plain,
      child: Text(label, maxLines: 1),
    );
  }

  Widget _phoneBody(
    BuildContext context,
    ServerSectionsLoader? loader,
    List<ServerSections> servers,
    List<ServerSections> rows,
  ) {
    final l = AppLocalizations.of(context);
    final bottom = _phoneScrollBottom(context);
    if (loader == null || (loader.loading && servers.isEmpty)) {
      return ListView(
        padding: EdgeInsets.fromLTRB(
          AppSpacing.md,
          AppSpacing.sm,
          AppSpacing.md,
          bottom,
        ),
        children: const [
          SkeletonBlock(width: 112, height: 20),
          SizedBox(height: AppSpacing.sm),
          MobileLoadingPlaceholder.row(),
        ],
      );
    }
    if (servers.isEmpty) {
      return _PhoneNotice(
        message: '没有已登录的服务器',
        icon: AppIcons.library,
        actionLabel: l.addServer,
        onAction: () => context.push('${AppRoutes.connect}?add=1'),
      );
    }
    if (rows.isEmpty) {
      return _PhoneNotice(message: l.aggregationEmpty, icon: AppIcons.movie);
    }
    final captioned = _segment == _AggregationSegment.continueWatching;
    final libraries = _segment == _AggregationSegment.libraries;
    final indices = {for (var i = 0; i < rows.length; i++) rows[i].serverId: i};
    return MediaImageScrollListener(
      key: const PageStorageKey('aggregation'),
      child: ListView.builder(
        key: PageStorageKey('aggregation-$_segment'),
        scrollCacheExtent: const ScrollCacheExtent.viewport(0.5),
        padding: EdgeInsets.only(bottom: bottom),
        itemCount: rows.length,
        findChildIndexCallback: (key) =>
            indices[(key as ValueKey<String>).value],
        itemBuilder: (context, index) {
          final section = rows[index];
          final slice = _slice(section);
          if (section.locked ||
              section.needsLogin ||
              (!slice.loading && slice.error == null && slice.items.isEmpty)) {
            return _serverPlaceholder(context, section);
          }
          return KeyedSubtree(
            key: ValueKey(section.serverId),
            child: scopeServerPosters(
              account: section.account,
              serverId: section.serverId,
              child: _phoneServerSection(
                context,
                loader,
                section,
                slice,
                captioned: captioned,
                libraries: libraries,
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _phoneServerSection(
    BuildContext context,
    ServerSectionsLoader loader,
    ServerSections section,
    ServerSectionSlice slice, {
    required bool captioned,
    required bool libraries,
  }) {
    final l = AppLocalizations.of(context);
    if (section.locked ||
        section.needsLogin ||
        (!slice.loading && slice.error == null && slice.items.isEmpty)) {
      return _serverPlaceholder(context, section);
    }
    final failed = slice.error != null && slice.items.isEmpty && !slice.loading;
    return Padding(
      key: ValueKey('aggregation-server-${section.serverId}'),
      padding: const EdgeInsets.only(top: AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: PhoneSectionHeader(
              title: section.serverName,
              onMore: !libraries && slice.items.isNotEmpty
                  ? () => context.push(_moreLocation(section.serverId))
                  : null,
            ),
          ),
          if (slice.loading && slice.items.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
              child: MobileLoadingPlaceholder.row(wide: libraries),
            ),
          if (failed)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
              child: _PhoneSectionFailure(
                message: catalogFailureMessage(l, slice.error!),
                onRetry: () => loader.retry(section.serverId),
              ),
            ),
          if (slice.error != null && slice.items.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.md,
                0,
                AppSpacing.md,
                AppSpacing.sm,
              ),
              child: _PhoneSectionFailure(
                message: catalogFailureMessage(l, slice.error!),
                onRetry: () => loader.retry(section.serverId),
              ),
            ),
          if (slice.items.isNotEmpty)
            SizedBox(
              height: libraries
                  ? _phoneLibraryRailHeight(context)
                  : phoneHomeRailHeight(context, wide: false),
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                itemCount: slice.items.length,
                itemBuilder: (context, index) {
                  final item = slice.items[index];
                  if (libraries) {
                    return _phoneLibraryCard(context, section, item);
                  }
                  return PhonePosterCard(
                    item: item,
                    width: phoneHomePosterCardWidth(
                      MediaQuery.sizeOf(context).width,
                    ),
                    hero: false,
                    onTap: () => _open(section, item),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  double _phoneLibraryRailHeight(BuildContext context) {
    final width = phoneHomeLibraryCardWidth(MediaQuery.sizeOf(context).width);
    final scaler = MediaQuery.textScalerOf(context);
    final fontSize =
        AppUiTheme.of(context).textTheme.bodyMedium?.fontSize ?? 14;
    final title = scaler.scale(fontSize) * 1.25;
    return width * 9 / 16 + 8 + title + 6;
  }

  /// 媒体库主图保持 16:9,封面不改走背景图。
  Widget _phoneLibraryCard(
    BuildContext context,
    ServerSections section,
    MediaItem item,
  ) {
    final width = phoneHomeLibraryCardWidth(MediaQuery.sizeOf(context).width);
    final height = width * 9 / 16;
    return Padding(
      padding: const EdgeInsets.only(right: AppSpacing.sm),
      child: SizedBox(
        width: width,
        child: MobilePressable(
          onTap: () => _open(section, item),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: width,
                height: height,
                child: PhoneArtworkFrame(
                  radius: 12,
                  child: MediaImage(
                    item: item,
                    width: width,
                    height: height,
                    preferBackdrop: false,
                    maxWidth: 480,
                    fit: BoxFit.cover,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                item.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: phonePosterTitleStyle(AppUiTheme.of(context)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 电视:分段胶囊在顶,下面每台服务器一行卡片;分段随内容一起滚走,
  /// 顶部导航收起后整屏都是内容。
  Widget _tvBuild(
    BuildContext context,
    ServerSectionsLoader? loader,
    List<ServerSections> servers,
    List<ServerSections> rows,
  ) {
    final l = AppLocalizations.of(context);
    final s = TvDesign.scaleOf(context);
    final size = MediaQuery.sizeOf(context);
    final gutter = tvSafeGutter(size.width);
    Widget segment(
      String label,
      String key,
      _AggregationSegment value,
      IconData icon, {
      double? fill,
    }) => TvAction(
      key: Key(key),
      pill: true,
      selected: _segment == value,
      leading: Icon(icon, fill: fill),
      onPressed: () => setState(() => _segment = value),
      child: Text(label),
    );
    final header = Padding(
      padding: EdgeInsets.fromLTRB(
        gutter,
        TvTopNavBar.reserveOf(context) + 4 * s,
        gutter,
        4 * s,
      ),
      child: Wrap(
        spacing: 8 * s,
        runSpacing: 8 * s,
        children: [
          segment(
            l.resumePlay,
            'aggregation-segment-continue',
            _AggregationSegment.continueWatching,
            CupertinoIcons.clock,
          ),
          segment(
            l.filterFavorite,
            'aggregation-segment-favorites',
            _AggregationSegment.favorites,
            AppIcons.favorite,
            fill: _segment == _AggregationSegment.favorites
                ? AppIcons.filled
                : AppIcons.outline,
          ),
          segment(
            l.libraries,
            'aggregation-segment-libraries',
            _AggregationSegment.libraries,
            AppIcons.library,
            fill: _segment == _AggregationSegment.libraries
                ? AppIcons.filled
                : AppIcons.outline,
          ),
        ],
      ),
    );
    final Widget body;
    if (loader == null || (loader.loading && servers.isEmpty)) {
      body = SizedBox(
        height: 260 * s,
        child: const Center(child: CupertinoActivityIndicator()),
      );
    } else if (servers.isEmpty) {
      body = SizedBox(
        height: 300 * s,
        child: TvEmptyState(
          icon: AppIcons.library,
          message: '没有已登录的服务器',
          action: TvAction(
            emphasized: true,
            onPressed: () => context.push('${AppRoutes.connect}?add=1'),
            child: Text(l.addServer),
          ),
        ),
      );
    } else if (rows.isEmpty) {
      body = SizedBox(
        height: 300 * s,
        child: TvEmptyState(message: l.aggregationEmpty),
      );
    } else {
      final captioned = _segment == _AggregationSegment.continueWatching;
      final libraries = _segment == _AggregationSegment.libraries;
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final section in rows)
            _tvRow(context, loader, section, captioned, libraries),
        ],
      );
    }
    return Container(
      decoration: BoxDecoration(),
      child: MediaImageScrollListener(
        child: ListView(
          key: PageStorageKey('aggregation-$_segment'),
          padding: EdgeInsets.only(bottom: tvSafeVertical(size.height)),
          children: [header, body],
        ),
      ),
    );
  }

  Widget _tvRow(
    BuildContext context,
    ServerSectionsLoader loader,
    ServerSections section,
    bool captioned,
    bool libraries,
  ) {
    final s = TvDesign.scaleOf(context);
    final gutter = tvSafeGutter(MediaQuery.sizeOf(context).width);
    final slice = _slice(section);
    if (section.locked ||
        section.needsLogin ||
        (!slice.loading && slice.error == null && slice.items.isEmpty)) {
      return _serverPlaceholder(context, section);
    }

    return Column(
      key: ValueKey('aggregation-server-${section.serverId}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TvSectionTitle(
          section.serverName,
          padding: EdgeInsets.fromLTRB(gutter, 14 * s, gutter, 0),
        ),
        if (slice.loading && slice.items.isEmpty)
          TvRowSkeleton(wide: captioned || libraries),
        if (slice.error != null)
          Padding(
            padding: EdgeInsets.symmetric(horizontal: gutter),
            child: TvFailure(
              error: slice.error!,
              retry: () => loader.retry(section.serverId),
            ),
          ),
        if (slice.items.isNotEmpty)
          scopeServerPosters(
            account: section.account,
            serverId: section.serverId,
            child: TvItemRow(
              title: 'aggregation-${section.serverId}-$_segment',
              items: slice.items,
              wide: captioned || libraries,
              subtitle: libraries ? false : null,
              width: libraries ? 184 * s : null,
              onPressed: (item) => _open(section, item),
              cardBuilder: libraries
                  ? (context, item, node, metrics) => TvCard(
                      item: item,
                      wide: true,
                      focusNode: node,
                      imageWidth: metrics.width,
                      preferBackdrop: false,
                      imageMaxWidth: metrics.imageMaxWidth,
                      onPressed: () => _open(section, item),
                    )
                  : null,
              trailing: !libraries && slice.items.isNotEmpty
                  ? (context, metrics) => TvMoreTile(
                      metrics: metrics,
                      onPressed: () =>
                          context.push(_moreLocation(section.serverId)),
                    )
                  : null,
            ),
          ),
      ],
    );
  }

  /// 媒体库主图是横版拼图，按 16:9 横幅排，不走竖版海报。
  double _libraryExtent(BuildContext context) {
    final screen = MediaQuery.sizeOf(context).width;
    final image = MediaShelf.wideCardWidthFor(screen) * 9 / 16;
    final labels = MediaShelf.posterLabelExtentFor(context);
    return ((image + labels) * MediaShelf.hoverScale).ceilToDouble();
  }

  Widget _libraryCard(
    BuildContext context,
    ServerSections section,
    MediaItem item,
  ) {
    final width = MediaShelf.wideCardWidthFor(MediaQuery.sizeOf(context).width);
    return PosterCard(
      item: item,
      wide: true,
      preferBackdrop: false,
      width: width,
      onTap: () => _open(section, item),
    );
  }
}

class _SearchHit {
  const _SearchHit({
    required this.serverId,
    required this.serverName,
    this.account,
    this.permit,
    this.items = const [],
    this.error,
    this.loading = false,
  });

  final String serverId;
  final String serverName;
  final SourceAccount? account;
  final OperationPermit? permit;
  final List<MediaItem> items;
  final MediaServerException? error;
  final bool loading;

  _SearchHit copyWith({
    SourceAccount? account,
    List<MediaItem>? items,
    MediaServerException? error,
    bool clearError = false,
    bool? loading,
  }) {
    return _SearchHit(
      serverId: serverId,
      serverName: serverName,
      account: account ?? this.account,
      permit: permit,
      items: items ?? this.items,
      error: clearError ? null : error ?? this.error,
      loading: loading ?? this.loading,
    );
  }
}

class _AggregationSearch extends StatefulWidget {
  const _AggregationSearch({
    this.focusNode,
    this.clearOfDesktopBar = true,
    this.onClose,
  });

  final FocusNode? focusNode;
  final bool clearOfDesktopBar;
  final VoidCallback? onClose;

  @override
  State<_AggregationSearch> createState() => _AggregationSearchState();
}

class _AggregationSearchState extends State<_AggregationSearch> {
  final _keyword = TextEditingController();
  AuthController? _auth;
  List<_SearchHit> _rows = const [];
  String _term = '';
  bool _searching = false;
  bool _filtersOpen = false;

  /// 边输入边搜：停顿片刻后自动查询，回车/搜索键立即查询。
  static const _typingPause = Duration(milliseconds: 450);
  Timer? _typing;
  String _typed = '';

  @override
  void initState() {
    super.initState();
    _keyword.addListener(_keywordChanged);
  }

  void _keywordChanged() {
    final value = _keyword.value;
    // 拼音输入法组字期间的字母不是要搜的词。
    if (value.composing.isValid && !value.composing.isCollapsed) return;
    final term = value.text.trim();
    // 光标移动也会通知，只在文字变化时重新计时。
    if (term == _typed) return;
    _typed = term;
    _typing?.cancel();
    if (term.isEmpty) {
      unawaited(_submit());
      return;
    }
    _typing = Timer(_typingPause, () {
      if (mounted && term != _term) unawaited(_submit());
    });
  }

  /// null 表示全部已登录服务器。收起筛选时仍沿用这里的选择。
  Set<String>? _servers;
  int _generation = 0;
  final Map<String, int> _attempt = {};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final auth = AuthScope.of(context);
    if (!identical(_auth, auth)) {
      _auth?.removeListener(_serversChanged);
      _auth = auth..addListener(_serversChanged);
    }
  }

  void _serversChanged() {
    if (_term.isEmpty || !mounted) return;
    final ids = AuthScope.of(context).sources
        .project()
        .where((server) => _auth!.serverAccess.allows(server.id))
        .map((server) => server.id)
        .toSet();
    final next = [
      for (final row in _rows)
        if (ids.contains(row.serverId) && row.permit?.isValid != false) row,
    ];
    if (next.length == _rows.length) return;
    setState(() => _rows = next);
  }

  @override
  void dispose() {
    _auth?.removeListener(_serversChanged);
    _typing?.cancel();
    _keyword.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    _typing?.cancel();
    final term = _keyword.text.trim();
    _typed = term;
    if (term.isEmpty) {
      setState(() {
        _term = '';
        _rows = const [];
        _searching = false;
        _generation++;
      });
      return;
    }
    await _run(term);
  }

  Future<void> _run(String term) async {
    final generation = ++_generation;
    final registry = AuthScope.of(context).sources;
    await registry.load();
    if (!mounted || generation != _generation) return;
    final targets = [
      for (final server in registry.project())
        if (registry.access.allows(server.id) &&
            (_servers == null || _servers!.contains(server.id)))
          server,
    ];
    _attempt
      ..clear()
      ..addEntries(targets.map((server) => MapEntry(server.id, 0)));
    setState(() {
      _term = term;
      _searching = true;
      _rows = const [];
    });
    await Future.wait(
      targets.map((server) => _publish(server, term, generation, 0)),
    );
    if (!mounted || generation != _generation) return;
    setState(() => _searching = false);
  }

  Future<void> _retry(String serverId) async {
    final term = _term;
    if (term.isEmpty) return;
    final generation = _generation;
    final server = AuthScope.of(context).sources
        .project()
        .where((item) => item.id == serverId)
        .firstOrNull;
    if (server == null) return;
    final attempt = (_attempt[serverId] ?? 0) + 1;
    _attempt[serverId] = attempt;
    setState(() {
      _rows = [
        for (final row in _rows)
          if (row.serverId == serverId)
            row.copyWith(loading: true, clearError: true)
          else
            row,
      ];
    });
    await _publish(server, term, generation, attempt);
  }

  Future<void> _publish(
    SavedServer server,
    String term,
    int generation,
    int attempt,
  ) async {
    final access = AuthScope.of(context).serverAccess;
    final accessGeneration = access.generation(server.id);
    final hit = await _query(server, term);
    if (!mounted ||
        !access.allows(server.id) ||
        access.generation(server.id) != accessGeneration ||
        hit?.permit?.isValid == false ||
        generation != _generation ||
        _attempt[server.id] != attempt) {
      return;
    }
    final next = [
      for (final row in _rows)
        if (row.serverId != server.id) row,
    ];
    if (hit != null) next.add(hit);
    final order = AuthScope.of(context).sources
        .project()
        .map((item) => item.id)
        .toList();
    final byId = {for (final row in next) row.serverId: row};
    setState(() {
      _rows = [
        for (final id in order)
          if (byId.containsKey(id)) byId[id]!,
      ];
    });
  }

  Future<_SearchHit?> _query(SavedServer server, String term) async {
    final registry = AuthScope.of(context).sources;
    try {
      final session = await registry.authenticate(server.id);
      final permit = registry.permit(session.account);
      final page = await permit.dispatch(
        (client) => client.queryItems(
          searchTerm: term,
          includeItemTypes: 'Movie,Series',
          recursive: true,
          limit: aggregationRowLimit,
          fields: MediaServerClient.gridFields,
        ),
      );
      final items = [
        for (final item in page.items)
          if (item.isMovieOrSeries) item,
      ];
      if (items.isEmpty) return null;
      return _SearchHit(
        serverId: server.id,
        serverName: server.displayName,
        account: session.account,
        permit: permit,
        items: items,
      );
    } on StateError catch (error) {
      if (error.message == 'Login required') return null;
      return _SearchHit(
        serverId: server.id,
        serverName: server.displayName,
        error: MediaServerException(
          MediaServerFailureKind.unknown,
          cause: error,
        ),
      );
    } catch (error) {
      return _SearchHit(
        serverId: server.id,
        serverName: server.displayName,
        error: error is MediaServerException
            ? error
            : MediaServerException(
                MediaServerFailureKind.unknown,
                cause: error,
              ),
      );
    }
  }

  void _toggleServer(List<SavedServer> servers, String id, bool selected) {
    final all = servers.map((server) => server.id).toSet();
    final next = {..._servers ?? all};
    if (selected) {
      next.add(id);
    } else {
      next.remove(id);
    }
    setState(() => _servers = next.containsAll(all) ? null : next);
    if (_term.isNotEmpty) unawaited(_run(_term));
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final presentation = PresentationScope.of(context);
    final servers = AuthScope.of(context).sources.project();
    final visible = [
      for (final row in _rows)
        if (row.items.isNotEmpty || row.error != null || row.loading) row,
    ];
    if (presentation.isTv) return _tvBuild(context, servers, visible);
    if (!presentation.isDesktop) {
      return _phoneSearchBuild(context, servers, visible);
    }
    final field = presentation.isTv
        ? TvInput(
            key: const Key('aggregation-keyword'),
            autofocus: true,
            label: l.searchHint,
            controller: _keyword,
            onSubmitted: _submit,
          )
        : AppTextField(
            key: const Key('aggregation-keyword'),
            focusNode: widget.focusNode,
            controller: _keyword,
            autofocus: widget.focusNode == null,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) {
              unawaited(RecentSearches.instance.add(_keyword.text));
              _submit();
            },
            placeholder: l.searchHint,
            prefix: const Icon(AppIcons.search, fill: AppIcons.filled),
            suffix: ValueListenableBuilder<TextEditingValue>(
              valueListenable: _keyword,
              builder: (context, value, _) {
                if (_searching && value.text.isNotEmpty) {
                  return const Padding(
                    padding: EdgeInsets.all(15),
                    child: SizedBox.square(
                      dimension: 18,
                      child: CupertinoActivityIndicator(),
                    ),
                  );
                }
                if (value.text.isEmpty) return const SizedBox.shrink();
                return AppIconButton(
                  key: const Key('aggregation-search-clear'),
                  tooltip: '删除',
                  onPressed: () {
                    _keyword.clear();
                    _submit();
                    widget.focusNode?.requestFocus();
                  },
                  icon: const Icon(AppIcons.close, fill: AppIcons.filled),
                );
              },
            ),
          );
    final showBackButton =
        !presentation.isDesktop &&
        (presentation.isTv ||
            ((ModalRoute.of(context)?.canPop ?? false) &&
                context.findAncestorWidgetOfExactType<SearchRouteGuard>() ==
                    null));
    final phoneTop = PhoneShellContentInset.clearedOf(context)
        ? 8.0
        : MediaQuery.viewPaddingOf(context).top + 8;
    // 桌面覆盖层盖住顶栏:搜索行与标题按钮带同一条中线,两侧让开窗口铬。
    final hasChrome =
        context.findAncestorWidgetOfExactType<WindowChromeHost>() != null;
    final chromeLeading = hasChrome ? windowChromeLeadingInset() : 0.0;
    final chromeTrailing = hasChrome ? windowChromeTrailingInset() : 0.0;
    final inPlace = presentation.isDesktop && !widget.clearOfDesktopBar;
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    final searchRow = Row(
      children: [
        if (showBackButton)
          CupertinoNavigationBarBackButton(onPressed: () => context.pop()),
        Expanded(
          child: Align(
            alignment: inPlace ? Alignment.center : Alignment.centerLeft,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: inPlace ? 720 : double.infinity,
              ),
              child: field,
            ),
          ),
        ),
        if (servers.isNotEmpty) ...[
          const SizedBox(width: AppSpacing.xxs),
          AppIconButton(
            key: const Key('aggregation-search-filters'),
            tooltip: l.searchServerFilter,
            selected: _filtersOpen,
            onPressed: () => setState(() => _filtersOpen = !_filtersOpen),
            icon: Icon(
              AppIcons.filter,
              fill: _filtersOpen || _servers != null
                  ? AppIcons.filled
                  : AppIcons.outline,
              color: _servers == null ? null : scheme.primary,
            ),
          ),
        ],
        if (widget.onClose != null)
          AppIconButton(
            key: SearchOverlay.closeKey,
            tooltip: '关闭',
            onPressed: widget.onClose,
            icon: const Icon(AppIcons.close, fill: AppIcons.filled),
          ),
      ],
    );
    return Container(
      decoration: BoxDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(
              presentation.isDesktop ? AppSpacing.page + chromeLeading : 16,
              presentation.isDesktop
                  ? (widget.clearOfDesktopBar ? 64 : AppSpacing.xs)
                  : phoneTop,
              presentation.isDesktop ? AppSpacing.md + chromeTrailing : 16,
              6,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                searchRow,
                if (_filtersOpen)
                  Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.sm),
                    child: Row(
                      children: [
                        Text(
                          l.searchServerFilter,
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final server in servers)
                                OptionPill(
                                  key: ValueKey(
                                    'aggregation-search-server-${server.id}',
                                  ),
                                  label: server.displayName,
                                  selected:
                                      _servers == null ||
                                      _servers!.contains(server.id),
                                  onPressed: () {
                                    final selected =
                                        _servers == null ||
                                        _servers!.contains(server.id);
                                    _toggleServer(
                                      servers,
                                      server.id,
                                      !selected,
                                    );
                                  },
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          if (inPlace)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xs),
              child: AppDivider(
                height: 1,
                color: scheme.outlineVariant.withValues(alpha: 0.6),
              ),
            ),
          Expanded(child: _results(context, visible)),
        ],
      ),
    );
  }

  Widget _phoneSearchBuild(
    BuildContext context,
    List<SavedServer> servers,
    List<_SearchHit> visible,
  ) {
    final l = AppLocalizations.of(context);
    final phoneTop = PhoneShellContentInset.clearedOf(context)
        ? 8.0
        : MediaQuery.viewPaddingOf(context).top + 8;
    final showBackButton =
        (ModalRoute.of(context)?.canPop ?? false) &&
        context.findAncestorWidgetOfExactType<SearchRouteGuard>() == null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(16, phoneTop, 8, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (showBackButton)
                    CupertinoNavigationBarBackButton(
                      onPressed: () => context.pop(),
                    ),
                  Expanded(child: _phoneSearchField(l)),
                  if (servers.isNotEmpty) ...[
                    const SizedBox(width: AppSpacing.xxs),
                    AppIconButton(
                      key: const Key('aggregation-search-filters'),
                      tooltip: l.searchServerFilter,
                      minimumSize: const Size(48, 48),
                      onPressed: () =>
                          setState(() => _filtersOpen = !_filtersOpen),
                      icon: Icon(
                        AppIcons.filter,
                        fill: _filtersOpen || _servers != null
                            ? AppIcons.filled
                            : AppIcons.outline,
                        color: _servers == null
                            ? null
                            : AppUiTheme.of(context).colorScheme.primary,
                      ),
                    ),
                  ],
                  if (widget.onClose != null)
                    AppIconButton(
                      key: SearchOverlay.closeKey,
                      tooltip: '关闭',
                      minimumSize: const Size(48, 48),
                      onPressed: widget.onClose,
                      icon: const Icon(AppIcons.close, fill: AppIcons.filled),
                    ),
                ],
              ),
              if (_filtersOpen)
                Padding(
                  padding: const EdgeInsets.only(top: 8, right: 8),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final server in servers)
                        OptionPill(
                          key: ValueKey(
                            'aggregation-search-server-${server.id}',
                          ),
                          label: server.displayName,
                          selected:
                              _servers == null || _servers!.contains(server.id),
                          onPressed: () {
                            final selected =
                                _servers == null ||
                                _servers!.contains(server.id);
                            _toggleServer(servers, server.id, !selected);
                          },
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        Expanded(child: _phoneSearchBody(context, visible)),
      ],
    );
  }

  Widget _phoneSearchField(AppLocalizations l) {
    return AppTextField(
      key: const Key('aggregation-keyword'),
      focusNode: widget.focusNode,
      controller: _keyword,
      autofocus: widget.focusNode == null,
      textInputAction: TextInputAction.search,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      onSubmitted: (_) {
        unawaited(RecentSearches.instance.add(_keyword.text));
        _submit();
      },
      placeholder: l.searchHint,
      prefix: const Icon(AppIcons.search, fill: AppIcons.filled),
      suffix: ValueListenableBuilder<TextEditingValue>(
        valueListenable: _keyword,
        builder: (context, value, _) {
          if (_searching && value.text.isNotEmpty) {
            return const Padding(
              padding: EdgeInsets.all(15),
              child: SizedBox.square(
                dimension: 18,
                child: CupertinoActivityIndicator(),
              ),
            );
          }
          if (value.text.isEmpty) return const SizedBox.shrink();
          return AppIconButton(
            key: const Key('aggregation-search-clear'),
            tooltip: '删除',
            minimumSize: const Size(48, 48),
            onPressed: () {
              _keyword.clear();
              _submit();
              widget.focusNode?.requestFocus();
            },
            icon: const Icon(AppIcons.close, fill: AppIcons.filled),
          );
        },
      ),
    );
  }

  Widget _phoneSearchBody(BuildContext context, List<_SearchHit> visible) {
    final l = AppLocalizations.of(context);
    if (_term.isEmpty) {
      return _PhoneSearchIdle(onPick: _searchRecent);
    }
    if (_searching && visible.isEmpty) {
      return ListView(
        padding: EdgeInsets.fromLTRB(
          AppSpacing.md,
          AppSpacing.xs,
          AppSpacing.md,
          _phoneScrollBottom(context),
        ),
        children: const [
          SkeletonBlock(width: 128, height: 20),
          SizedBox(height: AppSpacing.sm),
          _PhonePosterGridSkeleton(),
        ],
      );
    }
    if (visible.isEmpty) {
      return _PhoneNotice(message: l.searchNoResults, icon: AppIcons.search);
    }
    return _phoneResults(context, visible);
  }

  /// 手机搜索结果:每个服务器一段,标题带结果数,下面是海报网格。
  Widget _phoneResults(BuildContext context, List<_SearchHit> visible) {
    final l = AppLocalizations.of(context);
    final failed = visible.where((row) => row.error != null).length;
    return MediaImageScrollListener(
      child: ListView(
        key: const PageStorageKey('aggregation-search'),
        padding: EdgeInsets.fromLTRB(
          AppSpacing.md,
          AppSpacing.xs,
          AppSpacing.md,
          _phoneScrollBottom(context),
        ),
        children: [
          if (failed > 0 && failed < visible.length)
            _PhoneStatusNote(message: l.aggregationPartialFailure),
          if (failed == visible.length && visible.isNotEmpty)
            _PhoneStatusNote(message: l.aggregationAllFailed),
          for (final row in visible)
            Padding(
              key: ValueKey('aggregation-search-${row.serverId}'),
              padding: const EdgeInsets.only(bottom: AppSpacing.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  PhoneSectionHeader(
                    title: row.serverName,
                    subtitle: row.items.isEmpty
                        ? null
                        : l.phoneSearchResultCount(row.items.length),
                  ),
                  if (row.loading && row.items.isEmpty)
                    const _PhonePosterGridSkeleton(count: 2),
                  if (row.error != null)
                    _PhoneSectionFailure(
                      message: catalogFailureMessage(l, row.error!),
                      onRetry: () => _retry(row.serverId),
                    ),
                  if (row.items.isNotEmpty)
                    scopeServerPosters(
                      account: row.account,
                      serverId: row.serverId,
                      child: MobileGrid(
                        items: row.items,
                        itemBuilder: (context, item) => PhonePosterCard(
                          key: CatalogKeys.item(item.id),
                          item: item,
                          onTap: () {
                            final account = row.account;
                            if (account == null) return;
                            unawaited(RecentSearches.instance.add(_term));
                            openServerItem(
                              context,
                              account: account,
                              item: item,
                            );
                          },
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// 电视搜索:胶囊搜索框 + 来源筛选,结果按服务器分行。
  Widget _tvBuild(
    BuildContext context,
    List<SavedServer> servers,
    List<_SearchHit> visible,
  ) {
    final l = AppLocalizations.of(context);
    final s = TvDesign.scaleOf(context);
    final size = MediaQuery.sizeOf(context);
    final gutter = tvSafeGutter(size.width);
    final failed = visible.where((row) => row.error != null).length;
    bool chosen(String id) => _servers == null || _servers!.contains(id);
    final header = Padding(
      padding: EdgeInsets.fromLTRB(
        gutter,
        TvTopNavBar.reserveOf(context) + 4 * s,
        gutter,
        4 * s,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: TvInput(
                  key: const Key('aggregation-keyword'),
                  autofocus: true,
                  pill: true,
                  leading: const Icon(AppIcons.search, fill: AppIcons.filled),
                  label: l.searchHint,
                  controller: _keyword,
                  onSubmitted: _submit,
                ),
              ),
              if (servers.isNotEmpty) ...[
                SizedBox(width: 10 * s),
                TvAction(
                  key: const Key('aggregation-search-filters'),
                  pill: true,
                  selected: _filtersOpen || _servers != null,
                  leading: Icon(
                    AppIcons.filter,
                    fill: _filtersOpen || _servers != null
                        ? AppIcons.filled
                        : AppIcons.outline,
                  ),
                  onPressed: () => setState(() => _filtersOpen = !_filtersOpen),
                  child: Text(l.searchServerFilter),
                ),
              ],
            ],
          ),
          if (_filtersOpen) ...[
            SizedBox(height: 10 * s),
            Wrap(
              spacing: 8 * s,
              runSpacing: 8 * s,
              children: [
                for (final server in servers)
                  TvAction(
                    key: ValueKey('aggregation-search-server-${server.id}'),
                    pill: true,
                    selected: chosen(server.id),
                    leading: Icon(
                      chosen(server.id)
                          ? CupertinoIcons.check_mark
                          : CupertinoIcons.plus,
                    ),
                    onPressed: () =>
                        _toggleServer(servers, server.id, !chosen(server.id)),
                    child: Text(server.displayName),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
    final Widget body;
    if (_term.isEmpty) {
      body = SizedBox(
        height: 280 * s,
        child: TvEmptyState(icon: AppIcons.search, message: l.searchEmptyQuery),
      );
    } else if (_searching && visible.isEmpty) {
      body = SizedBox(
        height: 260 * s,
        child: const Center(child: CupertinoActivityIndicator()),
      );
    } else if (visible.isEmpty) {
      body = SizedBox(
        height: 280 * s,
        child: TvEmptyState(icon: AppIcons.search, message: l.searchNoResults),
      );
    } else {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (failed > 0)
            Padding(
              padding: EdgeInsets.fromLTRB(gutter, 8 * s, gutter, 0),
              child: Text(
                failed == visible.length
                    ? l.aggregationAllFailed
                    : l.aggregationPartialFailure,
                style: TextStyle(
                  color: AppUiTheme.of(context).colorScheme.error,
                ),
              ),
            ),
          for (final row in visible)
            Column(
              key: ValueKey('aggregation-search-${row.serverId}'),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TvSectionTitle(
                  row.serverName,
                  trailing: row.items.isEmpty
                      ? null
                      : Text(
                          '${row.items.length}',
                          style: AppUiTheme.of(context).textTheme.labelMedium
                              ?.copyWith(
                                color: AppUiTheme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                        ),
                  padding: EdgeInsets.fromLTRB(gutter, 14 * s, gutter, 0),
                ),
                if (row.loading && row.items.isEmpty) const TvRowSkeleton(),
                if (row.error != null)
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: gutter),
                    child: TvFailure(
                      error: row.error!,
                      retry: () => _retry(row.serverId),
                    ),
                  ),
                if (row.items.isNotEmpty)
                  scopeServerPosters(
                    account: row.account,
                    serverId: row.serverId,
                    child: TvItemRow(
                      title: 'aggregation-search-${row.serverId}',
                      items: row.items,
                      onPressed: (item) {
                        final account = row.account;
                        if (account == null) return;
                        openServerItem(context, account: account, item: item);
                      },
                    ),
                  ),
              ],
            ),
        ],
      );
    }
    return Container(
      decoration: BoxDecoration(),
      child: ListView(
        key: const PageStorageKey('aggregation-search'),
        padding: EdgeInsets.only(bottom: tvSafeVertical(size.height)),
        children: [header, body],
      ),
    );
  }

  /// 从最近搜索里点一个词:填进输入框并立即查询。
  void _searchRecent(String term) {
    _keyword.value = TextEditingValue(
      text: term,
      selection: TextSelection.collapsed(offset: term.length),
    );
    unawaited(RecentSearches.instance.add(term));
    unawaited(_submit());
  }

  Widget _results(BuildContext context, List<_SearchHit> visible) {
    final l = AppLocalizations.of(context);
    if (_term.isEmpty) {
      return _PhoneSearchIdle(onPick: _searchRecent, desktop: true);
    }
    if (_searching && visible.isEmpty) {
      return const Center(child: CupertinoActivityIndicator());
    }
    if (visible.isEmpty) {
      return AppEmptyView(icon: AppIcons.search, message: l.searchNoResults);
    }
    final failed = visible.where((row) => row.error != null).length;
    final total = visible.fold<int>(0, (sum, row) => sum + row.items.length);
    final theme = AppUiTheme.of(context);
    return ListView(
      key: const PageStorageKey('aggregation-search'),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.page,
            AppSpacing.lg,
            AppSpacing.page,
            AppSpacing.xxs,
          ),
          child: Row(
            children: [
              Icon(
                AppIcons.search,
                size: 16,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: AppSpacing.xs),
              Flexible(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: _term, style: theme.textTheme.titleSmall),
                      if (total > 0)
                        TextSpan(
                          text: '  ·  ${l.phoneSearchResultCount(total)}',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        if (failed > 0 && failed < visible.length)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(l.aggregationPartialFailure),
          ),
        if (failed == visible.length && visible.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(l.aggregationAllFailed),
          ),
        for (final row in visible)
          scopeServerPosters(
            account: row.account,
            serverId: row.serverId,
            child: MediaShelf(
              key: ValueKey('aggregation-search-${row.serverId}'),
              shelfId: 'aggregation-search-${row.serverId}',
              title: row.serverName,
              items: row.items,
              loading: row.loading,
              error: row.error,
              onRetry: row.error == null ? null : () => _retry(row.serverId),
              onTap: (item) {
                final account = row.account;
                if (account == null) return;
                unawaited(RecentSearches.instance.add(_term));
                openServerItem(context, account: account, item: item);
              },
            ),
          ),
      ],
    );
  }
}

/// 手机搜索页还没输入时:最近搜索的词(可点、可清除);没有记录时是一段引导。
class _PhoneSearchIdle extends StatefulWidget {
  const _PhoneSearchIdle({required this.onPick, this.desktop = false});

  final ValueChanged<String> onPick;

  /// 桌面搜索覆盖层:与搜索框同宽居中,触控行高收回到鼠标尺寸。
  final bool desktop;

  static const recentKey = Key('phone-search-recent');
  static const clearKey = Key('phone-search-recent-clear');

  @override
  State<_PhoneSearchIdle> createState() => _PhoneSearchIdleState();
}

class _PhoneSearchIdleState extends State<_PhoneSearchIdle> {
  @override
  void initState() {
    super.initState();
    unawaited(RecentSearches.instance.load());
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    return ListenableBuilder(
      listenable: RecentSearches.instance,
      builder: (context, _) {
        final terms = RecentSearches.instance.terms;
        final guide = Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh,
                shape: BoxShape.circle,
              ),
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: Icon(
                  AppIcons.search,
                  fill: AppIcons.filled,
                  size: 28,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              l.phoneSearchIdleTitle,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              l.searchEmptyQuery,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        );
        final desktop = widget.desktop;
        final chipHeight = desktop ? 36.0 : 48.0;
        final list = ListView(
          padding: desktop
              ? const EdgeInsets.fromLTRB(
                  AppSpacing.page,
                  AppSpacing.xl,
                  AppSpacing.page,
                  AppSpacing.xl,
                )
              : const EdgeInsets.fromLTRB(
                  AppSpacing.md,
                  AppSpacing.md,
                  AppSpacing.md,
                  AppSpacing.xl,
                ),
          children: [
            if (terms.isNotEmpty) ...[
              PhoneSectionHeader(
                title: l.phoneSearchRecent,
                trailing: AppButton(
                  key: _PhoneSearchIdle.clearKey,
                  style: AppButtonStyle(
                    minimumSize: Size(chipHeight, chipHeight),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    foregroundColor: scheme.onSurfaceVariant,
                  ),
                  onPressed: () {
                    unawaited(RecentSearches.instance.clear());
                  },
                  variant: AppButtonVariant.plain,
                  child: Text(l.phoneSearchClearRecent),
                ),
              ),
              Wrap(
                key: _PhoneSearchIdle.recentKey,
                spacing: AppSpacing.xs,
                runSpacing: AppSpacing.xs,
                children: [
                  for (final term in terms)
                    Container(
                      key: ValueKey('phone-search-recent-$term'),
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerHigh,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: AppSurfaceAction(
                        onTap: () => widget.onPick(term),
                        child: ConstrainedBox(
                          constraints: BoxConstraints(minHeight: chipHeight),
                          child: Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: desktop ? 8 : 12,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  CupertinoIcons.clock,
                                  size: 14,
                                  color: scheme.onSurfaceVariant,
                                ),
                                const SizedBox(width: 6),
                                ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    maxWidth: 220,
                                  ),
                                  child: Text(
                                    term,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.labelLarge?.copyWith(
                                      color: scheme.onSurface,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              SizedBox(height: desktop ? 72 : 56),
            ] else
              SizedBox(height: desktop ? 120 : 96),
            guide,
          ],
        );
        if (!desktop) return list;
        return Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: 720 + AppSpacing.page * 2,
            ),
            child: list,
          ),
        );
      },
    );
  }
}

/// 贴底导航盖住内容时，滚动到底仍能把最后一个按钮留在导航上方。
double _phoneScrollBottom(BuildContext context) {
  final overlaid = PhoneNavStyle.floatingOf(context)
      ? 0.0
      : AppMobileNav.dockedHeight;
  return AppSpacing.xl + phoneScrollClearance(context) + overlaid;
}

/// 手机聚合和搜索共用的空状态。有下一步时那一颗是实心主按钮。
class _PhoneNotice extends StatelessWidget {
  const _PhoneNotice({
    required this.message,
    required this.icon,
    this.actionLabel,
    this.onAction,
  });

  final String message;
  final IconData icon;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final scheme = AppUiTheme.of(context).colorScheme;
    final action = actionLabel != null && onAction != null
        ? AppButton(
            style: const AppButtonStyle(minimumSize: Size(48, 48)),
            onPressed: onAction,
            variant: AppButtonVariant.filled,
            child: Text(actionLabel!),
          )
        : null;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh,
                shape: BoxShape.circle,
              ),
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: Icon(
                  icon,
                  fill: AppIcons.filled,
                  size: 28,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              message,
              textAlign: TextAlign.center,
              style: AppUiTheme.of(context).textTheme.bodyLarge
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            if (action != null) ...[
              const SizedBox(height: AppSpacing.md),
              action,
            ],
          ],
        ),
      ),
    );
  }
}

/// 部分失败或全部失败的说明，贴在仍保留的结果上面。
class _PhoneStatusNote extends StatelessWidget {
  const _PhoneStatusNote({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = AppUiTheme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.errorContainer,
          borderRadius: BorderRadius.circular(AppRadii.md),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          ),
          child: Row(
            children: [
              Icon(
                AppIcons.error,
                fill: AppIcons.filled,
                size: 18,
                color: scheme.onErrorContainer,
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  message,
                  style: AppUiTheme.of(context).textTheme.bodyMedium
                      ?.copyWith(color: scheme.onErrorContainer),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 单个服务器失败时的说明和重试。重试不小于 48dp。
class _PhoneSectionFailure extends StatelessWidget {
  const _PhoneSectionFailure({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = AppUiTheme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
      child: Column(
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              color: scheme.errorContainer,
              shape: BoxShape.circle,
            ),
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Icon(
                AppIcons.error,
                fill: AppIcons.filled,
                size: 28,
                color: scheme.onErrorContainer,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            message,
            textAlign: TextAlign.center,
            style: AppUiTheme.of(context).textTheme.bodyLarge,
          ),
          const SizedBox(height: AppSpacing.md),
          AppButton(
            style: const AppButtonStyle(minimumSize: Size(48, 48)),
            onPressed: onRetry,
            variant: AppButtonVariant.filled,
            child: Text(AppLocalizations.of(context).retry),
          ),
        ],
      ),
    );
  }
}

/// 搜索海报网格的加载骨架，单元格比例与完成后的网格一致。
class _PhonePosterGridSkeleton extends StatelessWidget {
  const _PhonePosterGridSkeleton({this.count = 4});

  final int count;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const spacing = AppSpacing.sm;
        final columns = mobileGridColumnCount(
          constraints.maxWidth,
          textScale: MediaQuery.textScalerOf(context).scale(16) / 16,
        );
        final cellWidth =
            (constraints.maxWidth - spacing * (columns - 1)) / columns;
        final imageHeight = cellWidth * 1.5;
        final label = phonePosterCardLabelExtent(context);
        final rows = (count / columns).ceil();
        return Column(
          children: [
            for (var row = 0; row < rows; row++) ...[
              if (row > 0) const SizedBox(height: AppSpacing.lg),
              Row(
                children: [
                  for (var column = 0; column < columns; column++) ...[
                    if (column > 0) const SizedBox(width: spacing),
                    if (row * columns + column < count)
                      SizedBox(
                        width: cellWidth,
                        height: imageHeight + label,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SkeletonBlock(
                              width: cellWidth,
                              height: imageHeight,
                              borderRadius: BorderRadius.circular(
                                PhoneArtworkFrame.defaultRadius,
                              ),
                            ),
                            const Spacer(),
                            SkeletonBlock(width: cellWidth * 0.72, height: 12),
                          ],
                        ),
                      )
                    else
                      SizedBox(width: cellWidth),
                  ],
                ],
              ),
            ],
          ],
        );
      },
    );
  }
}
