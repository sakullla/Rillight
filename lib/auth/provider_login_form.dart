import 'package:rillight/app/ui/ui.dart';
import 'package:go_router/go_router.dart';

import '../app/l10n/app_localizations.dart';
import '../app/presentation_environment.dart';
import '../app/routes.dart';
import '../app/tv_widgets.dart';
import '../media_server/capabilities.dart';
import 'auth_scope.dart';
import 'login_widgets.dart';
import 'provider_connect_dialog.dart';
import 'server_list_store.dart';

/// Keeps provider selection and authorization in the current login page.
///
/// 顶部是服务类型分段切换与一句登录方式说明,下面是对应表单。切换时表单
/// 高度平滑过渡,内容淡入;选中已保存的服务器会自动切到它的服务类型。
class ProviderLoginForm extends StatefulWidget {
  const ProviderLoginForm({
    super.key,
    required this.embyForm,
    required this.userAgent,
    this.selectedServer,
    this.wrapForm,
  });

  final Widget embyForm;
  final String Function() userAgent;
  final SavedServer? selectedServer;

  /// 页面给三种表单统一套外框(例如桌面的玻璃卡片)。
  final Widget Function(Widget form)? wrapForm;

  @override
  State<ProviderLoginForm> createState() => _ProviderLoginFormState();
}

class _ProviderLoginFormState extends State<ProviderLoginForm> {
  late MediaServerType type =
      widget.selectedServer?.serviceType ?? MediaServerType.emby;

  @override
  void didUpdateWidget(ProviderLoginForm oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedServer?.id != widget.selectedServer?.id) {
      type = widget.selectedServer?.serviceType ?? MediaServerType.emby;
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = AuthScope.of(context);
    final tv = PresentationScope.maybeOf(context)?.isTv == true;
    final theme = AppUiTheme.of(context);
    final l = AppLocalizations.of(context);
    final ValueChanged<MediaServerType>? onChanged = auth.isBusy
        ? null
        : (value) => setState(() => type = value);
    final Widget body = type == MediaServerType.emby
        ? KeyedSubtree(
            key: const ValueKey('login-form-emby'),
            child: widget.embyForm,
          )
        : ProviderConnectDialog(
            key: ValueKey((type, widget.selectedServer?.id)),
            auth: auth,
            existing: widget.selectedServer?.serviceType == type
                ? widget.selectedServer
                : null,
            initialType: type,
            initialUserAgent: widget.userAgent(),
            inline: true,
            onConnected: () => context.go(AppRoutes.home),
          );
    final wrap = widget.wrapForm;
    if (tv) {
      final s = TvDesign.scaleOf(context);
      return Container(
        decoration: BoxDecoration(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TvProviderSwitcher(value: type, onChanged: onChanged),
            SizedBox(height: 10 * s),
            ProviderHint(
              type: type,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            SizedBox(height: 12 * s),
            wrap == null ? body : wrap(body),
          ],
        ),
      );
    }
    return Container(
      decoration: BoxDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            header: true,
            child: Text(
              l.loginServiceLabel,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                letterSpacing: .4,
              ),
            ),
          ),
          const SizedBox(height: 8),
          ProviderSwitcher(value: type, onChanged: onChanged),
          const SizedBox(height: 10),
          ProviderHint(type: type),
          const SizedBox(height: 18),
          if (wrap == null)
            LoginFormTransition(child: body)
          else
            wrap(LoginFormTransition(child: body)),
        ],
      ),
    );
  }
}
