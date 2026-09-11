import 'package:flutter/widgets.dart';
import 'package:rillight/app/app.dart';
import 'package:rillight/auth/auth_bootstrap.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final auth = await createProductionAuth();
  runApp(RillightApp(auth: auth));
}
