import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/app/window_chrome.dart';
import 'package:rillight/auth/auth_bootstrap.dart';
import 'package:rillight/player/desktop_player_window.dart';
import 'package:rillight/player/player_bindings.dart';
import 'package:window_manager/window_manager.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  PaintingBinding.instance.imageCache.maximumSize = 2000;
  PaintingBinding.instance.imageCache.maximumSizeBytes = 256 << 20;
  MediaKit.ensureInitialized();
  if (args.isNotEmpty &&
      (args.first == 'player' || args.first == 'multi_window')) {
    try {
      await windowManager.ensureInitialized();
      await windowManager.hide();
    } catch (_) {}
    if (args.first == 'player') {
      await runPlayerWindow(argumentFallback: args.length > 1 ? args[1] : '');
      return;
    }
    final controller = await WindowController.fromCurrentEngine();
    await runPlayerWindow(
      controller: controller,
      argumentFallback: args.length > 2 ? args[2] : null,
    );
    return;
  }
  await configureMainWindow();
  final auth = await createProductionAuth();
  runApp(
    WindowChromeHost(
      child: RillightApp(
        auth: auth,
        playerBindings: PlayerBindings(
          windowHost: DesktopPlayerWindowHost(auth: auth),
        ),
      ),
    ),
  );
}
