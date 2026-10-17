import 'package:rillight/app/ui/ui.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/home/catalog_scope.dart';

import 'server_selection_page.dart';

Future<void> showPhoneServerManagerSheet(
  BuildContext context,
  AuthController auth,
) => showServerSelection(
  context,
  auth: auth,
  phone: true,
  onEntered: () async {
    if (context.mounted) await CatalogScope.maybeOf(context)?.reload();
  },
  onLineChanged: () async {
    if (context.mounted) await CatalogScope.maybeOf(context)?.reload();
  },
);
