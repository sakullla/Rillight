import 'dart:async';

import 'package:flutter/material.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/phone_libraries_tab.dart';
import 'package:rillight/app/phone_mine_page.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/home/phone_home.dart';
import 'package:rillight/player/android_session_recovery.dart';
import 'package:rillight/player/player_bindings.dart';
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
    const hit = Size(AppSpacing.huge, AppSpacing.huge);
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
                      FilledButton(
                        style: FilledButton.styleFrom(minimumSize: hit),
                        onPressed: _recover,
                        child: Text(l.retry),
                      ),
                      TextButton(
                        style: TextButton.styleFrom(minimumSize: hit),
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
                      PhoneHome(),
                      PhoneLibrariesTab(),
                      MobileSearchPage(),
                      PhoneMinePage(),
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
