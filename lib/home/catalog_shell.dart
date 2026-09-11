import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/home/catalog_controller.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/home/catalog_scope.dart';

class CatalogShell extends StatefulWidget {
  const CatalogShell({super.key, required this.auth, required this.child});

  final AuthController auth;
  final Widget child;

  @override
  State<CatalogShell> createState() => _CatalogShellState();
}

class _CatalogShellState extends State<CatalogShell> {
  late final CatalogController _catalog = CatalogController(auth: widget.auth);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.auth.isLoggedIn) {
        _catalog.reload();
      }
    });
  }

  @override
  void dispose() {
    _catalog.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final onConnect =
        GoRouterState.of(context).matchedLocation == AppRoutes.connect;
    return CatalogScope(
      controller: _catalog,
      child: onConnect
          ? widget.child
          : ListenableBuilder(
              listenable: _catalog,
              builder: (context, _) {
                return Row(
                  children: [
                    _CatalogRail(catalog: _catalog),
                    const VerticalDivider(width: 1, thickness: 1),
                    Expanded(child: widget.child),
                  ],
                );
              },
            ),
    );
  }
}

class _CatalogRail extends StatelessWidget {
  const _CatalogRail({required this.catalog});

  final CatalogController catalog;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final location = GoRouterState.of(context).uri.path;
    final libraries = catalog.libraries;
    var selected = 0;
    for (var i = 0; i < libraries.length; i++) {
      if (location == AppRoutes.library(libraries[i].id)) {
        selected = i + 1;
        break;
      }
    }
    return NavigationRail(
      selectedIndex: selected,
      labelType: NavigationRailLabelType.all,
      onDestinationSelected: (index) {
        if (index == 0) {
          context.go(AppRoutes.home);
          return;
        }
        context.go(AppRoutes.library(libraries[index - 1].id));
      },
      destinations: [
        NavigationRailDestination(
          icon: const Icon(Icons.home_outlined),
          selectedIcon: const Icon(Icons.home),
          label: Text(l10n.home),
        ),
        for (final library in libraries)
          NavigationRailDestination(
            icon: Icon(
              library.collectionTypeNormalized == 'tvshows'
                  ? Icons.tv_outlined
                  : Icons.movie_outlined,
            ),
            selectedIcon: Icon(
              library.collectionTypeNormalized == 'tvshows'
                  ? Icons.tv
                  : Icons.movie,
            ),
            label: Text(library.name, key: CatalogKeys.library(library.id)),
          ),
      ],
    );
  }
}
