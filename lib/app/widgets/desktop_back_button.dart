import 'package:flutter/material.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/home/catalog_keys.dart';

/// 桌面顶栏返回:胶囊按钮,图标加短标签。
///
/// 浅色始终用白底细边,因为浅色顶栏本身已接近实色,深色圆片会压成一块贴纸。
/// 深色实心顶栏用抬高的表面;叠在海报上时改成深色遮罩和白字,保证对比度。
class DesktopBackButton extends StatefulWidget {
  const DesktopBackButton({
    super.key,
    required this.tooltip,
    required this.onPressed,
    required this.icon,
    required this.label,
    required this.overArtwork,
  });

  final String tooltip;
  final VoidCallback onPressed;
  final IconData icon;
  final String label;

  /// 顶栏透出作品画面。浅色顶栏忽略这一档,仍用纸色胶囊。
  final bool overArtwork;

  @override
  State<DesktopBackButton> createState() => _DesktopBackButtonState();
}

class _DesktopBackButtonState extends State<DesktopBackButton> {
  bool _hover = false;
  bool _focus = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final light = scheme.brightness == Brightness.light;
    final artwork = widget.overArtwork && !light;
    final highlighted = _hover || _focus;
    final foreground = artwork ? Colors.white : scheme.onSurface;
    final artworkAlpha = AppScrim.of(context, AppScrim.control);
    final fill = artwork
        ? scheme.scrim.withValues(
            alpha: highlighted
                ? (artworkAlpha + 0.16).clamp(0.0, 1.0)
                : artworkAlpha,
          )
        : highlighted
        ? (light ? scheme.surfaceContainerHigh : scheme.surfaceContainerHighest)
        : (light ? scheme.surfaceContainerLowest : scheme.surfaceContainerHigh);
    final border = _focus
        ? (artwork ? Colors.white : scheme.primary)
        : artwork
        ? Colors.white.withValues(alpha: AppGlass.edgeLight)
        : scheme.outlineVariant;
    final labelStyle = theme.textTheme.labelLarge?.copyWith(
      color: foreground,
      fontSize: 13,
      fontWeight: FontWeight.w600,
      height: 1,
    );

    final duration = AppMotion.durationOf(context, AppMotion.fast);
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 600),
      child: AnimatedContainer(
        key: CatalogKeys.back,
        duration: duration,
        curve: AppMotion.standard,
        height: 36,
        decoration: ShapeDecoration(
          color: fill,
          shape: StadiumBorder(
            side: BorderSide(color: border, width: _focus ? 1.5 : 1),
          ),
          shadows: [
            BoxShadow(
              color: Colors.black.withValues(
                alpha: artwork ? .28 : (light ? .06 : .18),
              ),
              blurRadius: highlighted ? 12 : 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: widget.onPressed,
            onHover: (value) => setState(() => _hover = value),
            onFocusChange: (value) => setState(() => _focus = value),
            customBorder: const StadiumBorder(),
            splashFactory: NoSplash.splashFactory,
            overlayColor: const WidgetStatePropertyAll(Colors.transparent),
            mouseCursor: SystemMouseCursors.click,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 14, 0),
              child: IconTheme.merge(
                data: IconThemeData(color: foreground, size: 20),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 悬停时箭头向左挪一点,提示「往回」的方向。
                    AnimatedSlide(
                      offset: highlighted ? const Offset(-.12, 0) : Offset.zero,
                      duration: duration,
                      curve: AppMotion.standard,
                      child: Icon(widget.icon),
                    ),
                    const SizedBox(width: 4),
                    Text(widget.label, style: labelStyle),
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
