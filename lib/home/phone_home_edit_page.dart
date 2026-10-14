import 'dart:async';

import 'package:rillight/app/ui/ui.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/home/phone_home_sections.dart';

/// 从首页进入的行编辑。账号页不放这份长列表。
class PhoneHomeEditPage extends StatefulWidget {
  const PhoneHomeEditPage({super.key});

  static const pageKey = Key('phone-home-edit-page');

  @override
  State<PhoneHomeEditPage> createState() => _PhoneHomeEditPageState();
}

class _PhoneHomeEditPageState extends State<PhoneHomeEditPage> {
  var _loadedServerId = '';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final serverId = AuthScope.maybeOf(context)?.session?.server.id ?? '';
    if (_loadedServerId == serverId) {
      return;
    }
    _loadedServerId = serverId;
    unawaited(PhoneHomeSectionController.app().load(serverId));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final catalog = CatalogScope.of(context);
    final sections = PhoneHomeSectionController.app();
    return CupertinoPageScaffold(
      key: PhoneHomeEditPage.pageKey,
      navigationBar: CupertinoNavigationBar(
        transitionBetweenRoutes: false,
        middle: Text(l10n.phoneHomeEdit),
      ),
      child: ListenableBuilder(
        listenable: Listenable.merge([sections, catalog]),
        builder: (context, _) {
          return PhoneHomeSectionEditor(
            controller: sections,
            libraries: catalog.libraries,
          );
        },
      ),
    );
  }
}
