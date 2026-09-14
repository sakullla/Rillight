import 'package:flutter/material.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_controller.dart';
import 'package:rillight/home/media_shelf.dart';

class HomeMediaRow extends StatelessWidget {
  const HomeMediaRow({
    super.key,
    required this.rowKey,
    required this.shelfId,
    required this.title,
    required this.state,
    required this.onTap,
    required this.onRetry,
    required this.onMore,
    this.showProgress = false,
    this.wide = false,
    this.onRemoveFromResume,
    this.headerAction,
  });

  final Key rowKey;
  final String shelfId;
  final String title;
  final CatalogRowState state;
  final ValueChanged<EmbyItem> onTap;
  final VoidCallback onRetry;
  final VoidCallback onMore;
  final bool showProgress;
  final bool wide;
  final ValueChanged<EmbyItem>? onRemoveFromResume;

  /// 货架标题右侧的附加控件(首页把手动刷新钮挂在这里)。
  final Widget? headerAction;

  @override
  Widget build(BuildContext context) {
    if (state.hidden) {
      return const SizedBox.shrink();
    }
    // 静默重试耗尽后 [CatalogRowState.error] 非空:MediaShelf 走错误分支,
    // 渲染「重试」入口并经 [onRetry] 重拉整组首页行。
    return MediaShelf(
      rowKey: rowKey,
      shelfId: shelfId,
      title: title,
      items: state.items,
      loading: state.loading,
      error: state.error,
      onRetry: onRetry,
      onMore: onMore,
      onTap: onTap,
      showProgress: showProgress,
      wide: wide,
      onRemoveFromResume: onRemoveFromResume,
      headerAction: headerAction,
    );
  }
}
