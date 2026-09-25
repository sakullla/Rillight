import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/mobile_motion.dart';
import 'package:rillight/app/phone_bottom_nav.dart';
import 'package:rillight/app/phone_libraries_tab.dart';
import 'package:rillight/app/phone_nav_style.dart';
import 'package:rillight/app/routes.dart';
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
  bool _homeCovered = false;
  bool _recovering = false, _recoveryFailed = false, _initialized = false;
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
      if (mounted && recovered) {
        final messenger = ScaffoldMessenger.of(context);
        messenger.clearSnackBars();
        messenger.showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.of(context).mobilePreviousSession),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 4),
          ),
        );
      }
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
    final titles = [l.home, l.libraries, l.search];
    final floating = PhoneNavStyle.floatingOf(context);
    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    final immersive = _index == 0 && !_homeCovered;
    const hit = Size(AppSpacing.huge, AppSpacing.huge);
    return PopScope(
      canPop: _index == 0,
      onPopInvokedWithResult: (popped, _) {
        if (!popped) setState(() => _index = 0);
      },
      child: Scaffold(
        extendBody: floating && !keyboardOpen,
        extendBodyBehindAppBar: _index == 0,
        appBar: AppBar(
          toolbarHeight: 56,
          centerTitle: false,
          forceMaterialTransparency: immersive,
          backgroundColor: immersive ? Colors.transparent : null,
          surfaceTintColor: immersive ? Colors.transparent : null,
          elevation: immersive ? 0 : null,
          scrolledUnderElevation: immersive ? 0 : null,
          title: Text(titles[_index]),
          titleTextStyle: Theme.of(context).textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w600,
            height: 1.2,
          ),
          actions: [
            if (_index == 0)
              IconButton(
                key: const Key('phone-home-edit'),
                tooltip: l.phoneHomeEdit,
                icon: const Icon(Icons.tune),
                onPressed: () => context.push(AppRoutes.homeEdit),
              ),
            IconButton(
              key: const Key('mobile-shell-mine-entry'),
              tooltip: l.mobileMine,
              icon: const Icon(Icons.account_circle_outlined),
              onPressed: () => context.push(AppRoutes.mine),
            ),
          ],
        ),
        body: NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            if (_index != 0 || notification.metrics.axis != Axis.vertical) {
              return false;
            }
            final covered = notification.metrics.pixels > 24;
            if (covered != _homeCovered) {
              setState(() => _homeCovered = covered);
            }
            return false;
          },
          child: SafeArea(
            top: _index != 0,
            bottom: !floating,
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
                Expanded(
                  child: IgnorePointer(
                    ignoring: _recovering || _recoveryFailed,
                    child: PhoneTabTransition(
                      index: _index,
                      child: IndexedStack(
                        index: _index,
                        children: [
                          TickerMode(
                            enabled: _index == 0,
                            child: const PhoneHome(),
                          ),
                          TickerMode(
                            enabled: _index == 1,
                            child: const PhoneLibrariesTab(),
                          ),
                          TickerMode(
                            enabled: _index == 2,
                            child: const MobileSearchPage(),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        bottomNavigationBar: keyboardOpen
            ? null
            : PhoneBottomNav(
                index: _index,
                floating: floating,
                onSelected: (index) {
                  FocusScope.of(context).unfocus();
                  setState(() => _index = index);
                },
              ),
      ),
    );
  }
}
