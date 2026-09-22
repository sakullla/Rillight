import 'dart:async';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/mobile_widgets.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/home/catalog_controller.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/player/android_session_recovery.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/player/player_settings.dart';
import 'package:rillight/search/mobile_search_page.dart';

class MobileShell extends StatefulWidget {
  const MobileShell({super.key});
  @override
  State<MobileShell> createState() => _MobileShellState();
}

class _MobileShellState extends State<MobileShell> with WidgetsBindingObserver {
  int _index = 0;
  bool _recovering = false,
      _recoveryFailed = false,
      _recovered = false,
      _initialized = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_initialized) {
      _initialized = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _recover();
      });
    }
  }

  Future<void> _recover() async {
    final store = PlayerScope.of(context).snapshotStore;
    if (store == null || _recovering) return;
    setState(() {
      _recovering = true;
      _recoveryFailed = false;
    });
    try {
      final recovered = await recoverAndroidSession(
        AuthScope.of(context).client,
        store,
      );
      if (mounted) setState(() => _recovered = recovered);
    } catch (_) {
      if (mounted) setState(() => _recoveryFailed = true);
    } finally {
      if (mounted) setState(() => _recovering = false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      final auth = AuthScope.of(context), catalog = CatalogScope.of(context);
      if (auth.isLoggedIn) {
        unawaited(() async {
          try {
            await auth.client.getUser();
          } catch (_) {
            /* Catalog displays retry or auth redirects. */
          }
          if (mounted && auth.isLoggedIn) await catalog.reload();
        }());
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context), auth = AuthScope.of(context);
    final titles = [l.home, l.libraries, l.search, l.mobileMine];
    return PopScope(
      canPop: _index == 0,
      onPopInvokedWithResult: (popped, _) {
        if (!popped) setState(() => _index = 0);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(titles[_index]),
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(24),
            child: Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                auth.session?.server.name ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ),
        body: SafeArea(
          child: Column(
            children: [
              if (_recovering) const LinearProgressIndicator(),
              if (_recoveryFailed)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    children: [
                      Text(l.mobileRecoveryFailed),
                      FilledButton(onPressed: _recover, child: Text(l.retry)),
                      TextButton(
                        onPressed: auth.logout,
                        child: Text(l.connect),
                      ),
                    ],
                  ),
                ),
              if (_recovered)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(l.mobilePreviousSession),
                ),
              Expanded(
                child: IgnorePointer(
                  ignoring: _recovering || _recoveryFailed,
                  child: IndexedStack(
                    index: _index,
                    children: const [
                      _MobileHome(),
                      _MobileLibraries(),
                      MobileSearchPage(),
                      _MobileMine(),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        bottomNavigationBar: MediaQuery.viewInsetsOf(context).bottom > 0
            ? null
            : NavigationBar(
                selectedIndex: _index,
                onDestinationSelected: (index) {
                  FocusScope.of(context).unfocus();
                  setState(() => _index = index);
                },
                destinations: [
                  NavigationDestination(
                    icon: const Icon(Icons.home_outlined),
                    selectedIcon: const Icon(Icons.home),
                    label: l.home,
                  ),
                  NavigationDestination(
                    icon: const Icon(Icons.video_library_outlined),
                    selectedIcon: const Icon(Icons.video_library),
                    label: l.libraries,
                  ),
                  NavigationDestination(
                    icon: const Icon(Icons.search),
                    label: l.search,
                  ),
                  NavigationDestination(
                    icon: const Icon(Icons.person_outline),
                    selectedIcon: const Icon(Icons.person),
                    label: l.mobileMine,
                  ),
                ],
              ),
      ),
    );
  }
}

class _MobileHome extends StatelessWidget {
  const _MobileHome();
  @override
  Widget build(BuildContext context) {
    final c = CatalogScope.of(context), l = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) => RefreshIndicator(
        onRefresh: () => c.reload(showCachedFirst: false),
        child: ListView(
          key: const PageStorageKey('mobile-home-scroll'),
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(12),
          children: [
            for (final row in [
              (l.resumeRow, c.resume),
              (l.nextUpRow, c.nextUp),
              (l.latestMoviesRow, c.latestMovies),
              (l.latestSeriesRow, c.latestSeries),
            ])
              _MobileRow(title: row.$1, state: row.$2, retry: c.reloadHomeRows),
            if ([
              c.resume,
              c.nextUp,
              c.latestMovies,
              c.latestSeries,
            ].every((r) => r.hidden))
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text(l.mobileEmpty),
              ),
            TextButton.icon(
              onPressed: () => c.reload(showCachedFirst: false),
              icon: const Icon(Icons.refresh),
              label: Text(l.mobileRefresh),
            ),
          ],
        ),
      ),
    );
  }
}

class _MobileRow extends StatelessWidget {
  const _MobileRow({
    required this.title,
    required this.state,
    required this.retry,
  });
  final String title;
  final CatalogRowState state;
  final VoidCallback retry;
  @override
  Widget build(BuildContext context) {
    if (state.hidden) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(title, style: Theme.of(context).textTheme.titleLarge),
        ),
        if (state.loading) const LinearProgressIndicator(),
        if (state.error != null || state.notice != null)
          MobileFailure(error: (state.error ?? state.notice)!, retry: retry),
        if (state.items.isNotEmpty)
          SizedBox(
            height:
                250 + 35 * (MediaQuery.textScalerOf(context).scale(14) / 14),
            child: ListView.builder(
              key: PageStorageKey('row-$title'),
              scrollDirection: Axis.horizontal,
              itemCount: state.items.length,
              itemBuilder: (context, index) => SizedBox(
                width: 148,
                child: MobilePoster(item: state.items[index]),
              ),
            ),
          ),
      ],
    );
  }
}

class _MobileLibraries extends StatelessWidget {
  const _MobileLibraries();
  @override
  Widget build(BuildContext context) {
    final c = CatalogScope.of(context), l = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) => RefreshIndicator(
        onRefresh: c.reload,
        child: ListView(
          key: const PageStorageKey('mobile-libraries-scroll'),
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: [
            if (c.librariesLoading) const LinearProgressIndicator(),
            if (c.librariesError != null || c.librariesNotice != null)
              MobileFailure(
                error: (c.librariesError ?? c.librariesNotice)!,
                retry: c.reload,
              ),
            if (!c.librariesLoading &&
                c.librariesError == null &&
                c.libraries.isEmpty)
              Text(l.mobileEmpty),
            for (final library in c.libraries)
              Card(
                child: ListTile(
                  minVerticalPadding: 20,
                  leading: const Icon(Icons.video_library),
                  title: Text(library.name),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.push(AppRoutes.library(library.id)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _MobileMine extends StatefulWidget {
  const _MobileMine();
  @override
  State<_MobileMine> createState() => _MobileMineState();
}

class _MobileMineState extends State<_MobileMine> {
  PlayerSettingsStore? _store;
  double _rate = 1;
  bool _loaded = false;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    unawaited(() async {
      _store =
          PlayerScope.of(context).settingsStore ??
          await openPlayerSettingsStore();
      final settings = await _store!.read();
      if (mounted) setState(() => _rate = settings.playbackRate ?? 1);
    }());
  }

  Future<void> _lines() async {
    final auth = AuthScope.of(context), l = AppLocalizations.of(context);
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (context) => FractionallySizedBox(
        heightFactor: .65,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(l.mobileLine, style: Theme.of(context).textTheme.titleLarge),
            for (final server in auth.savedServers) ...[
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text('${server.name} · ${server.username}'),
              ),
              for (final line in server.lines)
                ListTile(
                  title: Text(line.hostLabel),
                  selected:
                      auth.session?.server.id == server.id &&
                      auth.session?.server.activeLine?.id == line.id,
                  onTap: () async {
                    Navigator.pop(context);
                    await auth.switchTo(server.id, lineId: line.id);
                  },
                ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = AuthScope.of(context), l = AppLocalizations.of(context);
    return ListView(
      key: const PageStorageKey('mobile-mine-scroll'),
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          auth.session?.username ?? '',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 8),
        Text(auth.session?.server.name ?? ''),
        const SizedBox(height: 20),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.dns_outlined),
          title: Text(l.mobileLine),
          onTap: _lines,
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.add),
          title: Text(l.mobileAddServer),
          onTap: () => context.push('${AppRoutes.connect}?add=1'),
        ),
        const Divider(),
        Text(l.mobileSpeed),
        Wrap(
          spacing: 8,
          children: [
            for (final rate in [.5, 1.0, 1.25, 1.5, 2.0])
              ChoiceChip(
                label: Text('${rate}x'),
                selected: _rate == rate,
                onSelected: (_) async {
                  await _store?.write(PlayerSettings(playbackRate: rate));
                  if (mounted) setState(() => _rate = rate);
                },
              ),
          ],
        ),
        const SizedBox(height: 24),
        OutlinedButton(
          onPressed: auth.isBusy ? null : auth.logout,
          child: Text(l.logout),
        ),
      ],
    );
  }
}
