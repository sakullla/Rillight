import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/auth/auth_scope.dart';

/// 侧栏中的搜索入口(图标按钮)。
///
/// 外壳把它嵌为导航项的图标,点击行为与 [openSearch] 一致。
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
          icon: const Icon(Icons.search),
        );
      },
    );
  }
}

/// 进入搜索页;已在搜索页时不重复入栈。
void openSearch(BuildContext context) {
  if (GoRouterState.of(context).uri.path == AppRoutes.search) {
    return;
  }
  context.push(AppRoutes.search);
}
