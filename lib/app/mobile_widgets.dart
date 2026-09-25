import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/mobile_motion.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/emby/emby_errors.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/auth/failure_message.dart';
import 'package:rillight/media_image/media_image.dart';

import 'theme/tokens.dart';

/// 手机端通用按压反馈基件(T1):按下时缩放 + 提亮,供海报卡、主按钮等复用。
///
/// 缩放与提亮幅度取 [AppMobileCard] 档位,时长走 [AppMotion.durationOf],
/// 系统要求减少动态效果时动效退化为瞬时切换。配合 [onTap] 使用;
/// 仅 Android 手机布局引用,桌面/TV 组件不适用。
class MobilePressable extends StatefulWidget {
  const MobilePressable({
    super.key,
    required this.child,
    this.onTap,
    this.scale = AppMobileCard.pressScale,
    this.brighten = AppMobileCard.pressBrighten,
    this.duration = AppMobileCard.pressDuration,
  });

  final Widget child;
  final VoidCallback? onTap;

  /// 按下时的缩放比例,见 [AppMobileCard.pressScale] 档位。
  final double scale;

  /// 按下时的提亮幅度,见 [AppMobileCard.pressBrighten]。
  final double brighten;

  /// 回弹时长档,默认 [AppMobileCard.pressDuration]。
  final Duration duration;

  @override
  State<MobilePressable> createState() => _MobilePressableState();
}

class _MobilePressableState extends State<MobilePressable> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed == value) {
      return;
    }
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final duration = AppMotion.durationOf(context, widget.duration);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap == null
          ? null
          : () {
              _setPressed(false);
              widget.onTap!();
            },
      onTapDown: widget.onTap == null ? null : (_) => _setPressed(true),
      onTapUp: widget.onTap == null ? null : (_) => _setPressed(false),
      onTapCancel: widget.onTap == null ? null : () => _setPressed(false),
      child: AnimatedScale(
        scale: _pressed ? widget.scale : 1,
        duration: duration,
        curve: AppMotion.standard,
        child: ColorFiltered(
          colorFilter: _pressed
              ? ColorFilter.mode(
                  Colors.white.withValues(alpha: widget.brighten),
                  BlendMode.plus,
                )
              : const ColorFilter.mode(Colors.transparent, BlendMode.plus),
          child: widget.child,
        ),
      ),
    );
  }
}

class MobileFailure extends StatelessWidget {
  const MobileFailure({super.key, required this.error, required this.retry});
  final EmbyException error;
  final VoidCallback retry;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(embyFailureMessage(l, error)),
          const SizedBox(height: 8),
          FilledButton(onPressed: retry, child: Text(l.retry)),
        ],
      ),
    );
  }
}

class MobilePoster extends StatelessWidget {
  const MobilePoster({super.key, required this.item, this.imageMaxWidth = 240});

  final EmbyItem item;
  final int imageMaxWidth;

  /// 与 [MediaImage] 默认 `preferBackdrop: false` 的候选一致。
  /// 无标签的 Primary 兜底不算有图，避免把占位交出去。
  bool get _hasImage {
    return item
        .imageCandidates(preferBackdrop: false)
        .any((ref) => ref.tag != null && ref.tag!.isNotEmpty);
  }

  @override
  Widget build(BuildContext context) {
    final image = MediaImage(
      item: item,
      preferBackdrop: false,
      maxWidth: imageMaxWidth,
    );
    return RepaintBoundary(
      child: MobilePressable(
        onTap: () {
          if (!_hasImage) {
            context.push(AppRoutes.item(item.id));
            return;
          }
          PhoneMotion.openItem(
            context,
            item,
            preferBackdrop: false,
            maxWidth: imageMaxWidth,
          );
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(AppRadii.md),
                  boxShadow: const [
                    BoxShadow(
                      color: Color.fromRGBO(0, 0, 0, AppMobileCard.shadowAlpha),
                      blurRadius: AppMobileCard.shadowBlur,
                      spreadRadius: AppMobileCard.shadowSpread,
                      offset: Offset(0, AppMobileCard.shadowOffsetY),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadii.md),
                  clipBehavior: Clip.hardEdge,
                  child: _hasImage
                      ? PhoneMotion.sharedImage(
                          itemId: item.id,
                          preferBackdrop: false,
                          child: image,
                        )
                      : image,
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xxs),
              child: Text(
                item.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 手机网格列数标定(T5):按内容宽度约 95dp 一格,360dp→3 列、
/// 412dp→4 列,随宽度自适应并 clamp 在 2–6 列。
int mobileGridColumnCount(double width) => (width / 95).floor().clamp(2, 6);

/// 手机端海报网格(T5):Wrap 换 GridView,列数走 [mobileGridColumnCount],
/// 间距走 [AppSpacing];图片懒加载沿用 media_image。
///
/// 默认嵌套在可滚动页内:shrinkWrap + 禁用自身滚动,滚动由外层负责。
class MobileGrid extends StatelessWidget {
  const MobileGrid({
    super.key,
    required this.items,
    this.itemBuilder,
    this.padding = EdgeInsets.zero,
  });

  final List<EmbyItem> items;

  /// 自定义卡片构建;null 时用 [MobilePoster]。调用方负责条目 key。
  final Widget Function(BuildContext context, EmbyItem item)? itemBuilder;

  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      const spacing = AppSpacing.md;
      final columns = mobileGridColumnCount(constraints.maxWidth);
      final cellWidth =
          (constraints.maxWidth - spacing * (columns - 1)) / columns;
      final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
      return GridView.builder(
        padding: padding,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          mainAxisSpacing: spacing,
          crossAxisSpacing: spacing,
          childAspectRatio: cellWidth / (cellWidth * 1.5 + 32 * textScale),
        ),
        itemCount: items.length,
        itemBuilder: (context, index) {
          final item = items[index];
          return itemBuilder?.call(context, item) ?? MobilePoster(item: item);
        },
      );
    },
  );
}
