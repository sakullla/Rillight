import 'package:flutter/material.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/window_chrome.dart';
import 'package:rillight/auth/auth_scope.dart';

/// 顶栏中的搜索入口(图标按钮)。
///
/// 点击行为与 [openSearch] 一致:打开覆盖层,不 push `/search` 页壳。
class SearchAction extends StatelessWidget {
  const SearchAction({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = AuthScope.maybeOf(context);
    if (auth == null) {
      return const SizedBox.shrink();
    }
    return ListenableBuilder(
      listenable: auth,
      builder: (context, _) {
        if (!auth.isLoggedIn) {
          return const SizedBox.shrink();
        }
        final l10n = AppLocalizations.of(context);
        return IconButton(
          tooltip: l10n.search,
          onPressed: () => openSearch(context),
          padding: EdgeInsets.zero,
          constraints: kTitleBarIconConstraints,
          visualDensity: VisualDensity.compact,
          iconSize: 18,
          icon: const Icon(Icons.search),
        );
      },
    );
  }
}

/// 打开搜索覆盖层;已打开时聚焦输入,不重复入栈、不 push `/search`。
void openSearch(BuildContext context) {
  SearchOverlayController.maybeOf(context)?.open();
}

/// 关闭搜索覆盖层;未打开时为 no-op。
void closeSearch(BuildContext context) {
  SearchOverlayController.maybeOf(context)?.close();
}

/// AppShell 提供的搜索覆盖层控制:打开、关闭、是否已显示。
class SearchOverlayController extends InheritedWidget {
  const SearchOverlayController({
    super.key,
    required this.isOpen,
    required this.open,
    required this.close,
    required super.child,
  });

  final bool isOpen;
  final VoidCallback open;
  final VoidCallback close;

  static SearchOverlayController? maybeOf(BuildContext context) {
    return context.getInheritedWidgetOfExactType<SearchOverlayController>();
  }

  @override
  bool updateShouldNotify(SearchOverlayController oldWidget) {
    return isOpen != oldWidget.isOpen;
  }
}
