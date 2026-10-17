import 'server_selection_page.dart';
import 'source_management.dart';

import 'package:rillight/app/ui/ui.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/settings/settings_action.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/app/ui/app_icons.dart';

class SessionActions extends StatelessWidget {
  const SessionActions({super.key});

  static const serverMenuKey = Key('session-current-server');

  /// 未解锁时打开现有 PIN 对话框。已经允许，或对话框解锁成功时返回 true。
  static Future<bool> ensurePrivateAccess(BuildContext context) async {
    final auth = AuthScope.of(context);
    if (!auth.regionAccess.allows(AccessRegion.private)) {
      await showPrivateAccess(context, auth);
    }
    return context.mounted && auth.regionAccess.allows(AccessRegion.private);
  }

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
        final l10n = AppLocalizations.of(context);
        final server = auth.session!.server;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SettingsAction(),
            AppTooltip(
              message: '${_chipLabel(server)}\n${l10n.serversTitle}',
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 180),
                child: AppButton(
                  key: serverMenuKey,
                  onPressed: () => _openSwitcher(context, auth),
                  minimumSize: const Size(48, 36),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(AppIcons.library, size: 18),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          MediaQuery.sizeOf(context).width < 1100
                              ? l10n.serversTitle
                              : server.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 4),
                      const Icon(AppIcons.chevronDown, size: 16),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _openSwitcher(BuildContext context, AuthController auth) =>
      showServerSelection(
        context,
        auth: auth,
        onEntered: () async {
          if (!context.mounted) return;
          await CatalogScope.maybeOf(context)?.reload();
          if (context.mounted) GoRouter.of(context).go(AppRoutes.home);
        },
        onLineChanged: () async {
          if (context.mounted) await CatalogScope.maybeOf(context)?.reload();
        },
      );
}

String _chipLabel(SavedServer server) {
  final line = server.activeLine;
  if (line == null || server.lines.length < 2) {
    return server.displayName;
  }
  return '${server.displayName} · ${line.hostLabel}';
}
