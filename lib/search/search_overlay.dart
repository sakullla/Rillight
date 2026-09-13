import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/app/widgets/liquid_glass.dart';
import 'package:rillight/app/window_chrome.dart';
import 'package:rillight/search/search_page.dart';

/// 全屏搜索覆盖层:复用 [SearchPage] 的查询、结果与 50 条/600px 分页。
///
/// 由 [openSearch] 打开,不作为主导航页壳;Esc 或关闭按钮退出。
class SearchOverlay extends StatelessWidget {
  const SearchOverlay({super.key, required this.onClose, this.queryFocusNode});

  final VoidCallback onClose;
  final FocusNode? queryFocusNode;

  static const overlayKey = Key('search-overlay');
  static const closeKey = Key('search-overlay-close');

  @override
  Widget build(BuildContext context) {
    final hasChrome =
        context.findAncestorWidgetOfExactType<WindowChromeHost>() != null;
    final leading = hasChrome ? windowChromeLeadingInset() : 0.0;
    final trailing = hasChrome ? windowChromeTrailingInset() : 0.0;

    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): onClose},
      child: Focus(
        autofocus: true,
        child: LiquidGlass(
          key: overlayKey,
          kind: LiquidGlassKind.panel,
          borderRadius: BorderRadius.zero,
          child: Material(
            type: MaterialType.transparency,
            child: Padding(
              padding: EdgeInsets.only(
                left: leading + AppSpacing.md,
                right: trailing + AppSpacing.md,
                top: 56,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Text(
                        AppLocalizations.of(context).search,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const Spacer(),
                      IconButton(
                        key: closeKey,
                        tooltip: MaterialLocalizations.of(
                          context,
                        ).closeButtonTooltip,
                        onPressed: onClose,
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                  Expanded(
                    child: SearchPage(
                      autofocus: true,
                      focusNode: queryFocusNode,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
