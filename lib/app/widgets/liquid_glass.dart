import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:rillight/app/theme/tokens.dart';

enum LiquidGlassKind { bar, panel, control, pill }

/// 液态玻璃浮层:模糊 + 轻微饱和 + 顶部高光 + 细描边。
///
/// 只包导航、对话框、播放控件等浮层。海报墙不要用,滚动时 BackdropFilter
/// 会把解码和合成打满。减少动态效果时退回实色,避免透明不可读。
class LiquidGlass extends StatelessWidget {
  const LiquidGlass({
    super.key,
    required this.child,
    this.kind = LiquidGlassKind.panel,
    this.borderRadius,
    this.padding,
    this.width,
    this.height,
  });

  final Widget child;
  final LiquidGlassKind kind;
  final BorderRadius? borderRadius;
  final EdgeInsetsGeometry? padding;
  final double? width;
  final double? height;

  static bool reduced(BuildContext context) =>
      MediaQuery.disableAnimationsOf(context);

  BorderRadius get _radius {
    if (borderRadius != null) {
      return borderRadius!;
    }
    switch (kind) {
      case LiquidGlassKind.bar:
        return BorderRadius.zero;
      case LiquidGlassKind.panel:
        return BorderRadius.circular(AppRadii.xl);
      case LiquidGlassKind.control:
        return BorderRadius.circular(AppRadii.lg);
      case LiquidGlassKind.pill:
        return BorderRadius.circular(999);
    }
  }

  double get _sigma {
    switch (kind) {
      case LiquidGlassKind.bar:
        return AppGlass.barBlur;
      case LiquidGlassKind.panel:
        return AppGlass.panelBlur;
      case LiquidGlassKind.control:
        return AppGlass.controlBlur;
      case LiquidGlassKind.pill:
        return AppGlass.pillBlur;
    }
  }

  double get _tint {
    switch (kind) {
      case LiquidGlassKind.bar:
        return AppGlass.barTint;
      case LiquidGlassKind.panel:
        return AppGlass.panelTint;
      case LiquidGlassKind.control:
        return AppGlass.controlTint;
      case LiquidGlassKind.pill:
        return AppGlass.pillTint;
    }
  }

  static const _saturate = ColorFilter.matrix(<double>[
    1.168,
    -0.140,
    -0.028,
    0,
    0,
    -0.140,
    1.168,
    -0.028,
    0,
    0,
    -0.140,
    -0.140,
    1.280,
    0,
    0,
    0,
    0,
    0,
    1,
    0,
  ]);

  @override
  Widget build(BuildContext context) {
    final skipBlur = reduced(context);
    final scheme = Theme.of(context).colorScheme;
    final radius = _radius;
    final fill = scheme.surface.withValues(
      alpha: skipBlur ? AppGlass.reducedTint : _tint,
    );
    Widget body = child;
    if (padding != null) {
      body = Padding(padding: padding!, child: body);
    }
    return SizedBox(
      width: width,
      height: height,
      child: ClipRRect(
        borderRadius: radius,
        child: Stack(
          children: [
            if (!skipBlur)
              Positioned.fill(
                child: IgnorePointer(
                  child: ColorFiltered(
                    colorFilter: _saturate,
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: _sigma, sigmaY: _sigma),
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),
              ),
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: fill,
                    borderRadius: radius,
                    border: kind == LiquidGlassKind.bar
                        ? Border(
                            bottom: BorderSide(
                              color: Colors.white.withValues(
                                alpha: AppGlass.edgeLight,
                              ),
                            ),
                          )
                        : Border.all(
                            color: Colors.white.withValues(
                              alpha: AppGlass.edgeLight,
                            ),
                          ),
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      stops: const [0, 0.2, 1],
                      colors: [
                        Colors.white.withValues(alpha: AppGlass.specular),
                        Colors.white.withValues(alpha: 0.04),
                        Colors.transparent,
                      ],
                    ),
                  ),
                ),
              ),
            ),
            body,
          ],
        ),
      ),
    );
  }
}
