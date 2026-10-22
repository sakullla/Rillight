import '../app/l10n/app_localizations.dart';
import '../app/tv_widgets.dart';
import '../app/ui/ui.dart';

/// One remote page body at a time. The header remains reachable above keyboard
/// insets; text entry uses the existing single TV keyboard sheet.
class TvServerFlowFrame extends StatelessWidget {
  const TvServerFlowFrame({
    super.key,
    required this.title,
    required this.onBack,
    required this.child,
    this.action,
    this.subtitle,
    this.scroll = true,
  });
  final String title;

  /// 标题下的说明,例如服务器数量;只是文字,不加入焦点顺序。
  final String? subtitle;
  final VoidCallback onBack;
  final Widget child;
  final Widget? action;
  final bool scroll;
  @override
  Widget build(BuildContext context) => TvFrame(
    title: title,
    subtitle: subtitle,
    actions: [
      ?action,
      TvAction(
        key: const Key('tv-server-back'),
        onPressed: onBack,
        child: Text(AppLocalizations.of(context).mobileBack),
      ),
    ],
    child: Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: scroll
          ? SingleChildScrollView(
              padding: TvFrame.contentPadding(context),
              child: child,
            )
          : child,
    ),
  );
}
