import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/widgets/skeleton.dart';
import 'package:rillight/app/tv_widgets.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/home/tv_home_page.dart';
import 'package:rillight/player/android_session_recovery.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:rillight/search/tv_search_page.dart';

class TvShell extends StatefulWidget {
  const TvShell({super.key});
  @override
  State<TvShell> createState() => _TvShellState();
}

class _TvShellState extends State<TvShell> with WidgetsBindingObserver {
  int _index = 0;
  bool _initialized = false, _recovering = false, _failed = false;
  final _home = FocusNode();
  final _recoveryRetry = FocusNode();
  final _panes = List.generate(
    4,
    (_) => FocusScopeNode(
      traversalEdgeBehavior: TraversalEdgeBehavior.parentScope,
      directionalTraversalEdgeBehavior: TraversalEdgeBehavior.parentScope,
    ),
  );
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
    final retrying = _failed;
    setState(() {
      _recovering = true;
      _failed = false;
    });
    try {
      await recoverAndroidSession(AuthScope.of(context).client, store);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) {
        setState(() => _recovering = false);
        if (_failed || retrying) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && ModalRoute.of(context)?.isCurrent == true) {
              _enterPane(_index);
            }
          });
        }
      }
    }
  }

  void _enterPane(int index) {
    if (_recovering) return;
    // Recovery replaces the destination panes, so only target mounted content.
    if (_failed) {
      if (_recoveryRetry.context != null && _recoveryRetry.canRequestFocus) {
        _recoveryRetry.requestFocus();
      }
    } else if (_panes[index].context != null) {
      ReadingOrderTraversalPolicy()
          .findFirstFocus(_panes[index])
          ?.requestFocus();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      final auth = AuthScope.of(context), catalog = CatalogScope.of(context);
      unawaited(() async {
        try {
          await auth.client.getUser();
        } catch (_) {
          /* Catalog shows recovery. */
        }
        if (mounted && auth.isLoggedIn) await catalog.reload();
      }());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _home.dispose();
    _recoveryRetry.dispose();
    for (final pane in _panes) {
      pane.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final labels = [l.home, l.libraries, l.search, l.settings];
    return PopScope(
      canPop: _index == 0,
      onPopInvokedWithResult: (popped, _) {
        if (!popped) {
          setState(() => _index = 0);
          _home.requestFocus();
        }
      },
      child: TvFrame(
        title: '${l.appName} · ${labels[_index]}',
        back: false,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: 150,
              child: Column(
                children: [
                  for (var i = 0; i < labels.length; i++)
                    SizedBox(
                      width: double.infinity,
                      child: Focus(
                        skipTraversal: true,
                        canRequestFocus: false,
                        onKeyEvent: (_, event) {
                          if (event is KeyDownEvent &&
                              event.logicalKey ==
                                  LogicalKeyboardKey.arrowRight) {
                            void enter() => _enterPane(i);
                            if (_index == i) {
                              enter();
                            } else {
                              setState(() => _index = i);
                              WidgetsBinding.instance.addPostFrameCallback((_) {
                                if (mounted) {
                                  enter();
                                  WidgetsBinding.instance.scheduleFrame();
                                }
                              });
                            }
                            return KeyEventResult.handled;
                          }
                          return KeyEventResult.ignored;
                        },
                        child: TvAction(
                          key: ValueKey('tv-nav-$i'),
                          autofocus: i == 0,
                          focusNode: i == 0 ? _home : null,
                          selected: i == _index,
                          onPressed: () => setState(() => _index = i),
                          child: Text(labels[i]),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 20),
            Expanded(
              child: _recovering
                  ? const Center(child: CircularProgressIndicator())
                  : _failed
                  ? Column(
                      children: [
                        Text(l.mobileRecoveryFailed),
                        TvAction(
                          autofocus: true,
                          focusNode: _recoveryRetry,
                          onPressed: _recover,
                          child: Text(l.retry),
                        ),
                        TvAction(
                          onPressed: AuthScope.of(context).logout,
                          child: Text(l.connect),
                        ),
                      ],
                    )
                  : IndexedStack(
                      index: _index,
                      children: [
                        for (var i = 0; i < 4; i++)
                          ExcludeFocus(
                            excluding: i != _index,
                            child: FocusScope(
                              node: _panes[i],
                              child: [
                                const TvHomePage(),
                                const _TvLibraries(),
                                const TvSearchPage(),
                                const _TvSession(),
                              ][i],
                            ),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TvLibraries extends StatelessWidget {
  const _TvLibraries();
  @override
  Widget build(BuildContext context) {
    final c = CatalogScope.of(context), l = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) => ListView(
        key: const PageStorageKey('tv-libraries'),
        children: [
          if (c.librariesLoading && c.libraries.isEmpty)
            const _TvLibrarySkeleton(),
          if (c.librariesError != null || c.librariesNotice != null)
            TvFailure(
              error: (c.librariesError ?? c.librariesNotice)!,
              retry: c.reload,
            ),
          if (!c.librariesLoading && c.libraries.isEmpty) Text(l.mobileEmpty),
          for (final library in c.libraries)
            TvAction(
              key: ValueKey(library.id),
              onPressed: () => context.push(AppRoutes.library(library.id)),
              child: Text(library.name),
            ),
          TvAction(onPressed: c.reload, child: Text(l.mobileRefresh)),
        ],
      ),
    );
  }
}

class _TvSession extends StatelessWidget {
  const _TvSession();
  @override
  Widget build(BuildContext context) {
    final auth = AuthScope.of(context), l = AppLocalizations.of(context);
    return ListView(
      key: const PageStorageKey('tv-session'),
      children: [
        Text(
          '${auth.session?.server.name ?? ''} · ${auth.session?.username ?? ''}',
        ),
        const SizedBox(height: 16),
        Text(l.mobileLine),
        for (final server in auth.savedServers)
          for (final line in server.lines)
            TvAction(
              key: ValueKey('${server.id}-${line.id}'),
              selected:
                  auth.session?.server.id == server.id &&
                  auth.session?.server.activeLine?.id == line.id,
              onPressed: auth.isBusy
                  ? null
                  : () => auth.switchTo(server.id, lineId: line.id),
              child: Text('${server.name} · ${line.hostLabel}'),
            ),
        TvAction(
          onPressed: () => context.push('${AppRoutes.connect}?add=1'),
          child: Text(l.mobileAddServer),
        ),
        TvAction(
          onPressed: auth.isBusy ? null : auth.logout,
          child: Text(l.logout),
        ),
      ],
    );
  }
}

class _TvLibrarySkeleton extends StatelessWidget {
  const _TvLibrarySkeleton();

  @override
  Widget build(BuildContext context) {
    final animate = !MediaQuery.disableAnimationsOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < 6; i++) ...[
          const SizedBox(height: 8),
          SkeletonBlock(width: 280, height: 36, animated: animate),
        ],
      ],
    );
  }
}
