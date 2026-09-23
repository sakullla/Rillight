import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
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
  const MobilePoster({super.key, required this.item});
  final EmbyItem item;
  @override
  Widget build(BuildContext context) => Card(
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: () => context.push(AppRoutes.item(item.id)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: MediaImage(item: item, maxWidth: 400)),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              item.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    ),
  );
}

class MobileGrid extends StatelessWidget {
  const MobileGrid({super.key, required this.items});
  final List<EmbyItem> items;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final columns = (constraints.maxWidth / 165).floor().clamp(2, 6);
      final width = constraints.maxWidth / columns;
      final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
      return Wrap(
        children: [
          for (final item in items)
            SizedBox(
              width: width,
              height: width * 1.5 + 52 * textScale,
              child: MobilePoster(item: item),
            ),
        ],
      );
    },
  );
}
