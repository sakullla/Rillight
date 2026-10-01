import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/settings/settings_action.dart';
import 'package:rillight/app/window_chrome.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/auth/change_password_dialog.dart';
import 'package:rillight/auth/line_address_dialog.dart';
import 'package:rillight/auth/server_list_store.dart';
import 'package:rillight/auth/server_switcher_dialog.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/player/player_window_host.dart';

class SessionActions extends StatelessWidget {
  const SessionActions({super.key});

  static const serverMenuKey = Key('session-current-server');
  static const addServerKey = Key('session-add-server');
  static const lineSwitchFailureKey = Key('session-line-switch-failure');

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
            IconButton(
              key: serverMenuKey,
              tooltip: '${_chipLabel(server)}\n${l10n.switchServer}',
              padding: EdgeInsets.zero,
              constraints: kTitleBarIconConstraints,
              visualDensity: VisualDensity.compact,
              iconSize: 18,
              icon: const Icon(Icons.person_outline),
              onPressed: () => _openSwitcher(context, auth),
            ),
          ],
        );
      },
    );
  }

  Future<void> _openSwitcher(BuildContext context, AuthController auth) async {
    final playerHost = PlayerWindowScope.maybeOf(context);
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return ListenableBuilder(
          listenable: auth,
          builder: (context, _) {
            return ServerSwitcherDialog(
              servers: auth.savedServers,
              activeServerId: auth.session?.server.id,
              activeLineId: auth.session?.server.activeLineId,
              onSelect: (serverId, lineId) {
                Navigator.of(dialogContext).pop();
                unawaited(
                  _switchTo(context, auth, playerHost, serverId, lineId),
                );
              },
              onAddServer: () {
                Navigator.of(dialogContext).pop();
                GoRouter.of(context).push('${AppRoutes.connect}?add=1');
              },
              onLogout: () {
                Navigator.of(dialogContext).pop();
                unawaited(_logout(auth, playerHost));
              },
              onDelete: (serverId) {
                Navigator.of(dialogContext).pop();
                unawaited(_deleteServer(auth, playerHost, serverId));
              },
              onAddLine: (serverId) {
                Navigator.of(dialogContext).pop();
                unawaited(
                  _editLineAddress(context, auth, playerHost, serverId),
                );
              },
              onEditLine: (serverId, line) {
                Navigator.of(dialogContext).pop();
                unawaited(
                  _editLineAddress(
                    context,
                    auth,
                    playerHost,
                    serverId,
                    line: line,
                  ),
                );
              },
              onDeleteLine: (serverId, line) {
                Navigator.of(dialogContext).pop();
                unawaited(
                  _deleteLine(context, auth, playerHost, serverId, line),
                );
              },
              onChangePassword: () {
                Navigator.of(dialogContext).pop();
                unawaited(
                  showDialog<void>(
                    context: context,
                    builder: (_) => ChangePasswordDialog(auth: auth),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  /// 登出前先关闭播放窗口:此时主进程会话仍有效,宿主才能代发 Stopped。
  Future<void> _logout(
    AuthController auth,
    PlayerWindowHost? playerHost,
  ) async {
    await _closePlayer(playerHost);
    await auth.logout();
  }

  /// 删除当前登录的服务器前同样先停播;删除其它服务器不影响播放与会话。
  Future<void> _deleteServer(
    AuthController auth,
    PlayerWindowHost? playerHost,
    String serverId,
  ) async {
    if (auth.session?.server.id == serverId) {
      await _closePlayer(playerHost);
    }
    await auth.deleteServer(serverId);
  }

  /// 线路地址编辑:添加只录地址、不改当前线路;修改仅改地址,无
  /// User-Agent 输入项。改的是当前线路时先停掉走旧地址的播放窗口,
  /// 成功后刷新目录,之后浏览与播放走新地址。
  Future<void> _editLineAddress(
    BuildContext context,
    AuthController auth,
    PlayerWindowHost? playerHost,
    String serverId, {
    ServerLine? line,
  }) async {
    final catalog = CatalogScope.maybeOf(context);
    final address = await showLineAddressDialog(
      context,
      initialAddress: line?.address,
    );
    if (address == null || address == line?.address) {
      return;
    }
    final wasActive =
        auth.session?.server.id == serverId &&
        auth.session?.server.activeLineId == line?.id;
    if (wasActive) {
      await _closePlayer(playerHost);
    }
    if (line == null) {
      await auth.addLine(serverId, address);
      return;
    }
    final changed = await auth.updateLineAddress(serverId, line.id, address);
    if (changed && wasActive) {
      catalog?.reload();
    }
  }

  /// 删除一条线路;删除当前线路时先停播,随后客户端挂到剩余线路并
  /// 刷新目录。只剩一条线路时界面不会给出可点的删除入口。
  Future<void> _deleteLine(
    BuildContext context,
    AuthController auth,
    PlayerWindowHost? playerHost,
    String serverId,
    ServerLine line,
  ) async {
    final catalog = CatalogScope.maybeOf(context);
    final wasActive =
        auth.session?.server.id == serverId &&
        auth.session?.server.activeLineId == line.id;
    if (wasActive) {
      await _closePlayer(playerHost);
    }
    await auth.deleteLine(serverId, line.id);
    if (wasActive) {
      catalog?.reload();
    }
  }

  /// 切换服务器/线路:成功后才停播、刷新目录并回首页。目标线路不可达或
  /// 身份不一致时保持原线路、原会话与正在进行的播放,不刷新目录、不离开
  /// 当前页面,只以 SnackBar 展示 lineSwitchFailure 的原因。
  Future<void> _switchTo(
    BuildContext context,
    AuthController auth,
    PlayerWindowHost? playerHost,
    String serverId,
    String lineId,
  ) async {
    final current = auth.session?.server;
    if (serverId == current?.id && lineId == current?.activeLineId) {
      return;
    }
    final catalog = CatalogScope.maybeOf(context);
    final router = GoRouter.of(context);
    await auth.switchTo(serverId, lineId: lineId);
    final failure = auth.lineSwitchFailure;
    final switched =
        auth.session?.server.id == serverId &&
        auth.session?.server.activeLineId == lineId;
    if (!switched && failure != null) {
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          key: SessionActions.lineSwitchFailureKey,
          content: Text(
            AppLocalizations.of(context).lineSwitchFailed(failure.detail),
          ),
        ),
      );
      return;
    }
    await _closePlayer(playerHost);
    catalog?.reload();
    router.go(AppRoutes.home);
  }

  Future<void> _closePlayer(PlayerWindowHost? playerHost) async {
    if (playerHost == null) {
      return;
    }
    try {
      await playerHost.close();
    } catch (_) {
      // 播放窗口关闭失败不应阻断登出/切换。
    }
  }
}

String _chipLabel(SavedServer server) {
  final line = server.activeLine;
  if (line == null || server.lines.length < 2) {
    return server.name;
  }
  return '${server.name} · ${line.hostLabel}';
}
