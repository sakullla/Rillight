import 'package:rillight/app/ui/ui.dart';

import '../app/l10n/app_localizations.dart';
import '../app/tv_widgets.dart';
import '../app/widgets/emby_mark.dart';
import '../media_server/capabilities.dart';

import 'package:rillight/app/ui/app_icons.dart';

/// 三种媒体服务在登录与服务器列表里的统一呈现:名称、品牌色与一句登录方式说明。
extension MediaServerTypePresentation on MediaServerType {
  String get label => switch (this) {
    MediaServerType.emby => 'Emby',
    MediaServerType.jellyfin => 'Jellyfin',
    MediaServerType.plex => 'Plex',
  };

  Color get brandColor => switch (this) {
    MediaServerType.emby => AppServerBrand.emby,
    MediaServerType.jellyfin => AppServerBrand.jellyfin,
    MediaServerType.plex => AppServerBrand.plex,
  };

  String loginHint(AppLocalizations l) => switch (this) {
    MediaServerType.emby => l.loginEmbyHint,
    MediaServerType.jellyfin => l.loginJellyfinHint,
    MediaServerType.plex => l.loginPlexHint,
  };
}

/// 服务类型标记:Emby 绿底播放钮、Jellyfin 渐变三角、Plex 深底琥珀箭头。
/// 只用矢量绘制,不依赖资源文件;服务器列表、登录切换与 TV 共用。
class ServerTypeMark extends StatelessWidget {
  const ServerTypeMark({super.key, required this.type, this.size = 28});

  final MediaServerType type;
  final double size;

  @override
  Widget build(BuildContext context) {
    if (type == MediaServerType.emby) return EmbyMark(size: size);
    return Semantics(
      label: type.label,
      child: CustomPaint(
        size: Size.square(size),
        painter: type == MediaServerType.jellyfin
            ? const _JellyfinMarkPainter()
            : const _PlexMarkPainter(),
      ),
    );
  }
}

class _JellyfinMarkPainter extends CustomPainter {
  const _JellyfinMarkPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final radius = size.shortestSide * 0.22;
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(radius)),
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppServerBrand.jellyfinPurple, AppServerBrand.jellyfinBlue],
        ).createShader(rect),
    );
    Offset p(double x, double y) => Offset(size.width * x, size.height * y);
    final outer = Path()
      ..moveTo(p(.5, .2).dx, p(.5, .2).dy)
      ..lineTo(p(.82, .76).dx, p(.82, .76).dy)
      ..lineTo(p(.18, .76).dx, p(.18, .76).dy)
      ..close();
    final inner = Path()
      ..moveTo(p(.5, .46).dx, p(.5, .46).dy)
      ..lineTo(p(.635, .68).dx, p(.635, .68).dy)
      ..lineTo(p(.365, .68).dx, p(.365, .68).dy)
      ..close();
    final mark = Path.combine(PathOperation.difference, outer, inner);
    canvas.drawPath(
      mark,
      Paint()
        ..color = AppInk.white
        ..style = PaintingStyle.fill,
    );
    canvas.drawPath(
      outer,
      Paint()
        ..color = AppInk.white
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = size.shortestSide * 0.05,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _PlexMarkPainter extends CustomPainter {
  const _PlexMarkPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final radius = size.shortestSide * 0.22;
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(radius)),
      Paint()..color = AppServerBrand.plexSurface,
    );
    Offset p(double x, double y) => Offset(size.width * x, size.height * y);
    final chevron = Path()
      ..moveTo(p(.33, .2).dx, p(.33, .2).dy)
      ..lineTo(p(.53, .2).dx, p(.53, .2).dy)
      ..lineTo(p(.73, .5).dx, p(.73, .5).dy)
      ..lineTo(p(.53, .8).dx, p(.53, .8).dy)
      ..lineTo(p(.33, .8).dx, p(.33, .8).dy)
      ..lineTo(p(.53, .5).dx, p(.53, .5).dy)
      ..close();
    canvas.drawPath(chevron, Paint()..color = AppServerBrand.plex);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// 品牌方块:强调色实底 + 播放三角,桌面、手机共用。不带渐变与色光。
class LoginBrandMark extends StatelessWidget {
  const LoginBrandMark({super.key, this.size = 44});

  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = AppUiTheme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * .28),
        color: colors.primary,
      ),
      child: Icon(
        AppIcons.play,
        fill: AppIcons.filled,
        color: colors.onPrimary,
        size: size * .58,
      ),
    );
  }
}

/// 桌面与手机的服务类型分段切换:滑动的选中块 + 品牌标记 + 名称。
///
/// 每段带 `'$keyPrefix-<type>'` 键;[containerKey] 放在整条控件上。
class ProviderSwitcher extends StatelessWidget {
  const ProviderSwitcher({
    super.key,
    required this.value,
    required this.onChanged,
    this.keyPrefix = 'login-provider',
    this.containerKey,
    this.height = 48,
  });

  final MediaServerType value;

  /// 为空时整条禁用(连接中或编辑已有服务器)。
  final ValueChanged<MediaServerType>? onChanged;
  final String keyPrefix;
  final Key? containerKey;
  final double height;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    const types = MediaServerType.values;
    final index = types.indexOf(value);
    final duration = AppMotion.durationOf(context, AppMotion.normal);
    return Semantics(
      container: true,
      label: AppLocalizations.of(context).loginServiceLabel,
      child: Container(
        key: containerKey,
        height: height,
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(AppRadii.pill),
          border: Border.all(color: AppEdge.of(theme.brightness)),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final segment = constraints.maxWidth / types.length;
            return Stack(
              children: [
                AnimatedPositioned(
                  duration: duration,
                  curve: AppMotion.emphasized,
                  left: segment * index,
                  top: 0,
                  bottom: 0,
                  width: segment,
                  child: DecoratedBox(
                    decoration: AppSelectionDecoration.of(scheme).copyWith(
                      boxShadow: [
                        BoxShadow(
                          color: AppInk.black.withValues(
                            alpha: dark ? .28 : .08,
                          ),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                  ),
                ),
                Row(
                  children: [
                    for (final type in types)
                      Expanded(
                        child: _ProviderSegment(
                          key: Key('$keyPrefix-${type.name}'),
                          type: type,
                          selected: type == value,
                          onTap: onChanged == null
                              ? null
                              : () {
                                  if (type != value) onChanged!(type);
                                },
                        ),
                      ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _ProviderSegment extends StatelessWidget {
  const _ProviderSegment({
    super.key,
    required this.type,
    required this.selected,
    required this.onTap,
  });

  final MediaServerType type;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    final enabled = onTap != null;
    return Semantics(
      button: true,
      selected: selected,
      enabled: enabled,
      child: Container(
        decoration: BoxDecoration(),
        child: AppSurfaceAction(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadii.pill),
          child: Opacity(
            opacity: enabled || selected ? 1 : .5,
            child: Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AnimatedOpacity(
                        opacity: selected ? 1 : .7,
                        duration: AppMotion.durationOf(context),
                        child: ServerTypeMark(type: type, size: 18),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        type.label,
                        style: theme.textTheme.labelLarge?.copyWith(
                          fontWeight: selected
                              ? FontWeight.w600
                              : FontWeight.w500,
                          color: selected
                              ? scheme.onPrimaryContainer
                              : scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
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

/// TV 的服务类型切换:三颗遥控器可聚焦的胶囊,选中项实心并带品牌标记。
class TvProviderSwitcher extends StatelessWidget {
  const TvProviderSwitcher({
    super.key,
    required this.value,
    required this.onChanged,
    this.keyPrefix = 'login-provider',
  });

  final MediaServerType value;
  final ValueChanged<MediaServerType>? onChanged;
  final String keyPrefix;

  @override
  Widget build(BuildContext context) {
    final s = TvDesign.scaleOf(context);
    return Row(
      children: [
        for (final type in MediaServerType.values) ...[
          if (type != MediaServerType.values.first) SizedBox(width: 6 * s),
          Expanded(
            child: TvAction(
              key: Key('$keyPrefix-${type.name}'),
              selected: type == value,
              // 选中项主色实底,聚焦项反相;两种状态在 3 米外都能分清。
              emphasized: type == value,
              expand: true,
              onPressed: onChanged == null
                  ? null
                  : () {
                      if (type != value) onChanged!(type);
                    },
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ServerTypeMark(type: type, size: 14 * s),
                    SizedBox(width: 5 * s),
                    Text(type.label, maxLines: 1),
                  ],
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// 切换说明:随服务类型淡入淡出的一行小字。
class ProviderHint extends StatelessWidget {
  const ProviderHint({super.key, required this.type, this.style});

  final MediaServerType type;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final l = AppLocalizations.of(context);
    return AnimatedSwitcher(
      duration: AppMotion.durationOf(context),
      layoutBuilder: (current, previous) => Stack(
        alignment: Alignment.topLeft,
        children: [...previous, ?current],
      ),
      child: Text(
        type.loginHint(l),
        key: ValueKey(type),
        style:
            style ??
            theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.4,
            ),
      ),
    );
  }
}

/// 登录失败提示:错误容器色 + 图标,读屏即时播报。
class LoginErrorBanner extends StatelessWidget {
  const LoginErrorBanner({super.key, required this.message, this.textKey});

  final String message;
  final Key? textKey;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    return Semantics(
      liveRegion: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.errorContainer.withValues(alpha: .55),
          borderRadius: BorderRadius.circular(AppRadii.md),
          border: Border.all(color: scheme.error.withValues(alpha: .35)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm,
            vertical: AppSpacing.xs + 2,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                AppIcons.error,
                fill: AppIcons.filled,
                size: 20,
                color: scheme.onErrorContainer,
              ),
              const SizedBox(width: AppSpacing.xs + 2),
              Expanded(
                child: Text(
                  message,
                  key: textKey,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onErrorContainer,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 主操作按钮内的进行中样式:小圆环 + 文案,宽度不随状态跳动。
class BusyLabel extends StatelessWidget {
  const BusyLabel({
    super.key,
    required this.busy,
    required this.label,
    required this.busyLabel,
  });

  final bool busy;
  final String label;
  final String busyLabel;

  @override
  Widget build(BuildContext context) {
    if (!busy) return Text(label);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox.square(
          dimension: 16,
          child: CupertinoActivityIndicator(
            color: DefaultTextStyle.of(context).style.color,
          ),
        ),
        const SizedBox(width: AppSpacing.xs),
        Text(busyLabel),
      ],
    );
  }
}

/// 「或」分隔线。
class LoginOrDivider extends StatelessWidget {
  const LoginOrDivider({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    return Row(
      children: [
        Expanded(child: AppDivider(color: scheme.outlineVariant)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
          child: Text(
            AppLocalizations.of(context).tvConnectOr,
            style: theme.textTheme.labelMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(child: AppDivider(color: scheme.outlineVariant)),
      ],
    );
  }
}

/// 可折叠的「高级选项」:默认收起,已有内容时自动展开。
class LoginAdvancedSection extends StatefulWidget {
  const LoginAdvancedSection({
    super.key,
    required this.children,
    this.initiallyExpanded = false,
    this.toggleKey,
    this.title,
    this.onExpansionChanged,
  });

  final List<Widget> children;
  final bool initiallyExpanded;
  final Key? toggleKey;
  final String? title;
  final ValueChanged<bool>? onExpansionChanged;

  @override
  State<LoginAdvancedSection> createState() => _LoginAdvancedSectionState();
}

class _LoginAdvancedSectionState extends State<LoginAdvancedSection> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    final duration = AppMotion.durationOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: AppButton.icon(
            key: widget.toggleKey,
            style: AppButtonStyle(
              foregroundColor: scheme.onSurfaceVariant,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              minimumSize: const Size(44, 34),
            ),
            onPressed: () {
              setState(() => _expanded = !_expanded);
              widget.onExpansionChanged?.call(_expanded);
            },
            icon: AnimatedRotation(
              turns: _expanded ? .25 : 0,
              duration: duration,
              child: const Icon(
                AppIcons.chevronRight,
                fill: AppIcons.filled,
                size: 18,
              ),
            ),
            label: Text(
              widget.title ?? AppLocalizations.of(context).loginAdvanced,
            ),
            variant: AppButtonVariant.plain,
          ),
        ),
        AnimatedSize(
          duration: duration,
          curve: AppMotion.standard,
          alignment: Alignment.topCenter,
          child: _expanded
              ? Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.xs),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: widget.children,
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}

/// 表单在服务类型间切换时的过渡:新内容淡入,不让页面整体跳动。
///
/// 旧表单立即卸下(不与新表单叠放),避免两份同键输入框同时存在。
/// [child] 的键变化时重新播放淡入。
class LoginFormTransition extends StatelessWidget {
  const LoginFormTransition({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final duration = AppMotion.durationOf(context, AppMotion.normal);
    // 不做高度动画:表单列顶部对齐,高度变化只向下延伸;AnimatedSize 会在
    // 授权阶段切换时裁掉正在长高的内容与下拉菜单。
    return _FadeIn(key: child.key, duration: duration, child: child);
  }
}

class _FadeIn extends StatefulWidget {
  const _FadeIn({super.key, required this.duration, required this.child});

  final Duration duration;
  final Widget child;

  @override
  State<_FadeIn> createState() => _FadeInState();
}

class _FadeInState extends State<_FadeIn> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
    value: widget.duration == Duration.zero ? 1 : 0,
  )..forward();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: CurvedAnimation(parent: _controller, curve: AppMotion.standard),
      child: widget.child,
    );
  }
}
