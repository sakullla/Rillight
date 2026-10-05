import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import '../aggregation/query/aggregation_query.dart';
import '../aggregation/query/same_source_query.dart';
import '../aggregation/history/history_models.dart'
    show RemoteWatch, ResumeKind;
import '../emby/catalog_cache.dart';
import '../emby/emby_models.dart';
import '../auth/auth_scope.dart';

import '../app/l10n/app_localizations.dart';
import '../app/presentation_environment.dart';
import '../app/tv_widgets.dart';
import '../media_image/media_image.dart';
import '../player/playback_runtime.dart';
import '../player/player_bindings.dart';
import '../player/player_host_command.dart';
import '../player/player_window_host.dart';
import 'detail_source_scope.dart';

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
            child: Text(AppLocalizations.of(context).aggregationPrivateLocked),
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
    onPressed: () => context.push('/private'),
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
  });
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

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
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
            child: CustomScrollView(
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
                            if (widget.region == AccessRegion.ordinary)
                              const PrivateRegionButton(),
                          ],
                        ),
                        if (widget.search && PresentationScope.of(context).isTv)
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
                                          !_libraries.containsKey(server.id) ||
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
                                selected: _mode == QueryMode.continueWatching,
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
                          if (query.summary == QuerySummary.emptyScope)
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
                                      .where((s) => s.id == source.key.serverId)
                                      .firstOrNull
                                      ?.displayName ??
                                  '',
                              retry: () => query.retry(source.key),
                              more: () => query.loadMore(source.key),
                            ),
                          if (_mode == QueryMode.continueWatching)
                            for (final record in query.localContinueWatching)
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
                SliverLayoutBuilder(
                  builder: (context, constraints) {
                    final columns = (constraints.crossAxisExtent / 180)
                        .floor()
                        .clamp(2, 8);
                    return SliverPadding(
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
                    );
                  },
                ),
              ],
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
    final verified = await showDialog<bool>(
      context: context,
      useRootNavigator: false,
      builder: (context) => _DialogKeyboard(
        child: AlertDialog(
          title: Text(AppLocalizations.of(context).aggregationEpisodeMapping),
          content: Text(
            AppLocalizations.of(context).aggregationEpisodeMappingWarning,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(
                AppLocalizations.of(context).aggregationEpisodeUncertain,
              ),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(
                AppLocalizations.of(context).aggregationEpisodeMappingConfirm,
              ),
            ),
          ],
        ),
      ),
    );
    if (!context.mounted) return;
    if (controller.origin == null) {
      Navigator.of(context).pop();
      return;
    }
    if (verified == null) return;
    final e = episode!;
    const numbering = 'user-confirmed-season-episode';
    final mapped = verified
        ? EpisodeSource(
            reference: e.reference,
            series: e.series,
            season: e.season,
            episode: e.episode,
            endEpisode: e.endEpisode,
            isSpecial: e.isSpecial,
            providerIds: e.providerIds,
            numberingScheme: numbering,
          )
        : e;
    await controller.lookupEpisode(
      target: target,
      episode: mapped,
      verifiedNumberingScheme: verified ? numbering : null,
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
