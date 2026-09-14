import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/app/widgets/liquid_glass.dart';
import 'package:rillight/app/window_chrome.dart';
import 'package:rillight/search/search_page.dart';

/// 搜索覆盖层与页面内容之间的半透明黑色遮罩。
///
/// 常驻 [AppShell] 层叠,叠在页面内容与顶栏之上、[SearchOverlay] 之下:
/// 打开搜索时压暗背景,保证覆盖层标题/输入/结果在任意亮色 backdrop 下
/// 可读;覆盖层自身的输入、结果滚动、Esc 与关闭按钮在遮罩之上不受影响。
/// 点击遮罩等同关闭搜索:覆盖层玻璃面板吸收指针事件,非交互区域的
/// 点击由 [SearchOverlay] 根部的手势代理关闭;遮罩自身的 [onDismiss]
/// 在覆盖层让出事件时兜底。
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
/// 覆盖层之下叠 [SearchOverlayBarrier] 压暗背景(见 [AppShell])。
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

    return GestureDetector(
      // LiquidGlass 全屏面板的 backdrop 层吸收所有指针事件,遮罩本身无法
      // 直接命中;点击覆盖层非交互区域等同点击遮罩,交给 [onClose] 关闭。
      // 输入框/结果卡片/关闭按钮等交互子件的手势更深,在手势竞技场中
      // 优先胜出,不受影响。
      onTap: onClose,
      child: CallbackShortcuts(
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
      ),
    );
  }
}
