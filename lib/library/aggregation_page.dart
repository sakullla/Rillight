import 'dart:async';
import 'package:rillight/app/app_shell.dart';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import '../aggregation/query/aggregation_query.dart';
import '../aggregation/view/server_sections.dart';
import '../aggregation/query/same_source_query.dart';
import '../aggregation/history/history_models.dart'
    show RemoteWatch, ResumeKind;
import '../emby/catalog_cache.dart';
import '../emby/emby_models.dart';
import '../auth/auth_scope.dart';
import '../auth/source_management.dart';

import '../app/l10n/app_localizations.dart';
import '../app/presentation_environment.dart';
import '../app/routes.dart';
import '../app/theme/tokens.dart';
import '../app/tv_top_nav.dart';
import '../app/tv_widgets.dart';
import '../app/widgets/app_empty_view.dart';
import '../app/widgets/option_pill.dart';
import '../auth/auth_controller.dart';
import '../auth/server_list_store.dart';
import '../emby/emby_client.dart';
import '../emby/emby_errors.dart';
import '../home/media_shelf.dart';
import '../search/search_action.dart';
import '../search/search_overlay.dart';
import '../media_image/media_image.dart';
import '../player/playback_runtime.dart';
import '../player/player_bindings.dart';
import '../player/player_host_command.dart';
import '../player/player_window_host.dart';
import 'detail_source_scope.dart';
import 'episode_mapping_dialog.dart';
import 'poster_card.dart';
import 'server_library_page.dart';

/// A route-local projection. Keeping this State mounted on push preserves the
/// authorized query, filters, cursors, and scroll position when detail returns.
class RegionAggregationGate extends StatelessWidget {
  const RegionAggregationGate({super.key, required this.region});
  final AccessRegion region;
  @override
  Widget build(BuildContext context) {
    final access = AuthScope.of(context).regionAccess;
    return ListenableBuilder(
      listenable: access,
      builder: (context, _) {
        if (!access.allows(region)) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(AppLocalizations.of(context).aggregationPrivateLocked),
                FilledButton(
                  onPressed: () =>
                      showPrivateAccess(context, AuthScope.of(context)),
                  child: Text(AppLocalizations.of(context).privateUnlock),
                ),
              ],
            ),
          );
        }
        return AggregationPage(
          key: ValueKey((region, access.generation)),
          region: region,
        );
      },
    );
  }
}

class PrivateRegionButton extends StatelessWidget {
  const PrivateRegionButton({super.key});
  @override
  Widget build(BuildContext context) => IconButton(
    key: const Key('aggregation-private-entry'),
    tooltip: AppLocalizations.of(context).aggregationPrivate,
    onPressed: () async {
      final auth = AuthScope.of(context);
      if (!auth.regionAccess.allows(AccessRegion.private)) {
        await showPrivateAccess(context, auth);
      }
      if (context.mounted && auth.regionAccess.allows(AccessRegion.private)) {
        context.push('/private');
      }
    },
    icon: const Icon(Icons.lock_outline),
  );
}

class AggregationPage extends StatefulWidget {
  const AggregationPage({
    super.key,
    this.search = false,
    this.legacyLibraryId,
    this.initialMode = QueryMode.browse,
    this.region = AccessRegion.ordinary,
    this.sourceCommand,
    this.legacySelected = false,
    this.initialGenre = '',
    this.initialType,
    this.searchFocusNode,
    this.searchClearsTopBar = true,
    this.onCloseSearch,
  });
  final FocusNode? searchFocusNode;

  /// 桌面搜索覆盖层的关闭动作，按钮排在搜索框同一行末尾。
  final VoidCallback? onCloseSearch;

  /// 路由页从窗口顶开始，搜索栏要避开桌面顶栏。覆盖层自己已经让出顶栏。
  final bool searchClearsTopBar;
  final PlayerHostOpenItemCommand? sourceCommand;
  final bool legacySelected;
  final String initialGenre;
  final String? initialType;
  final AccessRegion region;
  final bool search;
  final String? legacyLibraryId;
  final QueryMode initialMode;
  @override
  State<AggregationPage> createState() => _AggregationPageState();
}

class _AggregationPageState extends State<AggregationPage> {
  AggregationQueryController? _query;
  final _keyword = TextEditingController();
  final _genreController = TextEditingController();
  final _yearController = TextEditingController();
  final _scroll = ScrollController();
  final _pageStorage = PageStorageBucket();
  final Map<SourceReference, GlobalKey> _cardKeys = {};
  double? _anchorOffset;
  bool _restoringAnchor = false;
  int _anchorRestoreRevision = 0;
  String _lastKeyword = '';
  Set<String>? _selected;
  final Set<String> _contributors = {};
  final Map<String, Set<String>> _libraries = {};
  String? _type;
  bool? _played;
  QueryMode _mode = QueryMode.browse;
  int? _year;
  String _genre = '';
  String _sort = 'SortName';

  @override
  void initState() {
    super.initState();
    _genreController.text = widget.initialGenre;
    _keyword.addListener(_keywordChanged);
    _scroll.addListener(_rememberAnchor);
  }

  void _keywordChanged() {
    if (_lastKeyword == _keyword.text) return;
    _lastKeyword = _keyword.text;
    if (widget.search) _start();
  }

  bool get _usesNewExperience =>
      widget.region == AccessRegion.ordinary &&
      (widget.search ||
          (widget.sourceCommand == null &&
              widget.legacyLibraryId == null &&
              !widget.legacySelected &&
              widget.initialGenre.isEmpty &&
              widget.initialType == null &&
              widget.initialMode == QueryMode.browse));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_usesNewExperience) return;
    final runtime = PlayerScope.of(context).runtime;
    if (_query == null && runtime != null) {
      _query = AggregationQueryController(
        registry: runtime.registry,
        history: runtime.history,
      );
      _query!.addListener(_changed);
      runtime.history.addListener(_changed);
      runtime.registry.addSourceRevocation(_sourceChanged);
      _mode = widget.initialMode;
      _genre = widget.initialGenre;
      _type = widget.initialType;
      final command = widget.sourceCommand;
      if (command?.source != null && command!.libraryId != null) {
        _selected = {command.source!.account.configuredServerId};
        _libraries[command.source!.account.configuredServerId] = {
          command.libraryId!,
        };
        _query!.useAccount(
          command.source!.account,
          libraryId: command.libraryId!,
        );
      } else if (widget.search ||
          widget.legacyLibraryId != null ||
          widget.legacySelected) {
        final selected = AuthScope.of(context).session?.server;
        _selected = selected?.region == AccessRegion.ordinary
            ? {selected!.id}
            : <String>{};
        if (selected != null && widget.legacyLibraryId != null) {
          _libraries[selected.id] = {widget.legacyLibraryId!};
        }
      }
      // start clears state synchronously; dependencies cannot be notified while
      // the enclosing inherited scope is building.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _start();
      });
    }
  }

  void _sourceChanged(String id) {
    if (!_contributors.remove(id)) return;
    _selected?.remove(id);
    _libraries.remove(id);
    _genre = '';
    _year = null;
    _type = null;
    _played = null;
    _genreController.clear();
    _yearController.clear();
    // User drafts and selection ids are presentation state too. A migrated
    // contribution must not survive as text/semantics in the ordinary overlay.
    _keyword.clear();
    _start();
    _changed();
  }

  void _rememberAnchor() {
    if (_restoringAnchor || !mounted) return;
    _anchorRestoreRevision++;
    final height = MediaQuery.sizeOf(context).height;
    final visible = <(SourceReference, double)>[];
    for (final entry in _cardKeys.entries) {
      final box = entry.value.currentContext?.findRenderObject();
      if (box is RenderBox && box.hasSize && box.attached) {
        final y = box.localToGlobal(Offset.zero).dy;
        if (y + box.size.height > 80 && y < height) visible.add((entry.key, y));
      }
    }
    visible.sort((a, b) => a.$2.compareTo(b.$2));
    if (visible.isNotEmpty) {
      _query?.anchor = visible.first.$1;
      _anchorOffset = visible.first.$2;
    }
  }

  void _changed() {
    if (!mounted) return;
    final revision = ++_anchorRestoreRevision;
    final anchor = _query?.anchor;
    final previousY = _anchorOffset;
    setState(() {});
    if (anchor == null || previousY == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !_scroll.hasClients ||
          revision != _anchorRestoreRevision) {
        return;
      }
      final group = _query?.resolveAnchor(anchor);
      if (group == null) return;
      final box = _cardKeys[group.sources.first.reference]?.currentContext
          ?.findRenderObject();
      if (box is! RenderBox || !box.hasSize || !box.attached) return;
      final delta = box.localToGlobal(Offset.zero).dy - previousY;
      _restoringAnchor = true;
      _scroll.jumpTo(
        (_scroll.offset + delta).clamp(0, _scroll.position.maxScrollExtent),
      );
      _restoringAnchor = false;
    });
  }

  void _start() {
    final query = _query;
    if (query == null) return;
    final command = widget.sourceCommand;
    if (command?.source != null) {
      try {
        final permit = query.registry.permit(
          command!.source!.account,
          libraryId: command.libraryId,
        );
        if (!permit.isValid ||
            permit.regionGeneration != command.regionGeneration) {
          return;
        }
      } catch (_) {
        return;
      }
    }
    _contributors
      ..clear()
      ..addAll(
        query.registry
            .project(widget.region)
            .where(
              (s) =>
                  s.participates &&
                  (_selected == null || _selected!.contains(s.id)),
            )
            .map((s) => s.id),
      );
    _anchorOffset = null;
    _cardKeys.clear();
    if (_scroll.hasClients) _scroll.jumpTo(0);
    unawaited(
      query.start(
        QueryScope(
          region: widget.region,
          serverIds: _selected,
          libraries: _libraries,
          mode: widget.search ? QueryMode.search : _mode,
          keyword: _keyword.text,
          types: _type == null ? null : {_type!},
          played: _played,
          years: _year == null ? {} : {_year!},
          genres: _genre.trim().isEmpty ? {} : {_genre.trim()},
          sortBy: _sort,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _query?.registry.removeSourceRevocation(_sourceChanged);
    _query?.history.removeListener(_changed);
    _query?.removeListener(_changed);
    _query?.dispose();
    _keyword.dispose();
    _genreController.dispose();
    _yearController.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_usesNewExperience) {
      return widget.search
          ? _AggregationSearch(
              focusNode: widget.searchFocusNode,
              clearOfDesktopBar: widget.searchClearsTopBar,
              onClose: widget.onCloseSearch,
            )
          : const _AggregationBrowse();
    }
    final l = AppLocalizations.of(context);
    final query = _query;
    final servers = AuthScope.of(context).sources.project(widget.region);
    final works = query?.works ?? const <WorkGroup>[];
    final items = query?.items ?? const <QueryItem>[];
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
      },
      child: Material(
        child: FocusTraversalGroup(
          child: PageStorage(
            bucket: _pageStorage,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final columns = (constraints.maxWidth / 180).floor().clamp(
                  2,
                  8,
                );
                return CustomScrollView(
                  key: PageStorageKey(
                    widget.search ? 'aggregation-search' : 'aggregation',
                  ),
                  controller: _scroll,
                  slivers: [
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 64, 16, 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                if (GoRouter.of(context).canPop())
                                  BackButton(onPressed: () => context.pop()),
                                Expanded(
                                  child: Text(
                                    widget.search ? l.search : l.aggregation,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.headlineSmall,
                                  ),
                                ),
                                IconButton(
                                  key: const Key(
                                    'aggregation-source-management',
                                  ),
                                  tooltip: l.sourceManagement,
                                  onPressed: () => showSourceManagement(
                                    context,
                                    region: widget.region,
                                  ),
                                  icon: const Icon(Icons.tune),
                                ),
                                if (widget.region == AccessRegion.private)
                                  IconButton(
                                    tooltip: l.privateLock,
                                    onPressed: () => AuthScope.of(
                                      context,
                                    ).regionAccess.lock(),
                                    icon: const Icon(Icons.lock),
                                  ),
                                if (widget.region == AccessRegion.ordinary)
                                  const PrivateRegionButton(),
                              ],
                            ),
                            if (widget.search &&
                                PresentationScope.of(context).isTv)
                              TvInput(
                                key: const Key('aggregation-keyword'),
                                autofocus: true,
                                label: l.search,
                                controller: _keyword,
                                onSubmitted: _start,
                              ),
                            if (widget.search &&
                                !PresentationScope.of(context).isTv)
                              TextField(
                                focusNode: widget.searchFocusNode,
                                key: const Key('aggregation-keyword'),
                                controller: _keyword,
                                decoration: InputDecoration(
                                  labelText: l.search,
                                  suffixIcon: IconButton(
                                    tooltip: l.search,
                                    onPressed: _start,
                                    icon: const Icon(Icons.search),
                                  ),
                                ),
                                onSubmitted: (_) => _start(),
                              ),
                            Wrap(
                              spacing: 8,
                              runSpacing: 4,
                              children: [
                                FilterChip(
                                  label: Text(
                                    widget.region == AccessRegion.ordinary
                                        ? l.aggregationAllSources
                                        : l.aggregationAllowedSources,
                                  ),
                                  selected: _selected == null,
                                  onSelected: (_) {
                                    setState(() => _selected = null);
                                    _start();
                                  },
                                ),
                                for (final server in servers)
                                  FilterChip(
                                    key: ValueKey(
                                      'aggregation-source-${server.id}',
                                    ),
                                    label: Text(server.displayName),
                                    selected:
                                        _selected == null ||
                                        _selected!.contains(server.id),
                                    onSelected: (selected) {
                                      setState(() {
                                        _selected ??= servers
                                            .map((s) => s.id)
                                            .toSet();
                                        selected
                                            ? _selected!.add(server.id)
                                            : _selected!.remove(server.id);
                                      });
                                      _start();
                                    },
                                  ),
                              ],
                            ),
                            ExpansionTile(
                              key: const PageStorageKey(
                                'aggregation-library-panel',
                              ),
                              title: Text(l.aggregationLibraryScope),
                              children: [
                                for (final server in servers)
                                  Wrap(
                                    spacing: 8,
                                    children: [
                                      for (final library in server.libraryIds)
                                        FilterChip(
                                          key: ValueKey(
                                            'aggregation-library-${server.id}-$library',
                                          ),
                                          label: Text(
                                            '${server.displayName} · $library',
                                          ),
                                          selected:
                                              !_libraries.containsKey(
                                                server.id,
                                              ) ||
                                              _libraries[server.id]!.contains(
                                                library,
                                              ),
                                          onSelected: (selected) {
                                            _libraries.putIfAbsent(
                                              server.id,
                                              () => server.libraryIds.toSet(),
                                            );
                                            selected
                                                ? _libraries[server.id]!.add(
                                                    library,
                                                  )
                                                : _libraries[server.id]!.remove(
                                                    library,
                                                  );
                                            _start();
                                          },
                                        ),
                                    ],
                                  ),
                              ],
                            ),
                            if (query == null) Text(l.appInitializationFailed),
                            Wrap(
                              spacing: 12,
                              runSpacing: 8,
                              children: [
                                DropdownButton<String>(
                                  value: _type ?? '',
                                  items: [
                                    DropdownMenuItem(
                                      value: '',
                                      child: Text(l.aggregationAllTypes),
                                    ),
                                    const DropdownMenuItem(
                                      value: 'Movie',
                                      child: Text('电影'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'Episode',
                                      child: Text(l.episodesRow),
                                    ),
                                    const DropdownMenuItem(
                                      value: 'Series',
                                      child: Text('剧集'),
                                    ),
                                  ],
                                  onChanged: (value) {
                                    setState(
                                      () => _type = value == '' ? null : value,
                                    );
                                    _start();
                                  },
                                ),
                                DropdownButton<bool>(
                                  value: _played,
                                  hint: Text(l.aggregationAllWatching),
                                  items: const [
                                    DropdownMenuItem(
                                      value: true,
                                      child: Text('已看'),
                                    ),
                                    DropdownMenuItem(
                                      value: false,
                                      child: Text('未看'),
                                    ),
                                  ],
                                  onChanged: (value) {
                                    setState(() => _played = value);
                                    _start();
                                  },
                                ),
                                TextButton(
                                  onPressed: () {
                                    setState(() => _played = null);
                                    _start();
                                  },
                                  child: Text(l.aggregationAllWatching),
                                ),
                                DropdownButton<String>(
                                  value: _sort,
                                  items: const [
                                    DropdownMenuItem(
                                      value: 'SortName',
                                      child: Text('标题'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'ProductionYear',
                                      child: Text('年份'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'DateCreated',
                                      child: Text('最近更新'),
                                    ),
                                  ],
                                  onChanged: (value) {
                                    setState(() => _sort = value!);
                                    _start();
                                  },
                                ),
                                SizedBox(
                                  width: PresentationScope.of(context).isTv
                                      ? 220
                                      : 90,
                                  child: PresentationScope.of(context).isTv
                                      ? TvInput(
                                          key: const Key('aggregation-year'),
                                          label: '年份',
                                          controller: _yearController,
                                          onSubmitted: () {
                                            _year = int.tryParse(
                                              _yearController.text,
                                            );
                                            _start();
                                          },
                                        )
                                      : TextField(
                                          key: const Key('aggregation-year'),
                                          controller: _yearController,
                                          decoration: const InputDecoration(
                                            labelText: '年份',
                                          ),
                                          keyboardType: TextInputType.number,
                                          onSubmitted: (value) {
                                            _year = int.tryParse(value);
                                            _start();
                                          },
                                        ),
                                ),
                                SizedBox(
                                  width: PresentationScope.of(context).isTv
                                      ? 240
                                      : 120,
                                  child: PresentationScope.of(context).isTv
                                      ? TvInput(
                                          key: const Key('aggregation-genre'),
                                          label: '流派',
                                          controller: _genreController,
                                          onSubmitted: () {
                                            _genre = _genreController.text;
                                            _start();
                                          },
                                        )
                                      : TextField(
                                          key: const Key('aggregation-genre'),
                                          controller: _genreController,
                                          decoration: const InputDecoration(
                                            labelText: '流派',
                                          ),
                                          onSubmitted: (value) {
                                            _genre = value;
                                            _start();
                                          },
                                        ),
                                ),
                                if (!widget.search) ...[
                                  ChoiceChip(
                                    label: Text(l.aggregation),
                                    selected: _mode == QueryMode.browse,
                                    onSelected: (_) {
                                      _mode = QueryMode.browse;
                                      _start();
                                    },
                                  ),
                                  ChoiceChip(
                                    label: Text(l.aggregationContinue),
                                    selected:
                                        _mode == QueryMode.continueWatching,
                                    onSelected: (_) {
                                      _mode = QueryMode.continueWatching;
                                      _start();
                                    },
                                  ),
                                  ChoiceChip(
                                    label: Text(l.aggregationRecent),
                                    selected: _mode == QueryMode.recent,
                                    onSelected: (_) {
                                      _mode = QueryMode.recent;
                                      _start();
                                    },
                                  ),
                                ],
                              ],
                            ),
                            if (query != null) ...[
                              Text(
                                '${_mode == QueryMode.continueWatching ? l.aggregationLoadedRemote : l.aggregationLoaded}: ${works.length} · ${query.complete ? l.aggregationComplete : l.aggregationIncomplete}',
                              ),
                              if (widget.search && _keyword.text.trim().isEmpty)
                                Text(l.searchEmptyQuery)
                              else if (query.summary == QuerySummary.emptyScope)
                                Text(l.aggregationEmptyScope),
                              if (query.summary == QuerySummary.empty)
                                Text(
                                  _mode == QueryMode.continueWatching &&
                                          query.localContinueWatching.isNotEmpty
                                      ? l.aggregationRemoteEmpty
                                      : l.aggregationEmpty,
                                ),
                              if (query.summary == QuerySummary.allFailed)
                                Text(l.aggregationAllFailed),
                              if (query.summary == QuerySummary.partialFailure)
                                Text(l.aggregationPartialFailure),
                              for (final source in query.sources)
                                _SourceStatus(
                                  source: source,
                                  name:
                                      servers
                                          .where(
                                            (s) => s.id == source.key.serverId,
                                          )
                                          .firstOrNull
                                          ?.displayName ??
                                      '',
                                  retry: () => query.retry(source.key),
                                  more: () => query.loadMore(source.key),
                                ),
                              if (_mode == QueryMode.continueWatching)
                                for (final record
                                    in query.localContinueWatching)
                                  ListTile(
                                    title: Text(l.aggregationLocalRecord),
                                    subtitle: Text(
                                      '${record.source.itemId} · ${record.positionTicks ~/ 10000000}s · ${record.remoteStatus.name}',
                                    ),
                                    trailing: IconButton(
                                      tooltip: l.aggregationResumeActual,
                                      icon: const Icon(Icons.play_arrow),
                                      onPressed: () =>
                                          _resumeRecord(context, record),
                                    ),
                                    onTap: () => _open(
                                      context,
                                      QueryItem(
                                        record.source,
                                        record.libraryId,
                                        items
                                                .where(
                                                  (i) =>
                                                      i.reference ==
                                                      record.source.item,
                                                )
                                                .firstOrNull
                                                ?.item ??
                                            // Records without a currently loaded DTO still navigate
                                            // by the recorded source, never by the selected auth.
                                            EmbyItem(
                                              id: record.source.itemId,
                                              name: l.aggregationLocalRecord,
                                              type: 'Movie',
                                            ),
                                      ),
                                    ),
                                  ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    SliverPadding(
                      padding: const EdgeInsets.all(16),
                      sliver: SliverGrid(
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: columns,
                          mainAxisSpacing: 12,
                          crossAxisSpacing: 12,
                          childAspectRatio: .56,
                        ),
                        delegate: SliverChildBuilderDelegate((context, index) {
                          final group = works[index];
                          final item = items.firstWhere(
                            (i) => i.reference == group.sources.first.reference,
                          );
                          return _QueryCard(
                            key: _cardKeys.putIfAbsent(
                              item.reference,
                              () => GlobalKey(),
                            ),
                            item: item,
                            count: group.sources.length,
                            open: () {
                              query!.anchor = item.reference;
                              if (_mode == QueryMode.continueWatching) {
                                _openResume(context, item);
                              } else {
                                _open(context, item);
                              }
                            },
                            compare: () => _compare(context, item),
                          );
                        }, childCount: works.length),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openResume(BuildContext context, QueryItem item) async {
    final query = _query!;
    final choice = query.resolveResume(
      item.reference,
      remote: query.items
          .where((i) => i.item.userData.playbackPositionTicks > 0)
          .map(
            (i) => RemoteWatch(
              source: i.reference,
              work: i.reference.item,
              libraryId: i.libraryId,
              positionTicks: i.item.userData.playbackPositionTicks,
              playedAt: i.item.userData.lastPlayedDate,
            ),
          ),
    );
    if (choice.kind == ResumeKind.local && choice.local != null) {
      _resumeRecord(context, choice.local!);
      return;
    }
    if (choice.kind != ResumeKind.conflict) {
      final selected = choice.remote;
      _open(
        context,
        selected == null
            ? item
            : query.items.firstWhere(
                (i) => i.reference == selected.source.item,
              ),
      );
      return;
    }
    final scope = query.scope;
    await showDialog<void>(
      context: context,
      useRootNavigator: false,
      builder: (context) => AnimatedBuilder(
        animation: query,
        builder: (context, _) {
          if (query.scope != scope) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (context.mounted) Navigator.of(context).pop();
            });
            return const SizedBox.shrink();
          }
          final services = query.registry.project(widget.region);
          final allowed = choice.conflicts
              .where(
                (r) => query.items.any((i) => i.reference == r.source.item),
              )
              .toList();
          return _DialogKeyboard(
            child: AlertDialog(
              title: Text(
                AppLocalizations.of(context).aggregationRemoteConflict,
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final record in allowed)
                      ListTile(
                        title: Text(
                          '${services.where((s) => s.id == record.source.account.configuredServerId).firstOrNull?.displayName ?? ''} · ${record.positionTicks ~/ 10000000}s',
                        ),
                        onTap: () {
                          final target = query.items
                              .where((i) => i.reference == record.source.item)
                              .firstOrNull;
                          Navigator.of(context).pop();
                          if (target != null) _open(context, target);
                        },
                      ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(
                    MaterialLocalizations.of(context).closeButtonLabel,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _compare(BuildContext context, QueryItem item) async {
    final query = _query!;
    final controller = SameSourceQueryController(
      registry: query.registry,
      history: query.history,
    );
    unawaited(
      controller.start(
        origin: item,
        scope: QueryScope(
          region: item.reference.account.region,
          serverIds: _selected,
        ),
      ),
    );
    await showDialog<void>(
      context: context,
      useRootNavigator: false,
      builder: (context) => _ComparisonDialog(controller: controller),
    );
    controller.dispose();
  }
}

void _resumeRecord(BuildContext context, WatchRecord record) {
  final permit = AuthScope.of(
    context,
  ).sources.permit(record.source.account, libraryId: record.libraryId);
  if (!permit.isValid) return;
  final request = PlayerOpenRequest(
    itemId: record.source.itemId,
    source: record.source,
    work: record.work,
    libraryId: record.libraryId,
    regionGeneration: permit.regionGeneration,
    mediaSourceId: record.source.mediaSourceId,
    startTimeTicks: record.positionTicks,
    autoResume: false,
  );
  if (PresentationScope.of(context).isDesktop) {
    unawaited(PlayerWindowScope.of(context).open(request));
  } else {
    context.push(
      '/play/${Uri.encodeComponent(record.source.itemId)}',
      extra: request,
    );
  }
}

void _open(BuildContext context, QueryItem item) {
  final registry = AuthScope.of(context).sources;
  final permit = registry.permit(
    item.reference.account,
    libraryId: item.libraryId,
  );
  if (!permit.isValid) return;
  SearchOverlayController.maybeOf(context)?.close();
  context.push(
    '/item/${Uri.encodeComponent(item.reference.itemId)}',
    extra: PlayerHostOpenItemCommand(
      itemId: item.reference.itemId,
      source: item.reference,
      libraryId: item.libraryId,
      regionGeneration: permit.regionGeneration,
    ),
  );
}

class _DialogKeyboard extends StatelessWidget {
  const _DialogKeyboard({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Shortcuts(
    shortcuts: const {
      SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
    },
    child: CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).pop(),
        const SingleActivator(LogicalKeyboardKey.goBack): () =>
            Navigator.of(context).pop(),
      },
      child: Focus(autofocus: true, child: child),
    ),
  );
}

String _sourceStatusLabel(SourceQueryStatus status, AppLocalizations l) =>
    switch (status) {
      SourceQueryStatus.idle => l.aggregationUnknown,
      SourceQueryStatus.loading => l.aggregationLoading,
      SourceQueryStatus.available => l.aggregationAvailable,
      SourceQueryStatus.empty => l.aggregationEmpty,
      SourceQueryStatus.timeout => l.aggregationTimeout,
      SourceQueryStatus.offline => l.aggregationOffline,
      SourceQueryStatus.needsLogin => l.aggregationNeedsLogin,
      SourceQueryStatus.forbidden => l.aggregationForbidden,
      SourceQueryStatus.failed => l.aggregationFailed,
      SourceQueryStatus.revoked => l.aggregationRevoked,
    };

class _SourceStatus extends StatelessWidget {
  const _SourceStatus({
    required this.source,
    required this.name,
    required this.retry,
    required this.more,
  });
  final SourceQuerySnapshot source;
  final String name;
  final VoidCallback retry, more;
  @override
  Widget build(BuildContext context) => Wrap(
    crossAxisAlignment: WrapCrossAlignment.center,
    spacing: 8,
    children: [
      Text(
        '$name · ${source.key.libraryId} · ${_sourceStatusLabel(source.status, AppLocalizations.of(context))}',
      ),
      if (source.status == SourceQueryStatus.loading)
        const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      if (source.failed)
        TextButton(
          onPressed: retry,
          child: Text(AppLocalizations.of(context).aggregationRetry),
        ),
      if (source.hasMore &&
          !source.failed &&
          source.status != SourceQueryStatus.loading)
        TextButton(
          onPressed: more,
          child: Text(AppLocalizations.of(context).aggregationMore),
        ),
    ],
  );
}

class _QueryCard extends StatefulWidget {
  const _QueryCard({
    super.key,
    required this.item,
    required this.count,
    required this.open,
    required this.compare,
  });
  final QueryItem item;
  final int count;
  final VoidCallback open, compare;
  @override
  State<_QueryCard> createState() => _QueryCardState();
}

class _QueryCardState extends State<_QueryCard> {
  PlaybackOrigin? _origin;
  MediaImageSourcePolicy? _policy;
  final _cache = CatalogCache();
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_origin == null) unawaited(_resolve());
  }

  Future<void> _resolve() async {
    try {
      final item = widget.item;
      final permit = AuthScope.of(
        context,
      ).sources.permit(item.reference.account, libraryId: item.libraryId);
      final client = await permit.dispatch(
        (c) async => c.withRequestGuard(permit.requireValid),
      );
      if (!mounted || !permit.isValid) return;
      final origin = PlaybackOrigin(
        source: item.reference,
        work: item.reference,
        libraryId: item.libraryId,
        permit: permit,
        client: client,
      );
      setState(() {
        _origin = origin;
        _policy = MediaImageSourcePolicy(origin);
      });
    } catch (_) {
      /* Revoked cards must not fall back to selected auth images. */
    }
  }

  @override
  void dispose() {
    _policy?.revoke();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final origin = _origin;
    if (origin == null || !origin.permit.isValid) {
      return const SizedBox.shrink();
    }
    return DetailSourceScope(
      origin: origin,
      cache: _cache,
      imagePolicy: _policy!,
      child: Column(
        children: [
          Expanded(
            child: InkWell(
              onTap: widget.open,
              child: AspectRatio(
                aspectRatio: 2 / 3,
                child: MediaImage(item: widget.item.item, fit: BoxFit.cover),
              ),
            ),
          ),
          TextButton(
            onPressed: widget.open,
            child: Text(
              widget.item.item.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton(
            onPressed: widget.compare,
            child: Text(
              '${AppLocalizations.of(context).aggregationSources} · ${widget.count}',
            ),
          ),
        ],
      ),
    );
  }
}

String _versionFacts(EmbyItem item, AppLocalizations l) {
  String fact(Object? value) => value?.toString() ?? l.aggregationUnknown;
  if (item.mediaSources.isEmpty) return l.aggregationUnknown;
  return item.mediaSources
      .map(
        (s) =>
            '${fact(s.name)}\n'
            '分辨率 ${fact(s.width)}×${fact(s.height)} · 码率 ${fact(s.bitrate)} · 大小 ${fact(s.size)} · 时长 ${fact(s.runTimeTicks)}\n'
            '${s.streams.map((v) => '${v.type}: ${fact(v.codec)} / ${fact(v.language)} / ${fact(v.videoRange)}').join('; ')}',
      )
      .join('\n');
}

/// Mounted in every gated detail tree, independent of global search.
class SourceComparisonAction extends StatefulWidget {
  const SourceComparisonAction({super.key});
  @override
  State<SourceComparisonAction> createState() => _SourceComparisonActionState();
}

class _SourceComparisonActionState extends State<SourceComparisonAction> {
  bool _loading = false;
  Future<void> _show() async {
    final origin = DetailSourceScope.maybeOf(context);
    final runtime = PlayerScope.of(context).runtime;
    if (origin == null || runtime == null || !origin.permit.isValid) return;
    setState(() => _loading = true);
    SameSourceQueryController? controller;
    try {
      var dto = await origin.permit.dispatch(
        (c) => c.getItem(origin.source.itemId),
      );
      EpisodeSource? episode;
      if (dto.isEpisode && dto.seriesId != null) {
        episode = EpisodeSource.fromEmby(origin.source, dto);
        dto = await origin.permit.dispatch((c) => c.getItem(dto.seriesId!));
      }
      if (!mounted || !origin.permit.isValid) return;
      final item = QueryItem(
        SourceReference(account: origin.source.account, itemId: dto.id),
        origin.libraryId,
        dto,
      );
      controller = SameSourceQueryController(
        registry: runtime.registry,
        history: runtime.history,
      );
      unawaited(
        controller.start(
          origin: item,
          scope: QueryScope(region: origin.source.account.region),
        ),
      );
      await showDialog<void>(
        context: context,
        useRootNavigator: false,
        builder: (context) =>
            _ComparisonDialog(controller: controller!, episode: episode),
      );
    } catch (_) {
      if (mounted && origin.permit.isValid) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.of(context).aggregationAllFailed),
          ),
        );
      }
    } finally {
      controller?.dispose();
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final origin = DetailSourceScope.maybeOf(context);
    if (origin == null || !origin.permit.isValid) {
      return const SizedBox.shrink();
    }
    final source = AuthScope.of(context).sources
        .project(origin.source.account.region)
        .where((s) => s.id == origin.source.account.configuredServerId)
        .firstOrNull;
    return Material(
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 220,
              child: Text(
                '${source?.displayName ?? ''} · ${origin.client.baseUrl}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            FilledButton.icon(
              onPressed: _loading ? null : _show,
              icon: const Icon(Icons.compare_arrows),
              label: Text(AppLocalizations.of(context).aggregationSources),
            ),
          ],
        ),
      ),
    );
  }
}

class _ComparisonDialog extends StatelessWidget {
  const _ComparisonDialog({required this.controller, this.episode});
  final SameSourceQueryController controller;
  final EpisodeSource? episode;
  Future<void> _lookupEpisode(BuildContext context, QueryItem target) async {
    final verified = await confirmEpisodeMapping(context);
    if (!context.mounted) return;
    if (controller.origin == null) {
      Navigator.of(context).pop();
      return;
    }
    if (verified == null) return;
    final e = episode!;
    final mapped = verified ? withConfirmedEpisodeMapping(e) : e;
    await controller.lookupEpisode(
      target: target,
      episode: mapped,
      verifiedNumberingScheme: verified ? userConfirmedEpisodeNumbering : null,
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final l = AppLocalizations.of(context);
      if (controller.origin == null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (context.mounted && ModalRoute.of(context)?.isCurrent == true) {
            Navigator.of(context).pop();
          }
        });
        return const SizedBox.shrink();
      }
      final servers = controller.query.registry.project(
        controller.origin!.reference.account.region,
      );
      return _DialogKeyboard(
        child: AlertDialog(
          title: Text(l.aggregationSources),
          content: SizedBox(
            width: 640,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    controller.complete
                        ? l.aggregationComplete
                        : l.aggregationIncomplete,
                  ),
                  for (final source in controller.sources)
                    _SourceStatus(
                      source: source,
                      name:
                          servers
                              .where((s) => s.id == source.key.serverId)
                              .firstOrNull
                              ?.displayName ??
                          '',
                      retry: () => controller.retry(source.key),
                      more: () => controller.loadMore(source.key),
                    ),
                  for (final comparison in controller.comparisons)
                    ListTile(
                      title: Text(
                        '${comparison.decision.confirmed ? l.aggregationConfirmed : l.aggregationCandidate} · ${comparison.source.item.name}',
                      ),
                      subtitle: Text(
                        '${servers.where((s) => s.id == comparison.source.reference.account.configuredServerId).firstOrNull?.displayName ?? ''}\n'
                        '${comparison.decision.reason.name} · ${_versionFacts(comparison.source.item, l)}',
                      ),
                      trailing:
                          episode != null &&
                              comparison.decision.confirmed &&
                              comparison.source.item.isSeries
                          ? TextButton(
                              onPressed: () =>
                                  _lookupEpisode(context, comparison.source),
                              child: Text(l.aggregationEpisodeLookup),
                            )
                          : null,
                      onTap: () {
                        Navigator.of(context).pop();
                        _open(context, comparison.source);
                      },
                    ),
                  for (final result in controller.episodes)
                    ListTile(
                      title: Text(
                        result.lookup.status == EpisodeLookupStatus.missing
                            ? l.aggregationMissingEpisode
                            : result.lookup.status ==
                                  EpisodeLookupStatus.queryFailed
                            ? l.aggregationEpisodeFailed
                            : result.lookup.status ==
                                  EpisodeLookupStatus.confirmed
                            ? l.aggregationEpisodeConfirmed
                            : l.aggregationEpisodeUncertain,
                      ),
                      subtitle: Text(_sourceStatusLabel(result.status, l)),
                      trailing:
                          result.lookup.status ==
                              EpisodeLookupStatus.queryFailed
                          ? TextButton(
                              onPressed: () => _lookupEpisode(
                                context,
                                controller.comparisons
                                    .firstWhere(
                                      (c) =>
                                          c.source.reference == result.target,
                                    )
                                    .source,
                              ),
                              child: Text(l.aggregationRetry),
                            )
                          : null,
                      onTap: result.lookup.source == null
                          ? null
                          : () {
                              final target = controller.comparisons
                                  .firstWhere(
                                    (c) => c.source.reference == result.target,
                                  )
                                  .source;
                              final ref = result.lookup.source!.reference;
                              Navigator.pop(context);
                              _open(
                                context,
                                QueryItem(
                                  ref,
                                  target.libraryId,
                                  EmbyItem(
                                    id: ref.itemId,
                                    name: l.aggregationEpisodeConfirmed,
                                    type: 'Episode',
                                  ),
                                ),
                              );
                            },
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(MaterialLocalizations.of(context).closeButtonLabel),
            ),
          ],
        ),
      );
    },
  );
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

  void _open(ServerSections section, EmbyItem item) {
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
    final track = Theme.of(context).colorScheme.surfaceContainerHigh;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: track.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(999),
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
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return TextButton(
      key: Key(keyName),
      onPressed: () => setState(() => _segment = value),
      style: TextButton.styleFrom(
        foregroundColor: selected ? scheme.onSurface : scheme.onSurfaceVariant,
        backgroundColor: selected ? scheme.surface : Colors.transparent,
        textStyle: theme.textTheme.labelLarge?.copyWith(
          fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
        ),
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        minimumSize: const Size(0, 32),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: const StadiumBorder(),
      ),
      child: Text(label),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final loader = _loader;
    final servers = loader?.servers ?? const <ServerSections>[];
    final desktop = PresentationScope.of(context).isDesktop;
    final rows = [
      for (final section in servers)
        if (_slice(section).items.isNotEmpty ||
            _slice(section).error != null ||
            _slice(section).loading)
          section,
    ];
    if (PresentationScope.of(context).isTv) {
      return _tvBuild(context, loader, servers, rows);
    }
    return Material(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(
              AppSpacing.page,
              desktop ? AppShell.topBarHeight + AppSpacing.sm : 8,
              AppSpacing.page,
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
                IconButton(
                  key: const Key('aggregation-source-management'),
                  tooltip: l.sourceManagement,
                  onPressed: () => showSourceManagement(
                    context,
                    region: AccessRegion.ordinary,
                  ),
                  icon: const Icon(Icons.tune),
                ),
                const PrivateRegionButton(),
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
      return const Center(child: CircularProgressIndicator());
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
                onMore: captioned && slice.items.isNotEmpty
                    ? () =>
                          context.push(AppRoutes.serverResume(section.serverId))
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
      IconData icon,
    ) => TvAction(
      key: Key(key),
      pill: true,
      selected: _segment == value,
      leading: Icon(icon),
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
            Icons.history_rounded,
          ),
          segment(
            l.filterFavorite,
            'aggregation-segment-favorites',
            _AggregationSegment.favorites,
            Icons.favorite_border_rounded,
          ),
          segment(
            l.libraries,
            'aggregation-segment-libraries',
            _AggregationSegment.libraries,
            Icons.video_library_outlined,
          ),
        ],
      ),
    );
    final Widget body;
    if (loader == null || (loader.loading && servers.isEmpty)) {
      body = SizedBox(
        height: 260 * s,
        child: const Center(child: CircularProgressIndicator()),
      );
    } else if (servers.isEmpty) {
      body = SizedBox(
        height: 300 * s,
        child: TvEmptyState(
          icon: Icons.dns_outlined,
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
    return Material(
      type: MaterialType.transparency,
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
              trailing: captioned
                  ? (context, metrics) => TvMoreTile(
                      metrics: metrics,
                      onPressed: () => context.push(
                        AppRoutes.serverResume(section.serverId),
                      ),
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
    EmbyItem item,
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
    this.items = const [],
    this.error,
    this.loading = false,
  });

  final String serverId;
  final String serverName;
  final SourceAccount? account;
  final List<EmbyItem> items;
  final EmbyException? error;
  final bool loading;

  _SearchHit copyWith({
    SourceAccount? account,
    List<EmbyItem>? items,
    EmbyException? error,
    bool clearError = false,
    bool? loading,
  }) {
    return _SearchHit(
      serverId: serverId,
      serverName: serverName,
      account: account ?? this.account,
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
    final ids = AuthScope.of(
      context,
    ).sources.project(AccessRegion.ordinary).map((server) => server.id).toSet();
    final next = [
      for (final row in _rows)
        if (ids.contains(row.serverId)) row,
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
      for (final server in registry.project(AccessRegion.ordinary))
        if (_servers == null || _servers!.contains(server.id)) server,
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
        .project(AccessRegion.ordinary)
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
    final hit = await _query(server, term);
    if (!mounted ||
        generation != _generation ||
        _attempt[server.id] != attempt) {
      return;
    }
    final next = [
      for (final row in _rows)
        if (row.serverId != server.id) row,
    ];
    if (hit != null) next.add(hit);
    final order = AuthScope.of(
      context,
    ).sources.project(AccessRegion.ordinary).map((item) => item.id).toList();
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
      final page = await session.client.queryItems(
        searchTerm: term,
        includeItemTypes: 'Movie,Series',
        recursive: true,
        limit: aggregationRowLimit,
        fields: EmbyClient.gridFields,
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
        items: items,
      );
    } on StateError catch (error) {
      if (error.message == 'Login required') return null;
      return _SearchHit(
        serverId: server.id,
        serverName: server.displayName,
        error: EmbyException(EmbyFailureKind.unknown, cause: error),
      );
    } catch (error) {
      return _SearchHit(
        serverId: server.id,
        serverName: server.displayName,
        error: error is EmbyException
            ? error
            : EmbyException(EmbyFailureKind.unknown, cause: error),
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
    final servers = AuthScope.of(
      context,
    ).sources.project(AccessRegion.ordinary);
    final visible = [
      for (final row in _rows)
        if (row.items.isNotEmpty || row.error != null || row.loading) row,
    ];
    if (presentation.isTv) return _tvBuild(context, servers, visible);
    final field = presentation.isTv
        ? TvInput(
            key: const Key('aggregation-keyword'),
            autofocus: true,
            label: l.searchHint,
            controller: _keyword,
            onSubmitted: _submit,
          )
        : TextField(
            key: const Key('aggregation-keyword'),
            focusNode: widget.focusNode,
            controller: _keyword,
            autofocus: widget.focusNode == null,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: l.searchHint,
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: ValueListenableBuilder<TextEditingValue>(
                valueListenable: _keyword,
                builder: (context, value, _) {
                  // 输入即搜，不再单设提交按钮；查询中以转圈代替清除钮。
                  if (_searching && value.text.isNotEmpty) {
                    return const Padding(
                      padding: EdgeInsets.all(15),
                      child: SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    );
                  }
                  if (value.text.isEmpty) return const SizedBox.shrink();
                  return IconButton(
                    key: const Key('aggregation-search-clear'),
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).deleteButtonTooltip,
                    onPressed: () {
                      _keyword.clear();
                      _submit();
                      widget.focusNode?.requestFocus();
                    },
                    icon: const Icon(Icons.close_rounded),
                  );
                },
              ),
            ),
            onSubmitted: (_) => _submit(),
          );
    return Material(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            // 桌面搜索框与下方结果分区同取 24 页边距，左缘对齐。
            padding: EdgeInsets.fromLTRB(
              presentation.isDesktop ? AppSpacing.page : 16,
              presentation.isDesktop && widget.clearOfDesktopBar ? 64 : 12,
              presentation.isDesktop ? AppSpacing.md : 16,
              8,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    if (!presentation.isDesktop)
                      BackButton(onPressed: () => context.pop()),
                    Expanded(child: field),
                    if (servers.isNotEmpty) ...[
                      const SizedBox(width: AppSpacing.xxs),
                      IconButton(
                        key: const Key('aggregation-search-filters'),
                        tooltip: l.searchServerFilter,
                        isSelected: _filtersOpen || _servers != null,
                        onPressed: () =>
                            setState(() => _filtersOpen = !_filtersOpen),
                        icon: Icon(
                          Icons.filter_list_rounded,
                          color: _servers == null
                              ? null
                              : Theme.of(context).colorScheme.primary,
                        ),
                      ),
                    ],
                    if (widget.onClose != null)
                      IconButton(
                        key: SearchOverlay.closeKey,
                        tooltip: MaterialLocalizations.of(
                          context,
                        ).closeButtonTooltip,
                        onPressed: widget.onClose,
                        icon: const Icon(Icons.close_rounded),
                      ),
                  ],
                ),
                if (_filtersOpen)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
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
                              _toggleServer(servers, server.id, !selected);
                            },
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          Expanded(child: _results(context, visible)),
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
                  leading: const Icon(Icons.search_rounded),
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
                  leading: const Icon(Icons.filter_list_rounded),
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
                          ? Icons.check_rounded
                          : Icons.add_rounded,
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
        child: TvEmptyState(
          icon: Icons.search_rounded,
          message: l.searchEmptyQuery,
        ),
      );
    } else if (_searching && visible.isEmpty) {
      body = SizedBox(
        height: 260 * s,
        child: const Center(child: CircularProgressIndicator()),
      );
    } else if (visible.isEmpty) {
      body = SizedBox(
        height: 280 * s,
        child: TvEmptyState(
          icon: Icons.search_off_rounded,
          message: l.searchNoResults,
        ),
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
                style: TextStyle(color: Theme.of(context).colorScheme.error),
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
                          style: Theme.of(context).textTheme.labelMedium
                              ?.copyWith(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
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
    return Material(
      type: MaterialType.transparency,
      child: ListView(
        key: const PageStorageKey('aggregation-search'),
        padding: EdgeInsets.only(bottom: tvSafeVertical(size.height)),
        children: [header, body],
      ),
    );
  }

  Widget _results(BuildContext context, List<_SearchHit> visible) {
    final l = AppLocalizations.of(context);
    if (_term.isEmpty) {
      return AppEmptyView(
        icon: Icons.search_rounded,
        message: l.searchEmptyQuery,
      );
    }
    if (_searching && visible.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (visible.isEmpty) {
      return AppEmptyView(
        icon: Icons.search_off_rounded,
        message: l.searchNoResults,
      );
    }
    final failed = visible.where((row) => row.error != null).length;
    return ListView(
      key: const PageStorageKey('aggregation-search'),
      children: [
        const SizedBox(height: AppSpacing.xs),
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
                openServerItem(context, account: account, item: item);
              },
            ),
          ),
      ],
    );
  }
}
