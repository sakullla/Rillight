import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/routes.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/auth/failure_message.dart';
import 'package:rillight/emby/emby_errors.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/library/episode_list.dart';
import 'package:rillight/library/item_format.dart';
import 'package:rillight/media_image/media_image.dart';

/// 电视设计基准。
///
/// Android TV 不论 1080p(DPR 2)还是 4K(DPR 4)面板,大多给出约 960×540 的
/// 逻辑画布;少数机型是 1280×720 或 1920×1080。所有 TV 尺寸以 960 宽为 1 倍设计,
/// 再按视口宽度等比放大,任何分辨率下版面比例一致。图片请求另按物理像素
/// ([tvImageWidth])取,4K 下海报和背景图依然清晰。
abstract final class TvDesign {
  static const double canvasWidth = 960;
  static const double maxScale = 2.5;

  /// 竖版海报卡宽(1 倍)。960 画布一行露出约 6.5 张,提示还能右滑。
  static const double posterWidth = 120;

  /// 横版 16:9 卡宽(继续观看、分集、媒体库)。
  static const double wideWidth = 196;

  /// 卡片之间的横向间隔。
  static const double cardGap = 14;

  /// 分区之间的竖向间隔。
  static const double sectionGap = 28;

  /// 卡片/按钮圆角。
  static const double cardRadius = 8;
  static const double controlRadius = 10;

  static double scaleFor(Size size) =>
      (size.width / canvasWidth).clamp(1.0, maxScale).toDouble();

  static double scaleOf(BuildContext context) =>
      scaleFor(MediaQuery.sizeOf(context));
}

/// 以 960 画布为 1 倍的尺寸换算。
extension TvDp on BuildContext {
  double tvdp(double value) => value * TvDesign.scaleOf(this);
}

/// 图片请求宽度:逻辑宽 × DPR,4K 面板(DPR 4)拉足物理像素。
int tvImageWidth(BuildContext context, double logicalWidth, {int max = 1280}) {
  final px = (logicalWidth * MediaQuery.devicePixelRatioOf(context)).round();
  return px.clamp(160, max);
}

/// 视口左右安全区:不低于视口宽的 5%(960 画布下 48)。
double tvSafeGutter(double extent) => math.max(48.0, extent * 0.05);

/// 视口上下安全区:视口高的 5%(540 画布下 27)。
double tvSafeVertical(double extent) => math.max(24.0, extent * 0.05);

/// Repairs a removed remote target only on the visible route. Offstage panes
/// cannot receive focus; a surviving nearby target or navigation remains usable.
class TvFocusRegion extends StatefulWidget {
  const TvFocusRegion({super.key, required this.child});
  final Widget child;
  @override
  State<TvFocusRegion> createState() => _TvFocusRegionState();
}

class _TvFocusRegionState extends State<TvFocusRegion> {
  final _nodes = <FocusNode>{};
  final _scope = FocusScopeNode(debugLabel: 'TV visible targets');

  bool _legalTarget(FocusNode node) =>
      node is! FocusScopeNode &&
      node.context?.mounted == true &&
      node.canRequestFocus &&
      !node.skipTraversal &&
      node.ancestors.contains(_scope);
  Rect? _lastRect;
  bool _scheduled = false;
  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_schedule);
  }

  void selected(FocusNode node) {
    if (node.context != null) _lastRect = node.rect;
  }

  void remove(FocusNode node) {
    if (node.hasFocus && node.context != null) _lastRect = node.rect;
    _nodes.remove(node);
    _schedule();
  }

  void _schedule() {
    if (_scheduled || !mounted) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted ||
          ModalRoute.of(context)?.isCurrent != true ||
          _lastRect == null) {
        return;
      }
      final current = FocusManager.instance.primaryFocus;
      final currentContext = current?.context;
      // A root-navigator dialog can cover a nested route that still reports
      // isCurrent. Its scope/editor owns focus until the dialog is dismissed.
      if (currentContext != null) {
        final focusedRoute = ModalRoute.of(currentContext);
        if (focusedRoute != null &&
            focusedRoute != ModalRoute.of(context) &&
            focusedRoute.isCurrent) {
          return;
        }
      }
      // Material chips, dropdowns and cards are legitimate remote targets too.
      // Never steal their focus back to a registered nav TvAction each frame.
      if (current != null && _legalTarget(current)) {
        _lastRect = current.rect;
        return;
      }
      final candidates = _scope.descendants.where(_legalTarget).toList();
      candidates.sort(
        (a, b) => (a.rect.center - _lastRect!.center).distanceSquared.compareTo(
          (b.rect.center - _lastRect!.center).distanceSquared,
        ),
      );
      if (candidates.isNotEmpty) {
        candidates.first.requestFocus();
        FocusManager.instance.applyFocusChangesIfNeeded();
      }
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_schedule);
    _scope.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _TvFocusRegistry(
    owner: this,
    child: FocusScope(node: _scope, child: widget.child),
  );
}

class _TvFocusRegistry extends InheritedWidget {
  const _TvFocusRegistry({required this.owner, required super.child});
  final _TvFocusRegionState owner;
  @override
  bool updateShouldNotify(_TvFocusRegistry oldWidget) =>
      owner != oldWidget.owner;
}

/// [TvAction] 的外观。
enum TvActionVariant {
  /// 圆角按钮:半透明底,聚焦反相为实色。
  button,

  /// 圆形图标按钮。
  icon,

  /// 无底的文字按钮(分区「查看全部」、次要链接),聚焦时反相。
  ghost,

  /// 整行列表项(设置、选项面板)。
  tile,

  /// 卡片:不画底与圆角,由卡片自己画焦点环,只负责焦点、缩放与激活。
  card,
}

/// A stable, visible remote target. Its node survives rebuilds and route pushes.
///
/// 焦点表现:按钮类整块反相(深色主题下近白实底 + 深色字),与静止态的
/// 半透明底对比度远高于 3:1,减少动效时同样即时生效;卡片类另由卡片画
/// 高对比焦点环。聚焦项轻微放大,遥控器在 3 米外也能一眼找到。
class TvAction extends StatefulWidget {
  const TvAction({
    super.key,
    required this.child,
    required this.onPressed,
    this.autofocus = false,
    this.focusNode,
    this.selected = false,
    this.emphasized = false,
    this.pill = false,
    this.leading,
    this.trailing,
    this.variant = TvActionVariant.button,
    this.expand = false,
  });
  final Widget child;
  final FutureOr<void> Function()? onPressed;
  final bool autofocus, selected, emphasized;

  /// 胶囊形态:导航、筛选与季切换。
  final bool pill;

  /// 可选前导/尾随图标,与 [child] 横向排列。
  final Widget? leading;
  final Widget? trailing;
  final FocusNode? focusNode;
  final TvActionVariant variant;

  /// 按钮内容撑满宽度(列表项默认撑满)。
  final bool expand;

  /// 聚焦放大档位,落在 1.05–1.1。
  static const double focusedScale = 1.06;

  /// 卡片焦点环宽度(960 画布下 3,4K 面板上 12 物理像素)。
  static const double focusRingWidth = 3;

  /// 当前子树是否处在聚焦的 [TvAction] 内。
  static bool focusedOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_TvActionScope>()?.focused ??
      false;

  /// 次要文字色:聚焦反相时随前景走,否则用 onSurfaceVariant。
  static Color secondaryColor(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final scope = context.dependOnInheritedWidgetOfExactType<_TvActionScope>();
    if (scope?.inverted == true) {
      return scheme.onInverseSurface.withValues(alpha: .72);
    }
    return scheme.onSurfaceVariant;
  }

  @override
  State<TvAction> createState() => _TvActionState();
}

class _TvActionScope extends InheritedWidget {
  const _TvActionScope({
    required this.focused,
    required this.inverted,
    required super.child,
  });
  final bool focused, inverted;
  @override
  bool updateShouldNotify(_TvActionScope oldWidget) =>
      focused != oldWidget.focused || inverted != oldWidget.inverted;
}

class _TvActionState extends State<TvAction>
    with AutomaticKeepAliveClientMixin {
  final _ownedNode = FocusNode();
  bool get _focused => _node.hasFocus;
  _TvFocusRegionState? _region;
  bool _activating = false;
  FocusNode get _node => widget.focusNode ?? _ownedNode;
  @override
  void initState() {
    super.initState();
    _node.addListener(_changed);
  }

  @override
  void didUpdateWidget(covariant TvAction oldWidget) {
    super.didUpdateWidget(oldWidget);
    final previous = oldWidget.focusNode ?? _ownedNode;
    if (!identical(previous, _node)) {
      previous.removeListener(_changed);
      _node.addListener(_changed);
    }
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    updateKeepAlive();
    if (_node.hasFocus) {
      _region?.selected(_node);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            _node.hasFocus &&
            ModalRoute.of(context)?.isCurrent != false &&
            !_comfortablyVisible()) {
          Scrollable.ensureVisible(
            context,
            alignment: .5,
            duration: AppMotion.durationOf(context, AppMotion.normal),
            curve: AppMotion.standard,
          );
        }
      });
    }
  }

  /// 目标已完整落在屏内(避开顶部导航与底部安全区)时不滚动:
  /// 在 hero 按钮间移动不会把舞台推走,只有越界时才把目标移到视口中央。
  bool _comfortablyVisible() {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize || !box.attached) return false;
    final size = MediaQuery.sizeOf(context);
    final s = TvDesign.scaleOf(context);
    final rect = box.localToGlobal(Offset.zero) & box.size;
    return rect.top >= 64 * s &&
        rect.bottom <= size.height - 20 * s &&
        rect.left >= 0 &&
        rect.right <= size.width;
  }

  @override
  bool get wantKeepAlive => _focused;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final region = context
        .dependOnInheritedWidgetOfExactType<_TvFocusRegistry>()
        ?.owner;
    if (!identical(region, _region)) {
      _region?.remove(_node);
      _region = region;
      _region?._nodes.add(_node);
    }
  }

  Future<void> _activate() async {
    if (widget.onPressed == null || _activating) return;
    _activating = true;
    _node.requestFocus();
    FocusManager.instance.applyFocusChangesIfNeeded();
    try {
      await widget.onPressed!();
    } finally {
      _activating = false;
      // Navigation restores its own focus. A callback may open a root dialog
      // without returning its Future; requesting this node would dismiss the
      // editor's IME even while our nested route still reports isCurrent.
      if (mounted &&
          _node.canRequestFocus &&
          ModalRoute.of(context)?.isCurrent != false &&
          _node.nearestScope?.hasFocus == true) {
        _node.requestFocus();
      }
    }
  }

  @override
  void dispose() {
    _region?.remove(_node);
    _node.removeListener(_changed);
    _ownedNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final s = TvDesign.scaleOf(context);
    final variant = widget.variant;
    final focused = _focused;
    final card = variant == TvActionVariant.card;
    final inverted = focused && !card;
    final rest = scheme.onSurface;
    final Color fill;
    if (card) {
      fill = Colors.transparent;
    } else if (focused) {
      fill = scheme.inverseSurface;
    } else if (widget.emphasized) {
      fill = scheme.primary;
    } else {
      fill = switch (variant) {
        TvActionVariant.ghost =>
          widget.selected
              ? rest.withValues(alpha: .12)
              : rest.withValues(alpha: 0),
        TvActionVariant.tile => rest.withValues(
          alpha: widget.selected ? .12 : .06,
        ),
        _ => rest.withValues(alpha: widget.selected ? .2 : .1),
      };
    }
    final Color? foreground = inverted
        ? scheme.onInverseSurface
        : widget.emphasized && !card
        ? scheme.onPrimary
        : null;
    final EdgeInsets padding = switch (variant) {
      TvActionVariant.card => EdgeInsets.zero,
      TvActionVariant.icon => EdgeInsets.all(9 * s),
      TvActionVariant.ghost => EdgeInsets.symmetric(
        horizontal: 12 * s,
        vertical: 7 * s,
      ),
      TvActionVariant.tile => EdgeInsets.symmetric(
        horizontal: 16 * s,
        vertical: 11 * s,
      ),
      TvActionVariant.button => EdgeInsets.symmetric(
        horizontal: (widget.pill ? 20 : 16) * s,
        vertical: 9 * s,
      ),
    };
    final double radius = switch (variant) {
      TvActionVariant.card => 0,
      TvActionVariant.icon || TvActionVariant.ghost => 999,
      TvActionVariant.tile => TvDesign.controlRadius * s,
      TvActionVariant.button => widget.pill ? 999 : TvDesign.controlRadius * s,
    };
    final double minHeight = switch (variant) {
      TvActionVariant.card => 0,
      TvActionVariant.ghost => 34 * s,
      TvActionVariant.tile => 44 * s,
      _ => 38 * s,
    };
    final double scale = switch (variant) {
      TvActionVariant.tile => 1.02,
      _ => TvAction.focusedScale,
    };
    final expand = widget.expand || variant == TvActionVariant.tile;
    Widget content = widget.child;
    if (widget.leading != null || widget.trailing != null) {
      content = Row(
        mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
        children: [
          if (widget.leading != null) ...[
            widget.leading!,
            SizedBox(width: (variant == TvActionVariant.tile ? 12 : 8) * s),
          ],
          if (expand) Expanded(child: content) else Flexible(child: content),
          if (widget.trailing != null) ...[
            SizedBox(width: 10 * s),
            widget.trailing!,
          ],
        ],
      );
    }
    if (!card) {
      final textStyle = variant == TvActionVariant.tile
          ? theme.textTheme.bodyLarge
          : theme.textTheme.labelLarge;
      content = IconTheme.merge(
        data: IconThemeData(
          color: foreground ?? scheme.onSurface,
          size: (variant == TvActionVariant.tile ? 20 : 18) * s,
        ),
        child: DefaultTextStyle.merge(
          style: (textStyle ?? const TextStyle()).copyWith(
            color: foreground ?? scheme.onSurface,
            fontWeight: widget.selected || widget.emphasized
                ? FontWeight.w700
                : null,
          ),
          child: content,
        ),
      );
      if (variant == TvActionVariant.icon) {
        content = Center(widthFactor: 1, heightFactor: 1, child: content);
      }
    }
    final duration = AppMotion.durationOf(context, AppMotion.fast);
    return ExcludeFocus(
      excluding: widget.onPressed == null,
      child: FocusableActionDetector(
        focusNode: _node,
        autofocus: widget.autofocus,
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.select, includeRepeats: false):
              ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.enter, includeRepeats: false):
              ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space, includeRepeats: false):
              ActivateIntent(),
        },
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              unawaited(_activate());
              return null;
            },
          ),
        },
        child: Semantics(
          button: true,
          enabled: widget.onPressed != null,
          focused: focused,
          selected: widget.selected,
          child: GestureDetector(
            onTap: widget.onPressed == null ? null : _activate,
            child: _TvActionScope(
              focused: focused,
              inverted: inverted,
              child: AnimatedScale(
                scale: focused ? scale : 1.0,
                duration: AppMotion.durationOf(context, AppMotion.normal),
                curve: AppMotion.standard,
                child: AnimatedContainer(
                  duration: duration,
                  curve: AppMotion.standard,
                  padding: padding,
                  constraints: BoxConstraints(
                    minHeight: minHeight,
                    minWidth: variant == TvActionVariant.icon ? minHeight : 0,
                  ),
                  decoration: BoxDecoration(
                    color: fill,
                    borderRadius: BorderRadius.circular(radius),
                    boxShadow: inverted
                        ? [
                            BoxShadow(
                              blurRadius: 14 * s,
                              offset: Offset(0, 4 * s),
                              color: Colors.black.withValues(alpha: .35),
                            ),
                          ]
                        : null,
                  ),
                  child: Opacity(
                    opacity: widget.onPressed == null ? .38 : 1,
                    child: content,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TvStaged extends InheritedWidget {
  const _TvStaged({required super.child});
  @override
  bool updateShouldNotify(_TvStaged oldWidget) => false;
}

/// TV 舞台主题:按 960 画布换算字号、弹窗与 Material 控件的焦点样式。
///
/// 应用根部已套一层;页面里重复套用不会二次放大。
class TvStageTheme extends StatelessWidget {
  const TvStageTheme({super.key, required this.child});
  final Widget child;

  static ThemeData themeFor(ThemeData base, double s) {
    final t = base.textTheme;
    TextStyle? size(
      TextStyle? style,
      double fontSize, {
      FontWeight? weight,
      double? height,
    }) => style?.copyWith(
      fontSize: fontSize * s,
      fontWeight: weight,
      height: height,
      letterSpacing: 0,
    );
    final text = t.copyWith(
      displayLarge: size(t.displayLarge, 40, weight: FontWeight.w800),
      displayMedium: size(
        t.displayMedium,
        34,
        weight: FontWeight.w800,
        height: 1.12,
      ),
      displaySmall: size(
        t.displaySmall,
        28,
        weight: FontWeight.w700,
        height: 1.18,
      ),
      headlineLarge: size(t.headlineLarge, 26, weight: FontWeight.w700),
      headlineMedium: size(
        t.headlineMedium,
        22,
        weight: FontWeight.w700,
        height: 1.25,
      ),
      headlineSmall: size(t.headlineSmall, 19, weight: FontWeight.w600),
      titleLarge: size(t.titleLarge, 17, weight: FontWeight.w600, height: 1.3),
      titleMedium: size(t.titleMedium, 15, weight: FontWeight.w600),
      titleSmall: size(t.titleSmall, 13.5, weight: FontWeight.w600),
      bodyLarge: size(t.bodyLarge, 15, height: 1.45),
      bodyMedium: size(t.bodyMedium, 13.5, height: 1.45),
      bodySmall: size(t.bodySmall, 12, height: 1.4),
      labelLarge: size(t.labelLarge, 14, weight: FontWeight.w600),
      labelMedium: size(t.labelMedium, 12.5, weight: FontWeight.w500),
      labelSmall: size(t.labelSmall, 11, weight: FontWeight.w500),
    );
    final scheme = base.colorScheme;
    // 遥控器聚焦到原生 Material 控件(弹窗按钮、开关)时同样整块反相。
    ButtonStyle focusInverts() => ButtonStyle(
      backgroundColor: WidgetStateProperty.resolveWith(
        (states) =>
            states.contains(WidgetState.focused) ? scheme.inverseSurface : null,
      ),
      foregroundColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.focused)
            ? scheme.onInverseSurface
            : null,
      ),
      textStyle: WidgetStatePropertyAll(text.labelLarge),
      padding: WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 16 * s, vertical: 9 * s),
      ),
      minimumSize: WidgetStatePropertyAll(Size(0, 38 * s)),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(TvDesign.controlRadius * s),
        ),
      ),
    );
    return base.copyWith(
      textTheme: text,
      focusColor: scheme.onSurface.withValues(alpha: .16),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainer,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        insetPadding: EdgeInsets.symmetric(
          horizontal: 48 * s,
          vertical: 27 * s,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16 * s),
        ),
        titleTextStyle: text.headlineSmall?.copyWith(color: scheme.onSurface),
        contentTextStyle: text.bodyMedium?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: focusInverts().merge(base.textButtonTheme.style),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: focusInverts().merge(base.filledButtonTheme.style),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: focusInverts().merge(base.outlinedButtonTheme.style),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.focused)
                ? scheme.inverseSurface
                : null,
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.focused)
                ? scheme.onInverseSurface
                : scheme.onSurface,
          ),
          iconSize: WidgetStatePropertyAll(22 * s),
        ),
      ),
      snackBarTheme: base.snackBarTheme.copyWith(
        contentTextStyle: text.bodyMedium,
        insetPadding: EdgeInsets.fromLTRB(48 * s, 0, 48 * s, 27 * s),
      ),
      listTileTheme: base.listTileTheme.copyWith(
        titleTextStyle: text.bodyLarge?.copyWith(color: scheme.onSurface),
        subtitleTextStyle: text.bodySmall?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
        selectedTileColor: scheme.onSurface.withValues(alpha: .1),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(TvDesign.controlRadius * s),
        ),
      ),
      inputDecorationTheme: base.inputDecorationTheme.copyWith(
        contentPadding: EdgeInsets.symmetric(
          horizontal: 16 * s,
          vertical: 14 * s,
        ),
        labelStyle: text.bodyMedium,
        hintStyle: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(TvDesign.controlRadius * s),
          borderSide: BorderSide(color: scheme.onSurface, width: 2 * s),
        ),
      ),
      progressIndicatorTheme: base.progressIndicatorTheme.copyWith(
        linearMinHeight: 3 * s,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (context.getInheritedWidgetOfExactType<_TvStaged>() != null) {
      return child;
    }
    final s = TvDesign.scaleOf(context);
    return _TvStaged(
      child: Theme(data: themeFor(Theme.of(context), s), child: child),
    );
  }
}

/// 页面标题:大标题 + 可选副标题 + 右侧操作。
class TvPageHeader extends StatelessWidget {
  const TvPageHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.actions = const [],
  });
  final String title;
  final String? subtitle;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = TvDesign.scaleOf(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.headlineMedium,
              ),
              if (subtitle case final value? when value.isNotEmpty) ...[
                SizedBox(height: 2 * s),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
        for (final action in actions) ...[SizedBox(width: 10 * s), action],
      ],
    );
  }
}

/// 分区标题:一行加粗小标题,可带尾随操作或计数。
class TvSectionTitle extends StatelessWidget {
  const TvSectionTitle(this.text, {super.key, this.trailing, this.padding});
  final String text;
  final Widget? trailing;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = TvDesign.scaleOf(context);
    return Padding(
      padding: padding ?? EdgeInsets.only(bottom: 4 * s),
      child: Row(
        children: [
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleLarge,
            ),
          ),
          if (trailing != null) ...[SizedBox(width: 12 * s), trailing!],
        ],
      ),
    );
  }
}

/// 标准页框:安全区内的大标题,内容铺满宽度。
///
/// 内容自己的滚动视图应以 [TvFrame.contentPadding] 作内边距,而不是被外层
/// Padding 收窄:聚焦放大与焦点环才不会在左右被裁(实机 F1/F2)。
class TvFrame extends StatelessWidget {
  const TvFrame({
    super.key,
    required this.title,
    required this.child,
    this.back = true,
    this.edgeToEdge = false,
    this.subtitle,
    this.actions = const [],
  });
  final String title;
  final Widget child;

  /// 遥控器自带返回键;保留参数以兼容调用方,不再画屏幕返回钮。
  final bool back;

  /// 出血模式:child 铺满整个视口,自行处理标题与留白。
  final bool edgeToEdge;
  final String? subtitle;
  final List<Widget> actions;

  /// 内容区左右与底部留白。
  static EdgeInsets contentPadding(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return EdgeInsets.fromLTRB(
      tvSafeGutter(size.width),
      0,
      tvSafeGutter(size.width),
      tvSafeVertical(size.height),
    );
  }

  @override
  Widget build(BuildContext context) {
    final viewSize = MediaQuery.sizeOf(context);
    final horizontal = tvSafeGutter(viewSize.width);
    final vertical = tvSafeVertical(viewSize.height);
    final s = TvDesign.scaleOf(context);
    return TvStageTheme(
      child: TvFocusRegion(
        child: Scaffold(
          body: edgeToEdge
              ? FocusTraversalGroup(child: child)
              : SafeArea(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        key: const Key('tv-frame-header'),
                        padding: EdgeInsets.fromLTRB(
                          horizontal,
                          vertical,
                          horizontal,
                          14 * s,
                        ),
                        child: TvPageHeader(
                          title: title,
                          subtitle: subtitle,
                          actions: actions,
                        ),
                      ),
                      Expanded(child: FocusTraversalGroup(child: child)),
                    ],
                  ),
                ),
        ),
      ),
    );
  }
}

class TvFailure extends StatelessWidget {
  const TvFailure({super.key, required this.error, required this.retry});
  final EmbyException error;
  final VoidCallback retry;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = TvDesign.scaleOf(context);
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 6 * s),
      child: Row(
        children: [
          Icon(
            Icons.error_outline_rounded,
            size: 20 * s,
            color: theme.colorScheme.error,
          ),
          SizedBox(width: 10 * s),
          Flexible(
            child: Text(
              embyFailureMessage(AppLocalizations.of(context), error),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium,
            ),
          ),
          SizedBox(width: 14 * s),
          TvAction(
            autofocus: true,
            leading: const Icon(Icons.refresh_rounded),
            onPressed: retry,
            child: Text(AppLocalizations.of(context).retry),
          ),
        ],
      ),
    );
  }
}

/// 居中的空态/提示:图标 + 一句话 + 可选操作。
class TvEmptyState extends StatelessWidget {
  const TvEmptyState({
    super.key,
    required this.message,
    this.icon = Icons.inbox_outlined,
    this.action,
  });
  final String message;
  final IconData icon;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = TvDesign.scaleOf(context);
    return Center(
      child: Padding(
        padding: EdgeInsets.all(24 * s),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40 * s, color: theme.colorScheme.onSurfaceVariant),
            SizedBox(height: 12 * s),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (action != null) ...[SizedBox(height: 16 * s), action!],
          ],
        ),
      ),
    );
  }
}

double _lineHeight(BuildContext context, TextStyle? style) {
  final painter = TextPainter(
    text: TextSpan(text: '海报Ag', style: style),
    textDirection: TextDirection.ltr,
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();
  final height = painter.height;
  painter.dispose();
  return height.ceilToDouble();
}

/// 卡片尺寸与图片请求宽度。
class TvCardMetrics {
  const TvCardMetrics({
    required this.width,
    required this.imageHeight,
    required this.height,
    required this.focusRoom,
    required this.imageMaxWidth,
  });

  /// 卡宽、图高、整卡高(含标题行)。
  final double width, imageHeight, height;

  /// 聚焦放大和焦点环在卡外需要的留白。
  final double focusRoom;
  final int imageMaxWidth;

  static TvCardMetrics of(
    BuildContext context, {
    bool wide = false,
    double? width,
    bool subtitle = false,
  }) {
    final s = TvDesign.scaleOf(context);
    final theme = Theme.of(context);
    final w = width ?? (wide ? TvDesign.wideWidth : TvDesign.posterWidth) * s;
    final image = wide ? w * 9 / 16 : w * 1.5;
    final title = _lineHeight(context, theme.textTheme.bodyMedium);
    final sub = subtitle
        ? _lineHeight(context, theme.textTheme.labelMedium)
        : 0;
    return TvCardMetrics(
      width: w,
      imageHeight: image,
      height: image + 8 * s + title + sub,
      focusRoom: (image * (TvAction.focusedScale - 1) / 2 + 6 * s)
          .ceilToDouble(),
      imageMaxWidth: tvImageWidth(context, w, max: wide ? 1280 : 720),
    );
  }
}

/// 现代 TV 海报卡:圆角封面 + 标题,不画底框。
///
/// 聚焦:整卡放大、封面加高对比焦点环与投影、标题转为主文字色。
/// [wide] 为 16:9 横版(继续观看、分集),竖版为 2:3。
class TvCard extends StatefulWidget {
  const TvCard({
    super.key,
    required this.item,
    this.autofocus = false,
    this.imageMaxWidth = 280,
    this.focusNode,
    this.wide = false,
    this.onPressed,
    this.title,
    this.subtitle,
    this.badge,
    this.current = false,
    this.imageWidth,
    this.preferBackdrop,
  });
  final EmbyItem item;
  final bool autofocus;
  final int imageMaxWidth;

  /// 给定时按该宽度与卡片比例固定封面尺寸(媒体库横幅拼图)。
  final double? imageWidth;

  /// 覆盖封面取图偏好;媒体库横幅取主图而不是背景图。
  final bool? preferBackdrop;
  final FocusNode? focusNode;

  /// 16:9 横版卡。
  final bool wide;

  /// 默认打开条目详情。
  final FutureOr<void> Function()? onPressed;

  /// 覆盖默认标题/副标题。
  final String? title, subtitle;

  /// 封面右下角的小标签(时长等)。
  final String? badge;

  /// 当前播放集:封面中央显示播放图标。
  final bool current;

  /// 卡片默认文字。横版剧集卡主标题为剧名,副标题为季集与集名。
  static (String, String?) labelsFor(EmbyItem item, {required bool wide}) {
    if (wide && item.isEpisode) {
      final series = item.seriesName;
      final detail = continueWatchingSubtitle(item);
      if (series != null && series.isNotEmpty) {
        return (series, detail.isEmpty ? null : detail);
      }
      return (episodeLabel(item), null);
    }
    return (item.name, null);
  }

  @override
  State<TvCard> createState() => _TvCardState();
}

class _TvCardState extends State<TvCard> {
  final _ownedNode = FocusNode();
  FocusNode get _node => widget.focusNode ?? _ownedNode;
  bool get _focused => _node.hasFocus;

  @override
  void initState() {
    super.initState();
    _node.addListener(_changed);
  }

  @override
  void didUpdateWidget(covariant TvCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final previous = oldWidget.focusNode ?? _ownedNode;
    if (!identical(previous, _node)) {
      previous.removeListener(_changed);
      _node.addListener(_changed);
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _node.removeListener(_changed);
    _ownedNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final s = TvDesign.scaleOf(context);
    final progress = item.playbackProgress;
    final played = item.userData.played;
    final focused = _focused;
    final defaults = TvCard.labelsFor(item, wide: widget.wide);
    final title = widget.title ?? defaults.$1;
    final subtitle = widget.subtitle ?? defaults.$2;
    final radius = BorderRadius.circular(TvDesign.cardRadius * s);
    final duration = AppMotion.durationOf(context, AppMotion.fast);
    return TvAction(
      autofocus: widget.autofocus,
      focusNode: _node,
      variant: TvActionVariant.card,
      onPressed:
          widget.onPressed ?? () => context.push(AppRoutes.item(item.id)),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 网格单元给定高度时封面吃掉剩余高度,任何单元比例都不溢出;
          // 行内卡片高度不限,按 2:3 / 16:9 排。
          final fitted = constraints.hasTightHeight;
          final cover = AnimatedContainer(
            duration: duration,
            curve: AppMotion.standard,
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHigh,
              borderRadius: radius,
              boxShadow: focused
                  ? [
                      BoxShadow(
                        blurRadius: 18 * s,
                        offset: Offset(0, 6 * s),
                        color: Colors.black.withValues(alpha: .45),
                      ),
                    ]
                  : const [],
            ),
            foregroundDecoration: BoxDecoration(
              borderRadius: radius,
              border: Border.all(
                color: focused ? scheme.onSurface : Colors.transparent,
                width: TvAction.focusRingWidth * s,
                strokeAlign: BorderSide.strokeAlignOutside,
              ),
            ),
            child: ClipRRect(
              borderRadius: radius,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  RepaintBoundary(
                    child: MediaImage(
                      item: item,
                      maxWidth: widget.imageMaxWidth,
                      width: widget.imageWidth,
                      height: widget.imageWidth == null
                          ? null
                          : widget.imageWidth! / (widget.wide ? 16 / 9 : 2 / 3),
                      fit: BoxFit.cover,
                      preferThumb: widget.wide,
                      preferBackdrop: widget.preferBackdrop ?? false,
                    ),
                  ),
                  if (progress > 0 && !played)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: LinearProgressIndicator(
                        value: progress,
                        minHeight: 3 * s,
                        color: scheme.primary,
                        backgroundColor: Colors.black.withValues(alpha: .5),
                      ),
                    ),
                  if (widget.badge case final badge?)
                    Positioned(
                      right: 6 * s,
                      bottom: (progress > 0 && !played ? 9 : 6) * s,
                      child: EpisodeThumbBadge(label: badge),
                    ),
                  if (played)
                    Positioned(
                      right: 6 * s,
                      top: 6 * s,
                      child: EpisodeWatchedBadge(size: 16 * s),
                    ),
                  if (widget.current)
                    Center(
                      child: Icon(
                        Icons.play_circle_fill_rounded,
                        key: const Key('tv-episode-current'),
                        size: 36 * s,
                        color: Colors.white.withValues(alpha: .92),
                      ),
                    ),
                ],
              ),
            ),
          );
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: fitted ? MainAxisSize.max : MainAxisSize.min,
            children: [
              if (fitted)
                Expanded(child: cover)
              else
                AspectRatio(
                  aspectRatio: widget.wide ? 16 / 9 : 2 / 3,
                  child: cover,
                ),
              SizedBox(height: 8 * s),
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurface,
                  fontWeight: focused ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
              if (subtitle != null && subtitle.isNotEmpty)
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: scheme.onSurfaceVariant.withValues(alpha: .8),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class TvPoster extends StatelessWidget {
  const TvPoster({
    super.key,
    required this.item,
    this.autofocus = false,
    this.imageMaxWidth = 280,
    this.focusNode,
    this.wide = false,
    this.onPressed,
  });
  final EmbyItem item;
  final bool autofocus;
  final int imageMaxWidth;
  final FocusNode? focusNode;

  /// 16:9 横版卡(继续观看行)。
  final bool wide;
  final FutureOr<void> Function()? onPressed;
  @override
  Widget build(BuildContext context) => TvCard(
    key: key,
    item: item,
    autofocus: autofocus,
    imageMaxWidth: imageMaxWidth,
    focusNode: focusNode,
    wide: wide,
    onPressed: onPressed,
  );
}

/// 带行级焦点记忆的横向卡片行:记住上次焦点项,焦点从行外进入时落回该项。
///
/// 行铺满屏宽、内边距对齐安全区,不裁剪:滑到左侧的卡片一直显示到屏幕
/// 边缘,聚焦放大与焦点环也不会被行的上下边界切掉。
class TvItemRow extends StatefulWidget {
  const TvItemRow({
    super.key,
    required this.title,
    required this.items,
    this.wide = false,
    this.onPressed,
    this.cardBuilder,
    this.width,
    this.subtitle,
    this.trailing,
  });

  /// 行尾附加项(如「查看全部」),与卡片同尺寸。
  final Widget Function(BuildContext context, TvCardMetrics metrics)? trailing;

  /// 行标识,用于 `tv-row-<title>` 键与滚动位置记忆。
  final String title;
  final List<EmbyItem> items;
  final bool wide;

  /// 覆盖卡宽(逻辑像素,已换算)。
  final double? width;

  /// 卡片是否带副标题行;默认横版剧集行带。
  final bool? subtitle;
  final FutureOr<void> Function(EmbyItem item)? onPressed;

  /// 完全自定义卡片;仍由行提供焦点节点。
  final Widget Function(
    BuildContext context,
    EmbyItem item,
    FocusNode focusNode,
    TvCardMetrics metrics,
  )?
  cardBuilder;

  @override
  State<TvItemRow> createState() => _TvItemRowState();
}

class _TvItemRowState extends State<TvItemRow> {
  final _nodes = <String, FocusNode>{};
  final _scroll = ScrollController();
  final _trailingFocus = FocusNode(canRequestFocus: false);
  int? _pendingIndex;
  String? _lastId;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    if ((event is! KeyDownEvent && event is! KeyRepeatEvent) ||
        (key != LogicalKeyboardKey.arrowLeft &&
            key != LogicalKeyboardKey.arrowRight)) {
      return KeyEventResult.ignored;
    }
    final index =
        _pendingIndex ??
        (_trailingFocus.hasFocus
            ? widget.items.length
            : widget.items.indexWhere(
                (item) => _nodes[item.id]?.hasFocus == true,
              ));
    if (index < 0) return KeyEventResult.ignored;
    final forward =
        (key == LogicalKeyboardKey.arrowRight) ==
        (Directionality.of(context) == TextDirection.ltr);
    final target = index + (forward ? 1 : -1);
    final count = widget.items.length + (widget.trailing == null ? 0 : 1);
    // Horizontal traversal belongs to this shelf, including its end tile.
    // Geometric traversal otherwise jumps diagonally into a different shelf.
    if (target < 0 || target >= count) return KeyEventResult.handled;
    FocusNode? targetNode() => target == widget.items.length
        ? _trailingFocus.traversalDescendants.firstOrNull
        : _nodes[widget.items[target].id];
    final next = targetNode();
    if (next?.context != null && next!.canRequestFocus) {
      next.requestFocus();
      return KeyEventResult.handled;
    }
    // Lazy rows do not have focus nodes for distant cards yet. Reveal the
    // adjacent slot before requesting it, rather than escaping the row.
    if (_scroll.hasClients) {
      _pendingIndex = target;
      final metrics = TvCardMetrics.of(
        context,
        wide: widget.wide,
        width: widget.width,
      );
      final pitch = metrics.width + context.tvdp(TvDesign.cardGap);
      _scroll.jumpTo(
        (target * pitch).clamp(0.0, _scroll.position.maxScrollExtent),
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _pendingIndex != target) return;
        _pendingIndex = null;
        final next = targetNode();
        if (next?.context != null && next!.canRequestFocus) next.requestFocus();
      });
    }
    return KeyEventResult.handled;
  }

  FocusNode _nodeFor(EmbyItem item) {
    return _nodes.putIfAbsent(item.id, () {
      final node = FocusNode(debugLabel: 'tv-row-${item.id}');
      node.addListener(() {
        if (node.hasFocus) _lastId = item.id;
      });
      return node;
    });
  }

  void _prune() {
    final ids = widget.items.map((item) => item.id).toSet();
    for (final id in _nodes.keys.toList()) {
      if (!ids.contains(id)) {
        _nodes.remove(id)?.dispose();
        if (_lastId == id) _lastId = null;
      }
    }
  }

  void _onRowFocus(bool focused) {
    if (!focused) return;
    final last = _lastId;
    if (last == null) return;
    final node = _nodes[last];
    final primary = FocusManager.instance.primaryFocus;
    // 焦点刚从行外进入:方向遍历落在位移最近项,改落回上次焦点项;
    // 该项滚出视口未构建或不可聚焦时保持遍历结果。
    if (node != null &&
        node != primary &&
        node.context?.mounted == true &&
        node.canRequestFocus) {
      node.requestFocus();
    }
  }

  @override
  void didUpdateWidget(covariant TvItemRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    _prune();
  }

  @override
  void dispose() {
    _scroll.dispose();
    _trailingFocus.dispose();
    for (final node in _nodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _prune();
    final wide = widget.wide;
    final s = TvDesign.scaleOf(context);
    final hasSubtitle =
        widget.subtitle ?? (wide && widget.items.any((i) => i.isEpisode));
    final metrics = TvCardMetrics.of(
      context,
      wide: wide,
      width: widget.width,
      subtitle: hasSubtitle,
    );
    final gutter = tvSafeGutter(MediaQuery.sizeOf(context).width);
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: _onRowFocus,
      onKeyEvent: _onKey,
      child: SizedBox(
        key: ValueKey('tv-row-${widget.title}'),
        height: metrics.height + metrics.focusRoom * 2,
        child: ListView.separated(
          controller: _scroll,
          key: PageStorageKey('tv-row-${widget.title}'),
          scrollDirection: Axis.horizontal,
          clipBehavior: Clip.none,
          padding: EdgeInsets.symmetric(
            horizontal: gutter,
            vertical: metrics.focusRoom,
          ),
          itemCount: widget.items.length + (widget.trailing == null ? 0 : 1),
          separatorBuilder: (context, index) =>
              SizedBox(width: TvDesign.cardGap * s),
          itemBuilder: (context, index) {
            if (index == widget.items.length) {
              return SizedBox(
                key: const ValueKey('tv-row-trailing'),
                width: metrics.width,
                child: Align(
                  alignment: Alignment.topCenter,
                  child: Focus(
                    focusNode: _trailingFocus,
                    skipTraversal: true,
                    child: widget.trailing!(context, metrics),
                  ),
                ),
              );
            }
            final item = widget.items[index];
            final node = _nodeFor(item);
            return SizedBox(
              key: ValueKey(item.id),
              width: metrics.width,
              child: Align(
                alignment: Alignment.topCenter,
                child:
                    widget.cardBuilder?.call(context, item, node, metrics) ??
                    TvCard(
                      item: item,
                      wide: wide,
                      focusNode: node,
                      imageMaxWidth: metrics.imageMaxWidth,
                      onPressed: widget.onPressed == null
                          ? null
                          : () => widget.onPressed!(item),
                    ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// 行尾「查看全部」:与卡片封面同尺寸的圆角块,聚焦时反相。
class TvMoreTile extends StatelessWidget {
  const TvMoreTile({
    super.key,
    required this.metrics,
    required this.onPressed,
    this.label,
  });
  final TvCardMetrics metrics;
  final FutureOr<void> Function()? onPressed;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final s = TvDesign.scaleOf(context);
    final text = label ?? AppLocalizations.of(context).tvViewAll;
    return SizedBox(
      width: metrics.width,
      height: metrics.imageHeight,
      child: TvAction(
        variant: TvActionVariant.tile,
        onPressed: onPressed,
        child: Builder(
          builder: (context) => Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.arrow_forward_rounded, size: 26 * s),
              SizedBox(height: 8 * s),
              Text(
                text,
                textAlign: TextAlign.center,
                maxLines: 2,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: DefaultTextStyle.of(context).style.color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 行加载骨架:与真实卡片同尺寸,加载完成不跳版。
class TvRowSkeleton extends StatelessWidget {
  const TvRowSkeleton({super.key, this.wide = false});
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final metrics = TvCardMetrics.of(context, wide: wide);
    final s = TvDesign.scaleOf(context);
    final gutter = tvSafeGutter(MediaQuery.sizeOf(context).width);
    final color = Theme.of(
      context,
    ).colorScheme.onSurface.withValues(alpha: .07);
    return SizedBox(
      height: metrics.height + metrics.focusRoom * 2,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.symmetric(
          horizontal: gutter,
          vertical: metrics.focusRoom,
        ),
        itemCount: 8,
        separatorBuilder: (context, index) =>
            SizedBox(width: TvDesign.cardGap * s),
        itemBuilder: (context, index) => SizedBox(
          width: metrics.width,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                height: metrics.imageHeight,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(TvDesign.cardRadius * s),
                ),
              ),
              SizedBox(height: 10 * s),
              Container(
                width: metrics.width * .7,
                height: 12 * s,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(4 * s),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class TvGrid extends StatelessWidget {
  const TvGrid({super.key, required this.items});
  final List<EmbyItem> items;

  /// 列数:960 画布内容区约 7 列。
  static int columnCount(double width, [double scale = 1]) =>
      ((width + TvDesign.cardGap * scale) / ((104 + TvDesign.cardGap) * scale))
          .floor()
          .clamp(3, 10);

  /// [width] 为去掉左右安全区后的内容宽。
  static TvGridMetrics metricsFor(BuildContext context, double width) {
    final s = TvDesign.scaleOf(context);
    final columns = columnCount(width, s);
    final gap = TvDesign.cardGap * s;
    final cell = (width - gap * (columns - 1)) / columns;
    final card = TvCardMetrics.of(context, width: cell);
    return TvGridMetrics(
      columns: columns,
      imageMaxWidth: card.imageMaxWidth,
      childAspectRatio: cell / card.height,
      crossAxisSpacing: gap,
      mainAxisSpacing: 22 * s,
    );
  }

  @override
  Widget build(BuildContext context) {
    final padding = TvFrame.contentPadding(context);
    final metrics = metricsFor(
      context,
      MediaQuery.sizeOf(context).width - padding.horizontal,
    );
    return SliverPadding(
      padding: EdgeInsets.symmetric(horizontal: padding.left),
      sliver: TvPosterSliver(items: items, metrics: metrics),
    );
  }
}

class TvGridMetrics {
  const TvGridMetrics({
    required this.columns,
    required this.imageMaxWidth,
    required this.childAspectRatio,
    this.crossAxisSpacing = 0,
    this.mainAxisSpacing = 0,
  });

  final int columns;
  final int imageMaxWidth;
  final double childAspectRatio;
  final double crossAxisSpacing;
  final double mainAxisSpacing;

  SliverGridDelegate get delegate => SliverGridDelegateWithFixedCrossAxisCount(
    crossAxisCount: columns,
    childAspectRatio: childAspectRatio,
    crossAxisSpacing: crossAxisSpacing,
    mainAxisSpacing: mainAxisSpacing,
  );
}

/// 只构建视口内的海报。列数在滚动视图外算好，避免每滚一帧重建整屏。
class TvPosterSliver extends StatelessWidget {
  const TvPosterSliver({super.key, required this.items, required this.metrics});

  final List<EmbyItem> items;
  final TvGridMetrics metrics;

  @override
  Widget build(BuildContext context) {
    return SliverGrid(
      gridDelegate: metrics.delegate,
      delegate: _TvPosterDelegate(items: items, metrics: metrics),
    );
  }
}

class _TvPosterDelegate extends SliverChildBuilderDelegate {
  _TvPosterDelegate({required this.items, required TvGridMetrics metrics})
    : super(
        (context, index) => TvPoster(
          key: ValueKey(items[index].id),
          item: items[index],
          imageMaxWidth: metrics.imageMaxWidth,
        ),
        childCount: items.length,
        addAutomaticKeepAlives: false,
        findChildIndexCallback: (key) {
          if (key is! ValueKey<String>) return null;
          final index = items.indexWhere((item) => item.id == key.value);
          return index < 0 ? null : index;
        },
      );

  final List<EmbyItem> items;

  @override
  bool shouldRebuild(covariant _TvPosterDelegate oldDelegate) {
    return !identical(oldDelegate.items, items);
  }
}

/// 遥控器文本框:平时像输入框一样显示标签与当前值,确认键才进入编辑,
/// 方向键不会被输入法吞掉。
class TvInput extends StatelessWidget {
  const TvInput({
    super.key,
    required this.label,
    required this.controller,
    this.autofocus = false,
    this.secret = false,
    this.pill = false,
    this.leading,
    this.onSubmitted,
    this.placeholder,
    this.keyboardType,
  });
  final String label;
  final TextEditingController controller;
  final bool autofocus, secret;

  /// 胶囊形态(搜索条):单行,值为空时显示标签作占位。
  final bool pill;

  /// 可选前导图标。
  final Widget? leading;
  final VoidCallback? onSubmitted;

  /// 值为空时的提示文字;缺省「未填写」式的弱化标签。
  final String? placeholder;
  final TextInputType? keyboardType;

  Future<void> _edit(BuildContext context) async {
    await showDialog<void>(
      context: context,
      useRootNavigator: false,
      builder: (context) {
        final s = TvDesign.scaleOf(context);
        return AlertDialog(
          title: Text(label),
          content: SizedBox(
            width: 520 * s,
            child: TextField(
              key: const Key('tv-input-editor'),
              controller: controller,
              autofocus: true,
              obscureText: secret,
              autocorrect: false,
              enableSuggestions: !secret,
              keyboardType: keyboardType,
              style: Theme.of(context).textTheme.bodyLarge,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => Navigator.pop(context),
            ),
          ),
          actions: [
            TvAction(
              onPressed: () => Navigator.pop(context),
              child: Text(AppLocalizations.of(context).mobileBack),
            ),
          ],
        );
      },
    );
    onSubmitted?.call();
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: controller,
    builder: (context, value, _) {
      final text = secret ? '•' * value.text.length : value.text;
      final empty = text.isEmpty;
      if (pill) {
        return TvAction(
          autofocus: autofocus,
          pill: true,
          expand: true,
          leading: leading,
          onPressed: () => _edit(context),
          child: Builder(
            builder: (context) => Text(
              empty ? (placeholder ?? label) : text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: empty
                  ? TextStyle(
                      color: TvAction.secondaryColor(context),
                      fontWeight: FontWeight.w500,
                    )
                  : null,
            ),
          ),
        );
      }
      return TvAction(
        autofocus: autofocus,
        variant: TvActionVariant.tile,
        leading: leading,
        trailing: const Icon(Icons.edit_rounded),
        onPressed: () => _edit(context),
        child: Builder(
          builder: (context) {
            final theme = Theme.of(context);
            final secondary = TvAction.secondaryColor(context);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: secondary,
                  ),
                ),
                Text(
                  empty ? (placeholder ?? '—') : text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: empty ? TextStyle(color: secondary) : null,
                ),
              ],
            );
          },
        ),
      );
    },
  );
}

/// 选项行:左侧文字,右侧勾选。用于外观、播放设置等单选组。
class TvChoiceTile extends StatelessWidget {
  const TvChoiceTile({
    super.key,
    required this.label,
    required this.selected,
    required this.onPressed,
    this.autofocus = false,
    this.focusNode,
    this.subtitle,
    this.leading,
    this.actionKey,
  });

  /// 键放在内部 [TvAction] 上,便于按键查找与聚焦断言。
  final Key? actionKey;
  final String label;
  final String? subtitle;
  final bool selected, autofocus;
  final FutureOr<void> Function()? onPressed;
  final FocusNode? focusNode;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    return TvAction(
      key: actionKey,
      variant: TvActionVariant.tile,
      selected: selected,
      autofocus: autofocus,
      focusNode: focusNode,
      leading: leading,
      onPressed: onPressed,
      trailing: Icon(
        selected ? Icons.check_rounded : null,
        key: selected ? const Key('tv-choice-check') : null,
      ),
      child: Builder(
        builder: (context) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, maxLines: 2, overflow: TextOverflow.ellipsis),
            if (subtitle case final value? when value.isNotEmpty)
              Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: TvAction.secondaryColor(context),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 列表导航行:图标 + 标题/说明 + 右箭头或当前值。
class TvNavTile extends StatelessWidget {
  const TvNavTile({
    super.key,
    required this.title,
    required this.onPressed,
    this.subtitle,
    this.icon,
    this.value,
    this.autofocus = false,
    this.destructive = false,
    this.chevron = true,
    this.actionKey,
  });

  /// 键放在内部 [TvAction] 上。
  final Key? actionKey;
  final String title;
  final String? subtitle, value;
  final IconData? icon;
  final FutureOr<void> Function()? onPressed;
  final bool autofocus, destructive, chevron;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return TvAction(
      key: actionKey,
      variant: TvActionVariant.tile,
      autofocus: autofocus,
      onPressed: onPressed,
      leading: icon == null
          ? null
          : Builder(
              builder: (context) => Icon(
                icon,
                color: destructive && !TvAction.focusedOf(context)
                    ? scheme.error
                    : null,
              ),
            ),
      trailing: Builder(
        builder: (context) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (value case final text? when text.isNotEmpty)
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: context.tvdp(260)),
                child: Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: TvAction.secondaryColor(context)),
                ),
              ),
            if (chevron)
              Icon(
                Icons.chevron_right_rounded,
                color: TvAction.secondaryColor(context),
              ),
          ],
        ),
      ),
      child: Builder(
        builder: (context) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: destructive && !TvAction.focusedOf(context)
                  ? TextStyle(color: scheme.error)
                  : null,
            ),
            if (subtitle case final text? when text.isNotEmpty)
              Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: TvAction.secondaryColor(context),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 影像上的固定深色舞台:hero 与详情头图不随浅色主题变白,
/// 按钮与文字始终在压暗的画面上保持对比度。
class TvDarkStage extends StatelessWidget {
  const TvDarkStage({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (theme.brightness == Brightness.dark) return child;
    final dark = TvStageTheme.themeFor(
      AppTheme.tvDark(),
      TvDesign.scaleOf(context),
    );
    return Theme(
      data: dark,
      child: DefaultTextStyle.merge(
        style: const TextStyle(color: Colors.white),
        child: child,
      ),
    );
  }
}

/// TV 沉浸 hero 遮罩:顶带保护导航/标题,左侧文字带托底白字,底带溶入页面。
///
/// hero 文字恒为白色,遮罩恒为黑色系,与主题明暗无关;alpha 全部经
/// [AppScrim.resolve],系统要求高对比度时抬到不低于 [AppScrim.highContrastAlpha]。
class TvHeroScrim extends StatelessWidget {
  const TvHeroScrim({
    super.key,
    this.top = true,
    this.leading = true,
    this.bottom = true,
  });

  /// 顶带:保护浮于 hero 之上的导航与标题。
  final bool top;

  /// 左侧文字带:hero 底部左对齐标题区的横向渐变。
  final bool leading;

  /// 底带:向页面底色溶入。
  final bool bottom;

  @override
  Widget build(BuildContext context) {
    final s = TvDesign.scaleOf(context);
    return Stack(
      fit: StackFit.expand,
      children: [
        if (top)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: 110 * s,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(
                      alpha: AppScrim.of(context, AppScrim.top),
                    ),
                    Colors.black.withValues(alpha: 0),
                  ],
                ),
              ),
            ),
          ),
        if (leading)
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: [
                    Colors.black.withValues(alpha: AppScrim.of(context, .82)),
                    Colors.black.withValues(alpha: AppScrim.of(context, .45)),
                    Colors.black.withValues(alpha: 0),
                  ],
                  stops: const [0, .42, .78],
                ),
              ),
            ),
          ),
        if (bottom)
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0),
                    Colors.black.withValues(
                      alpha: AppScrim.of(context, AppScrim.bottomMid),
                    ),
                    Colors.black.withValues(alpha: AppScrim.of(context, .9)),
                  ],
                  stops: const [.45, .8, 1],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
