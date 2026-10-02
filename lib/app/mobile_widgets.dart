import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/content_theme.dart';
import 'package:rillight/app/mobile_motion.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/library/item_format.dart';
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

/// 海报卡角标组的定位键:一张卡最多一组角标,测试据此把角标限定在卡内。
Key phoneCardBadgesKey(String itemId) => Key('phone-card-badges-$itemId');

/// 角标文案:分集给季集编号、剧集给季数、已看给已看标记、可续播给
/// 已看百分比(沿用 playbackProgress/resumeProgress 的既有语义)。
///
/// [includePlayback] 关闭时不给已看/进度角标:片库「最新入库」预览行只在
/// 入场时取一次数据,不随 reloadHomeRows 刷新,播动态角标会停留旧值。
List<String> phoneCardBadgeLabels(
  AppLocalizations l10n,
  EmbyItem item, {
  bool includePlayback = true,
}) {
  final labels = <String>[];
  if (item.isEpisode) {
    final code = seasonEpisodeCode(item);
    if (code != null) {
      labels.add(code);
    }
  } else if (item.isSeries && (item.childCount ?? 0) > 0) {
    labels.add(l10n.cardSeasonCount(item.childCount!));
  }
  if (includePlayback) {
    if (item.userData.played) {
      labels.add(l10n.mobileWatched);
    } else if (item.canResume) {
      labels.add(l10n.playbackProgress((item.playbackProgress * 100).round()));
    }
  }
  return labels;
}

/// 海报图角上的信息角标:半透明黑底胶囊,叠在图区上不遮挡点按。
class _PhoneCardBadge extends StatelessWidget {
  const _PhoneCardBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.scrim.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(AppRadii.sm),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Text(
          label,
          maxLines: 1,
          style: theme.textTheme.labelSmall?.copyWith(
            color: Colors.white,
            fontWeight: FontWeight.w600,
            height: 1.2,
          ),
        ),
      ),
    );
  }
}

/// 一张卡的角标组(ADR-3),多个角标从左到右排列、超出换行。
class PhoneCardBadges extends StatelessWidget {
  const PhoneCardBadges({
    super.key,
    required this.itemId,
    required this.labels,
  });

  final String itemId;
  final List<String> labels;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      key: phoneCardBadgesKey(itemId),
      spacing: AppSpacing.xxs,
      runSpacing: AppSpacing.xxs,
      children: [for (final label in labels) _PhoneCardBadge(label: label)],
    );
  }
}

/// 手机端 2:3 海报卡(ADR-2):AppRadii.md 圆角、图下 6px、bodyMedium w600
/// 标题、labelSmall onSurfaceVariant 年份行,可选图上胶囊角标与 Hero 飞行。
///
/// [width] 非空是横向行里的定宽卡(右侧留 xs 间距);为 null 时铺满父级
/// 宽度,供网格单元格使用——网格 childAspectRatio 须按
/// [phonePosterCardLabelExtent] 预留图下文字区。
class PhonePosterCard extends StatelessWidget {
  const PhonePosterCard({
    super.key,
    required this.item,
    this.width,
    this.pressKey,
    this.hero = false,
    this.includePlaybackBadges = true,
    this.imageMaxWidth = PhoneMotion.posterRequestWidth,
    this.onTap,
  });

  final EmbyItem item;

  /// 横向行里的固定卡宽;null 时铺满父级宽度(网格)。
  final double? width;

  /// 点按热区的行为键(如 CatalogKeys.item)。键语义归调用方,组件不假设。
  final Key? pressKey;

  /// 是否用 [PhoneMotion.sharedImage] 参与详情页飞行。同一路由里同一条目
  /// 只允许一张海报置 true,否则 Hero 标签重复。
  final bool hero;

  /// 是否显示已看/进度角标。只取一次数据的行传 false,避免角标停留旧值。
  final bool includePlaybackBadges;

  /// 请求图宽,默认 [PhoneMotion.posterRequestWidth];网格按单元格物理宽取。
  final int imageMaxWidth;

  /// 点按行为;默认 [PhoneMotion.openItem] 进详情。
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => ContentTheme(
    item: item,
    preferBackdrop: false,
    fillSurface: false,
    child: Builder(builder: _buildCard),
  );

  Widget _buildCard(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final badges = phoneCardBadgeLabels(
      l10n,
      item,
      includePlayback: includePlaybackBadges,
    );
    final image = MediaImage(
      item: item,
      maxWidth: imageMaxWidth,
      contributesToTheme: true,
    );
    final card = Material(
      color: theme.colorScheme.surface,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: MobilePressable(
        key: pressKey,
        onTap:
            onTap ??
            () => PhoneMotion.openItem(context, item, maxWidth: imageMaxWidth),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadii.md),
              child: AspectRatio(
                aspectRatio: 2 / 3,
                // 图缺失时 MediaImage 落主题化占位,底衬与页面分层。
                child: ColoredBox(
                  color: theme.colorScheme.surfaceContainerLow,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      hero
                          ? PhoneMotion.sharedImage(
                              itemId: item.id,
                              preferBackdrop: false,
                              child: image,
                            )
                          : image,
                      if (badges.isNotEmpty)
                        Positioned(
                          top: AppSpacing.xs,
                          left: AppSpacing.xs,
                          right: AppSpacing.xs,
                          child: PhoneCardBadges(
                            itemId: item.id,
                            labels: badges,
                          ),
                        ),
                      if (item.communityRating != null &&
                          item.communityRating! > 0)
                        Positioned(
                          right: 8,
                          bottom: 8,
                          child: _PhoneCardBadge(
                            label:
                                '★ ${item.communityRating!.toStringAsFixed(1)}',
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      height: 1.2,
                    ),
                  ),
                  if (item.productionYear != null && item.productionYear! > 0)
                    Text(
                      '${item.productionYear}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        height: 1.2,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    final width = this.width;
    if (width == null) {
      return card;
    }
    return Padding(
      padding: const EdgeInsets.only(right: AppSpacing.xs),
      child: SizedBox(width: width, child: card),
    );
  }
}

/// 海报主图是否存在:无标签的 Primary 兜底不算有图,避免把占位交出去。
bool phonePosterHasImage(EmbyItem item) {
  return item
      .imageCandidates(preferBackdrop: false)
      .any((ref) => ref.tag != null && ref.tag!.isNotEmpty);
}

/// 网格海报卡(ADR-3):铺满网格单元格的 [PhonePosterCard],带图上胶囊角标。
///
/// 有图时参与 Hero 飞行并带图交接进详情;无图直 push 详情,不出现占位飞行
/// (沿用原 MobilePoster 语义)。[onTap] 可覆盖默认导航(如相册进货架);
/// 与首页同屏可能重复出现条目时应把 [hero] 置 false,避免 Hero 标签撞车。
class PhoneGridPosterCard extends StatelessWidget {
  const PhoneGridPosterCard({
    super.key,
    required this.item,
    this.hero = true,
    this.includePlaybackBadges = true,
    this.imageMaxWidth = PhoneMotion.posterRequestWidth,
    this.onTap,
  });

  final EmbyItem item;

  /// 是否参与 Hero 飞行;仅在有图时生效。
  final bool hero;

  /// 是否显示已看/进度角标。只取一次数据的网格传 false,避免角标停留旧值。
  final bool includePlaybackBadges;

  /// 请求图宽,默认 [PhoneMotion.posterRequestWidth]。
  final int imageMaxWidth;

  /// 点按行为;默认按有无图走 [PhoneMotion.openItem] 或直 push 详情。
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final hasImage = phonePosterHasImage(item);
    return RepaintBoundary(
      child: PhonePosterCard(
        item: item,
        hero: hero && hasImage,
        includePlaybackBadges: includePlaybackBadges,
        imageMaxWidth: imageMaxWidth,
        onTap:
            onTap ??
            () {
              if (!hasImage) {
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
      ),
    );
  }
}

/// 网格海报卡图下文字区高度:6px 间距 + w600 标题行 + labelSmall 年份行。
/// 网格 childAspectRatio 与骨架共用,保证单元格刚好容纳网格态
/// [PhonePosterCard](年份缺失的卡片底部留空,不挤压图区 2:3)。
double phonePosterCardLabelExtent(BuildContext context) {
  final theme = Theme.of(context);
  double lineHeight(TextStyle? style) {
    final painter = TextPainter(
      text: TextSpan(text: 'Ag', style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final height = painter.height;
    painter.dispose();
    return height;
  }

  return 16 +
      2 *
          lineHeight(
            theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
              height: 1.2,
            ),
          ) +
      lineHeight(theme.textTheme.labelSmall?.copyWith(height: 1.2));
}

/// Readable poster widths: 360dp uses two columns, 412dp uses three.
/// System text scaling reduces columns instead of shrinking labels.
int mobileGridColumnCount(double width, {double textScale = 1}) =>
    ((width + AppSpacing.md) / (126 * textScale.clamp(1, 2))).floor().clamp(
      1,
      6,
    );

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

  /// 自定义卡片构建;null 时用 [PhoneGridPosterCard]。调用方负责条目 key。
  final Widget Function(BuildContext context, EmbyItem item)? itemBuilder;

  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      const spacing = AppSpacing.md;
      final columns = mobileGridColumnCount(
        constraints.maxWidth,
        textScale: MediaQuery.textScalerOf(context).scale(16) / 16,
      );
      final cellWidth =
          (constraints.maxWidth - spacing * (columns - 1)) / columns;
      final labelExtent = phonePosterCardLabelExtent(context);
      return GridView.builder(
        padding: padding,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          mainAxisSpacing: spacing,
          crossAxisSpacing: spacing,
          childAspectRatio: cellWidth / (cellWidth * 1.5 + labelExtent),
        ),
        itemCount: items.length,
        itemBuilder: (context, index) {
          final item = items[index];
          return itemBuilder?.call(context, item) ??
              PhoneGridPosterCard(item: item);
        },
      );
    },
  );
}
