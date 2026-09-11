import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
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
    return CatalogScope(controller: _catalog, child: widget.child);
  }
}

class LibrariesAction extends StatelessWidget {
  const LibrariesAction({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = AuthScope.maybeOf(context);
    if (auth == null) {
      return const SizedBox.shrink();
    }
    return ListenableBuilder(
      listenable: auth,
      builder: (context, _) {
        if (!auth.isLoggedIn) {
          return const SizedBox.shrink();
        }
        final catalog = CatalogScope.maybeOf(context);
        if (catalog == null) {
          return const SizedBox.shrink();
        }
        return ListenableBuilder(
          listenable: catalog,
          builder: (context, _) {
            final libraries = catalog.libraries;
            if (libraries.isEmpty) {
              return const SizedBox.shrink();
            }
            final l10n = AppLocalizations.of(context);
            return PopupMenuButton<String>(
              key: CatalogKeys.librariesMenu,
              tooltip: l10n.libraries,
              onSelected: (id) => context.go(AppRoutes.library(id)),
              itemBuilder: (context) => [
                for (final library in libraries)
                  PopupMenuItem(
                    value: library.id,
                    child: Text(
                      library.name,
                      key: CatalogKeys.library(library.id),
                    ),
                  ),
              ],
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.video_library_outlined, size: 18),
                    const SizedBox(width: 6),
                    Text(l10n.libraries),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}
