import 'package:flutter/material.dart';
import 'package:rillight/app/theme/tokens.dart';

/// 骨架屏 shimmer 块:圆角色块叠加循环扫过的渐变高亮。
///
/// 纯呈现组件,不持有业务数据;动画周期取 [AppMotion.slow] 的整数倍,
/// 保持在 token 时长体系内。
class SkeletonBlock extends StatefulWidget {
  const SkeletonBlock({super.key, this.width, this.height, this.borderRadius});

  final double? width;
  final double? height;

  /// 圆角,默认 [AppRadii.sm]。
  final BorderRadius? borderRadius;

  @override
  State<SkeletonBlock> createState() => _SkeletonBlockState();
}

class _SkeletonBlockState extends State<SkeletonBlock>
    with SingleTickerProviderStateMixin {
  /// shimmer 循环周期:slow 阶梯的四倍。
  static final Duration _period = AppMotion.slow * 4;

  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: _period)..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return SizedBox(
          width: widget.width,
          height: widget.height,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius:
                  widget.borderRadius ?? BorderRadius.circular(AppRadii.sm),
              gradient: LinearGradient(
                colors: [
                  colorScheme.surfaceContainerHigh,
                  colorScheme.surfaceContainerHighest,
                  colorScheme.surfaceContainerHigh,
                ],
                transform: _SweepGradientTransform(_controller.value),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 让高亮带随 [progress] 从左向右扫过色块。
class _SweepGradientTransform extends GradientTransform {
  const _SweepGradientTransform(this.progress);

  final double progress;

  @override
  Matrix4 transform(Rect bounds, {TextDirection? textDirection}) {
    return Matrix4.translationValues(bounds.width * (progress * 2 - 1), 0, 0);
  }
}

/// 横向海报骨架行,用于 shelf 加载占位。
class SkeletonShelfRow extends StatelessWidget {
  const SkeletonShelfRow({
    super.key,
    this.itemCount = 6,
    this.posterWidth = 132,
    this.posterAspectRatio = 2 / 3,
    this.spacing = AppSpacing.sm,
  });

  final int itemCount;
  final double posterWidth;

  /// 海报宽高比(宽/高),默认竖版 2:3。
  final double posterAspectRatio;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    final posterHeight = posterWidth / posterAspectRatio;
    const labelHeight = AppSpacing.sm;
    return SizedBox(
      height: posterHeight + AppSpacing.xs + labelHeight,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: itemCount,
        separatorBuilder: (context, index) => SizedBox(width: spacing),
        itemBuilder: (context, index) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SkeletonBlock(width: posterWidth, height: posterHeight),
              const SizedBox(height: AppSpacing.xs),
              SkeletonBlock(width: posterWidth * 0.75, height: labelHeight),
            ],
          );
        },
      ),
    );
  }
}

/// 网格骨架,用于媒体库/shelf 全集页加载占位。
class SkeletonPosterGrid extends StatelessWidget {
  const SkeletonPosterGrid({
    super.key,
    this.itemCount = 12,
    this.maxCrossAxisExtent = 180,
    this.childAspectRatio = 2 / 3,
    this.spacing = AppSpacing.md,
    this.padding = const EdgeInsets.all(AppSpacing.md),
  });

  final int itemCount;
  final double maxCrossAxisExtent;

  /// 网格项宽高比(宽/高),默认竖版 2:3。
  final double childAspectRatio;
  final double spacing;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: padding,
      itemCount: itemCount,
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: maxCrossAxisExtent,
        mainAxisSpacing: spacing,
        crossAxisSpacing: spacing,
        childAspectRatio: childAspectRatio,
      ),
      itemBuilder: (context, index) => const SkeletonBlock(),
    );
  }
}
