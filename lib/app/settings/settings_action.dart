import 'package:rillight/app/ui/ui.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/window_chrome.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/app/ui/app_icons.dart';

/// 顶栏中的设置入口(图标按钮),push `/settings` 页。
class SettingsAction extends StatelessWidget {
  const SettingsAction({super.key});

  static const actionKey = Key('settings-action');

  @override
  Widget build(BuildContext context) {
    final auth = AuthScope.maybeOf(context);
    if (auth == null || !auth.isLoggedIn) {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context);
    return AppIconButton(
      key: actionKey,
      tooltip: l10n.settings,
      onPressed: () => context.push(AppRoutes.settings),
      padding: EdgeInsets.zero,
      constraints: kTitleBarIconConstraints,

      size: 18,
      icon: const Icon(AppIcons.settings, fill: AppIcons.filled),
    );
  }
}
