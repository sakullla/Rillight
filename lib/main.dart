import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/app/product.dart';
import 'package:rillight/auth/auth_bootstrap.dart';
import 'package:window_manager/window_manager.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(title: kProductName, minimumSize: Size(960, 540)),
    () async {
      await windowManager.show();
      await windowManager.focus();
    },
  );
  final auth = await createProductionAuth();
  runApp(RillightApp(auth: auth));
}
