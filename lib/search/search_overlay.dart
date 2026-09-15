import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/app/window_chrome.dart';
import 'package:rillight/search/search_page.dart';

/// 搜索覆盖层与页面内容之间的半透明黑色遮罩。
///
/// 常驻 [AppShell] 层叠,叠在页面内容与顶栏之上、[SearchOverlay] 之下。
/// 覆盖层本身是不透明阅读面,遮罩只负责关闭后的淡出,以及覆盖层让出
/// 命中时的兜底关闭。点击遮罩等同关闭搜索。
///
/// [visible] 为 false 时透明且不参与命中测试,背景立即恢复;出现/退出
/// 跟随 [AppMotion] 过渡,并尊重系统「减少动态效果」设置。
class SearchOverlayBarrier extends StatelessWidget {
  const SearchOverlayBarrier({
    super.key,
    required this.visible,
    required this.onDismiss,
  });

  /// 是否压暗背景;false 时透明且不参与命中测试。
  final bool visible;

  /// 点击遮罩回调,等同关闭搜索。
  final VoidCallback onDismiss;

  static const barrierKey = Key('search-overlay-barrier');

  /// 压暗不透明度:与近黑主题协调,亮色 backdrop 下明显压暗。
  /// 减少动态效果时由 [AppScrim.of] 抬到不低于 [AppScrim.reduced]。
  static const double dimOpacity = AppScrim.barrier;

  @override
  Widget build(BuildContext context) {
    final dim = AppScrim.of(context, dimOpacity);
    return IgnorePointer(
      ignoring: !visible,
      child: GestureDetector(
        key: barrierKey,
        behavior: HitTestBehavior.opaque,
        onTap: onDismiss,
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: AppMotion.durationOf(context, AppMotion.fast),
          curve: AppMotion.standard,
          child: SizedBox.expand(
            child: ColoredBox(color: Colors.black.withValues(alpha: dim)),
          ),
        ),
      ),
    );
  }
}

/// 全屏搜索覆盖层:复用 [SearchPage] 的查询、结果与 50 条/600px 分页。
///
/// 由 [openSearch] 打开,不作为主导航页壳;Esc 或关闭按钮退出。
/// 输入与结果是阅读面,用实色 [Material] 铺满,不走液态玻璃,避免首页
/// hero 透上来把标题和输入框衬花。关闭钮与搜索框同一行,避开窗口铬。
class SearchOverlay extends StatelessWidget {
  const SearchOverlay({super.key, required this.onClose, this.queryFocusNode});

  final VoidCallback onClose;
  final FocusNode? queryFocusNode;

  static const overlayKey = Key('search-overlay');
  static const closeKey = Key('search-overlay-close');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasChrome =
        context.findAncestorWidgetOfExactType<WindowChromeHost>() != null;
    final leading = hasChrome ? windowChromeLeadingInset() : 0.0;
    final trailing = hasChrome ? windowChromeTrailingInset() : 0.0;
    final top = hasChrome
        ? (kWindowChromeHeight > AppSpacing.xl
              ? kWindowChromeHeight
              : AppSpacing.xl)
        : AppSpacing.xl;

    return GestureDetector(
      // 点击覆盖层非交互区域等同关闭。输入框/结果卡片/关闭按钮等交互
      // 子件的手势更深,在手势竞技场中优先胜出,不受影响。
      onTap: onClose,
      child: CallbackShortcuts(
        bindings: {const SingleActivator(LogicalKeyboardKey.escape): onClose},
        child: Focus(
          autofocus: true,
          child: Material(
            key: overlayKey,
            color: theme.colorScheme.surface,
            child: Padding(
              padding: EdgeInsets.only(
                left: leading + AppSpacing.page,
                right: trailing + AppSpacing.page,
                top: top,
              ),
              child: SearchPage(
                autofocus: true,
                focusNode: queryFocusNode,
                trailing: IconButton(
                  key: closeKey,
                  tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                  onPressed: onClose,
                  icon: const Icon(Icons.close_rounded),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
