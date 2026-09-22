import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/app/android_bootstrap.dart';
import 'package:rillight/app/router.dart';
import 'package:rillight/app/window_chrome.dart';
import 'package:rillight/auth/auth_bootstrap.dart';
import 'package:rillight/media_image/media_image.dart';
import 'package:rillight/player/desktop_player_window.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:window_manager/window_manager.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isAndroid) {
    configurePaintingImageCache(playerProcess: false);
    runApp(const AndroidBootstrap());
    return;
  }
  final playerProcess = args.isNotEmpty && args.first == 'player';
  configurePaintingImageCache(playerProcess: playerProcess);
  if (playerProcess) {
    await windowManager.ensureInitialized();
    await windowManager.hide();
    await runPlayerWindow(argumentFallback: args.length > 1 ? args[1] : '');
    return;
  }
  await configureMainWindow();
  final auth = await createProductionAuth();
  final router = createAppRouter(auth: auth);
  final playerHost = DesktopPlayerWindowHost(auth: auth);
  // 播放器进程请求打开条目详情(播放结束"查看剧集"):
  // 主窗口路由到详情页并前置主窗口。
  playerHost.onOpenItemRoute = (itemId, {seasonId}) {
    router.push(AppRoutes.item(itemId, seasonId: seasonId));
    unawaited(windowManager.focus());
  };
  runApp(
    WindowChromeHost(
      child: RillightApp(
        auth: auth,
        router: router,
        playerBindings: PlayerBindings(windowHost: playerHost),
      ),
    ),
  );
}
