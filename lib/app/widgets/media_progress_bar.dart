import 'package:rillight/app/ui/ui.dart';

/// 续播进度条:海报/剧照封面上的一条细进度。
///
/// 4.5px 圆头、主题色实芯带微光,压在封面底部。比旧版 3px 直线更醒目,
/// 但仍是封面上的点缀,不抢内容。语义标签由 [label] 提供。
class MediaProgressBar extends StatelessWidget {
  const MediaProgressBar({
    super.key,
    required this.value,
    required this.label,
    this.height = 4.5,
  });

  /// 0–1 的进度比例。
  final double value;

  /// 无障碍标签,例如"已播放 45%"。
  final String label;

  /// 条高;封面底条用默认 4.5。
  final double height;

  @override
  Widget build(BuildContext context) {
    final scheme = AppUiTheme.of(context).colorScheme;
    return Semantics(
      container: true,
      label: label,
      child: SizedBox(
        height: height,
        child: ColoredBox(
          color: AppInk.black.withValues(alpha: 0.45),
          child: Align(
            alignment: Alignment.centerLeft,
            child: FractionallySizedBox(
              widthFactor: value.clamp(0.0, 1.0),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: scheme.primary,
                  borderRadius: BorderRadius.horizontal(
                    right: Radius.circular(height / 2),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: scheme.primary.withValues(alpha: 0.55),
                      blurRadius: 6,
                    ),
                  ],
                ),
                child: SizedBox(height: height),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
