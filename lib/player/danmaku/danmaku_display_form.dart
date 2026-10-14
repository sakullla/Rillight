import 'package:rillight/player/buffered_ranges_track.dart';
import 'package:rillight/app/ui/ui.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/player/danmaku/danmaku_display_settings.dart';
import 'package:rillight/player/danmaku/danmaku_keys.dart';
import 'package:rillight/app/widgets/option_pill.dart';
import 'package:rillight/player/player_setting_choices.dart';

/// 弹幕显示表单的三种布局:播放器常用 / 播放器高级 / 设置页分组。
enum DanmakuFormLayout { playerBasic, playerAdvanced, settings }

/// 受控弹幕显示表单:每次改动立即 [onChanged],无单独保存。
class DanmakuDisplayForm extends StatelessWidget {
  const DanmakuDisplayForm({
    super.key,
    required this.value,
    required this.onChanged,
    required this.layout,
  });

  final DanmakuDisplaySettings value;
  final ValueChanged<DanmakuDisplaySettings> onChanged;
  final DanmakuFormLayout layout;

  @override
  Widget build(BuildContext context) {
    switch (layout) {
      case DanmakuFormLayout.playerBasic:
        return _BasicGroup(value: value, onChanged: onChanged, compact: true);
      case DanmakuFormLayout.playerAdvanced:
        return _AdvancedGroup(
          value: value,
          onChanged: onChanged,
          compact: true,
        );
      case DanmakuFormLayout.settings:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _DanmakuPreview(value: value),
            const SizedBox(height: AppSpacing.md),
            _BasicGroup(value: value, onChanged: onChanged, compact: false),
            const SizedBox(height: AppSpacing.md),
            AppDisclosure(
              key: const ValueKey('danmaku-advanced-settings'),
              title: Text(AppLocalizations.of(context).danmakuAdvanced),
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(bottom: 8),
              children: [
                _AdvancedGroup(
                  value: value,
                  onChanged: onChanged,
                  compact: false,
                  showRestore: false,
                ),
              ],
            ),
          ],
        );
    }
  }
}

class _DanmakuPreview extends StatelessWidget {
  const _DanmakuPreview({required this.value});
  final DanmakuDisplaySettings value;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = AppUiTheme.of(context).colorScheme;
    return Container(
      height: 116,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: const Color(0xff161a20),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    scheme.primary.withValues(alpha: .16),
                    const Color(0x00000000),
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
            ),
          ),
          Positioned(
            left: 16,
            top: 14,
            right: 16,
            child: Opacity(
              opacity: value.opacity.clamp(0, 1),
              child: Text(
                l10n.danmakuPreviewText,
                maxLines: 1,
                overflow: TextOverflow.fade,
                style: TextStyle(
                  color: value.colorful
                      ? const Color(0xffffd78c)
                      : CupertinoColors.white,
                  fontSize: 18 * value.fontScale,
                  fontWeight: FontWeight.w600,
                  shadows: value.outline
                      ? const [
                          Shadow(color: CupertinoColors.black, blurRadius: 3),
                        ]
                      : null,
                ),
              ),
            ),
          ),
          Positioned(
            left: 16,
            bottom: 14,
            child: Text(
              l10n.danmakuPreview,
              style: AppUiTheme.of(context).textTheme.labelSmall
                  ?.copyWith(color: const Color(0x99ffffff)),
            ),
          ),
        ],
      ),
    );
  }
}

class _BasicGroup extends StatelessWidget {
  const _BasicGroup({
    required this.value,
    required this.onChanged,
    required this.compact,
  });

  final DanmakuDisplaySettings value;
  final ValueChanged<DanmakuDisplaySettings> onChanged;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _OpacityRow(
          label: l10n.danmakuOpacity,
          value: value.opacity,
          compact: compact,
          onChanged: (opacity) => onChanged(value.copyWith(opacity: opacity)),
        ),
        if (compact) const SizedBox(height: 6),
        _SegmentedRow<double>(
          key: DanmakuKeys.fontScale,
          label: l10n.danmakuFontSize,
          compact: compact,
          value: value.fontScale,
          segments: [
            _DanmakuChoice(
              value: kDanmakuFontScaleSteps[0],
              label: Text(l10n.danmakuFontScaleSmall),
            ),
            _DanmakuChoice(
              value: kDanmakuFontScaleSteps[1],
              label: Text(l10n.danmakuFontScaleMedium),
            ),
            _DanmakuChoice(
              value: kDanmakuFontScaleSteps[2],
              label: Text(l10n.danmakuFontScaleLarge),
            ),
            _DanmakuChoice(
              value: kDanmakuFontScaleSteps[3],
              label: Text(l10n.danmakuFontScaleExtraLarge),
            ),
          ],
          onChanged: (fontScale) =>
              onChanged(value.copyWith(fontScale: fontScale)),
        ),
        if (compact) const SizedBox(height: 6),
        _SegmentedRow<double>(
          key: DanmakuKeys.speed,
          label: l10n.danmakuSpeed,
          compact: compact,
          value: value.speed,
          segments: [
            _DanmakuChoice(
              value: kDanmakuSpeedSteps[0],
              label: Text(l10n.danmakuSpeedSlow),
            ),
            _DanmakuChoice(
              value: kDanmakuSpeedSteps[1],
              label: Text(l10n.danmakuSpeedNormal),
            ),
            _DanmakuChoice(
              value: kDanmakuSpeedSteps[2],
              label: Text(l10n.danmakuSpeedFast),
            ),
            _DanmakuChoice(
              value: kDanmakuSpeedSteps[3],
              label: Text(l10n.danmakuSpeedVeryFast),
            ),
          ],
          onChanged: (speed) => onChanged(value.copyWith(speed: speed)),
        ),
        if (compact) const SizedBox(height: 6),
        _SegmentedRow<double>(
          key: DanmakuKeys.area,
          label: l10n.danmakuDisplayArea,
          compact: compact,
          value: value.areaFraction,
          segments: [
            _DanmakuChoice(
              value: kDanmakuAreaFractionSteps[0],
              label: Text(l10n.danmakuAreaQuarter),
            ),
            _DanmakuChoice(
              value: kDanmakuAreaFractionSteps[1],
              label: Text(l10n.danmakuAreaHalf),
            ),
            _DanmakuChoice(
              value: kDanmakuAreaFractionSteps[2],
              label: Text(l10n.danmakuAreaThreeQuarters),
            ),
            _DanmakuChoice(
              value: kDanmakuAreaFractionSteps[3],
              label: Text(l10n.danmakuAreaFull),
            ),
          ],
          onChanged: (areaFraction) =>
              onChanged(value.copyWith(areaFraction: areaFraction)),
        ),
        if (compact) const SizedBox(height: 8),
        _TypeRow(value: value, onChanged: onChanged, compact: compact),
      ],
    );
  }
}

class _AdvancedGroup extends StatelessWidget {
  const _AdvancedGroup({
    required this.value,
    required this.onChanged,
    required this.compact,
    this.showRestore = true,
  });

  final DanmakuDisplaySettings value;
  final ValueChanged<DanmakuDisplaySettings> onChanged;
  final bool compact;
  final bool showRestore;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SwitchRow(
          key: DanmakuKeys.preventOverlap,
          title: l10n.danmakuPreventOverlap,
          value: value.preventOverlap,
          compact: compact,
          onChanged: (preventOverlap) =>
              onChanged(value.copyWith(preventOverlap: preventOverlap)),
        ),
        _SwitchRow(
          key: DanmakuKeys.mergeDuplicates,
          title: l10n.danmakuMergeDuplicates,
          value: value.mergeDuplicates,
          compact: compact,
          onChanged: (mergeDuplicates) =>
              onChanged(value.copyWith(mergeDuplicates: mergeDuplicates)),
        ),
        _SwitchRow(
          key: DanmakuKeys.outline,
          title: l10n.danmakuOutline,
          value: value.outline,
          compact: compact,
          onChanged: (outline) => onChanged(value.copyWith(outline: outline)),
        ),
        _SwitchRow(
          key: DanmakuKeys.followPlaybackRate,
          title: l10n.danmakuFollowPlaybackRate,
          value: value.followPlaybackRate,
          compact: compact,
          onChanged: (followPlaybackRate) =>
              onChanged(value.copyWith(followPlaybackRate: followPlaybackRate)),
        ),
        _SegmentedRow<DanmakuDensity>(
          key: DanmakuKeys.density,
          label: l10n.danmakuDensity,
          compact: compact,
          value: value.density,
          segments: [
            _DanmakuChoice(
              value: DanmakuDensity.auto,
              label: Text(l10n.danmakuDensityAuto),
            ),
            _DanmakuChoice(
              value: DanmakuDensity.sparse,
              label: Text(l10n.danmakuDensitySparse),
            ),
            _DanmakuChoice(
              value: DanmakuDensity.dense,
              label: Text(l10n.danmakuDensityDense),
            ),
            _DanmakuChoice(
              value: DanmakuDensity.unlimited,
              label: Text(l10n.danmakuUnlimited),
            ),
          ],
          onChanged: (density) => onChanged(value.copyWith(density: density)),
        ),
        _TimeOffsetRow(
          value: value.timeOffset,
          compact: compact,
          onChanged: (timeOffset) =>
              onChanged(value.copyWith(timeOffset: timeOffset)),
        ),
        _KeywordEditor(
          keywords: value.blockedKeywords,
          compact: compact,
          onChanged: (blockedKeywords) =>
              onChanged(value.copyWith(blockedKeywords: blockedKeywords)),
        ),
        if (showRestore)
          Align(
            alignment: Alignment.centerLeft,
            child: AppButton.icon(
              key: DanmakuKeys.restoreDefaults,
              onPressed: () => onChanged(const DanmakuDisplaySettings()),
              style: AppButtonStyle(),
              icon: const Icon(CupertinoIcons.arrow_counterclockwise),
              label: Text(l10n.danmakuRestoreDefaults),
            ),
          ),
      ],
    );
  }
}

class _OpacityRow extends StatelessWidget {
  const _OpacityRow({
    required this.label,
    required this.value,
    required this.compact,
    required this.onChanged,
  });

  final String label;
  final double value;
  final bool compact;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    final slider = PlayerSlider(
      key: DanmakuKeys.opacity,
      value: value.clamp(kDanmakuOpacityMin, 1.0),
      min: kDanmakuOpacityMin,
      max: 1,
      onChanged: onChanged,
    );
    final percent = Text(
      '${(value * 100).round()}%',
      style: theme.textTheme.labelSmall?.copyWith(
        color: compact ? scheme.onSurface.withValues(alpha: 0.72) : null,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
    if (compact) {
      return SizedBox(
        height: 32,
        child: Row(
          children: [
            _CompactLabel(label),
            Expanded(child: slider),
            percent,
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text(label, style: theme.textTheme.titleSmall)),
              percent,
            ],
          ),
          slider,
        ],
      ),
    );
  }
}

class _SegmentedRow<T extends Object> extends StatelessWidget {
  const _SegmentedRow({
    super.key,
    required this.label,
    required this.compact,
    required this.value,
    required this.segments,
    required this.onChanged,
  });

  final String label;
  final bool compact;
  final T value;
  final List<_DanmakuChoice<T>> segments;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    if (compact) {
      return SizedBox(
        height: 32,
        child: Row(
          children: [
            _CompactLabel(label),
            Expanded(
              child: _HudChoiceBar<T>(
                value: value,
                segments: segments,
                onChanged: onChanged,
              ),
            ),
          ],
        ),
      );
    }
    final theme = AppUiTheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(label, style: theme.textTheme.titleSmall),
          const SizedBox(height: AppSpacing.xs),
          PlayerOptionGrid(
            options: [
              for (final segment in segments)
                PlayerOption(
                  label: _segmentLabel(segment),
                  selected: segment.value == value,
                  onPressed: () => onChanged(segment.value),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

String _segmentLabel<T extends Object>(_DanmakuChoice<T> segment) {
  final label = segment.label;
  if (label is Text) {
    final data = label.data;
    if (data != null) return data;
  }
  return '';
}

class _TypeRow extends StatelessWidget {
  const _TypeRow({
    required this.value,
    required this.onChanged,
    required this.compact,
  });

  final DanmakuDisplaySettings value;
  final ValueChanged<DanmakuDisplaySettings> onChanged;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final chips = [
      _TypeChip(
        key: DanmakuKeys.typeScroll,
        label: l10n.danmakuTypeScroll,
        selected: value.showScroll,
        onSelected: (showScroll) =>
            onChanged(value.copyWith(showScroll: showScroll)),
      ),
      _TypeChip(
        key: DanmakuKeys.typeTop,
        label: l10n.danmakuTypeTop,
        selected: value.showTop,
        onSelected: (showTop) => onChanged(value.copyWith(showTop: showTop)),
      ),
      _TypeChip(
        key: DanmakuKeys.typeBottom,
        label: l10n.danmakuTypeBottom,
        selected: value.showBottom,
        onSelected: (showBottom) =>
            onChanged(value.copyWith(showBottom: showBottom)),
      ),
      _TypeChip(
        key: DanmakuKeys.typeColorful,
        label: l10n.danmakuColorful,
        selected: value.colorful,
        onSelected: (colorful) => onChanged(value.copyWith(colorful: colorful)),
      ),
    ];
    if (compact) {
      return SizedBox(
        key: DanmakuKeys.types,
        height: 32,
        child: Row(
          children: [
            for (var i = 0; i < chips.length; i++) ...[
              if (i > 0) const SizedBox(width: 6),
              Expanded(child: chips[i]),
            ],
          ],
        ),
      );
    }
    return Padding(
      key: DanmakuKeys.types,
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: PlayerOptionGrid(
        options: [
          for (final chip in chips)
            PlayerOption(
              key: chip.key,
              label: chip.label,
              selected: chip.selected,
              onPressed: () => chip.onSelected(!chip.selected),
            ),
        ],
      ),
    );
  }
}

class _TypeChip extends StatelessWidget {
  const _TypeChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onSelected,
  });

  final String label;
  final bool selected;
  final ValueChanged<bool> onSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = AppUiTheme.of(context).colorScheme;
    final selectedFill = scheme.onSurface.withValues(alpha: 0.92);
    final idleFill = scheme.onSurface.withValues(alpha: 0.08);
    return Container(
      decoration: BoxDecoration(
        color: selected ? selectedFill : idleFill,
        borderRadius: BorderRadius.circular(999),
      ),
      child: AppSurfaceAction(
        onTap: () => onSelected(!selected),
        borderRadius: BorderRadius.circular(999),
        child: Center(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppUiTheme.of(context).textTheme.labelSmall?.copyWith(
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              color: selected
                  ? scheme.surface
                  : scheme.onSurface.withValues(alpha: 0.72),
            ),
          ),
        ),
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    super.key,
    required this.title,
    required this.value,
    required this.compact,
    required this.onChanged,
  });

  final String title;
  final bool value;
  final bool compact;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    if (!compact) {
      return AppSwitchTile(
        title: Text(title),
        value: value,
        onChanged: onChanged,
      );
    }
    return SizedBox(
      height: 36,
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppUiTheme.of(context).textTheme.labelMedium,
            ),
          ),
          CupertinoSwitch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

class _TimeOffsetRow extends StatelessWidget {
  const _TimeOffsetRow({
    required this.value,
    required this.compact,
    required this.onChanged,
  });

  final Duration value;
  final bool compact;
  final ValueChanged<Duration> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = AppUiTheme.of(context);
    final atMin = value <= -kDanmakuTimeOffsetMax;
    final atMax = value >= kDanmakuTimeOffsetMax;
    final seconds = value.inMilliseconds / 1000;
    final sign = seconds > 0 ? '+' : '';
    final controls = Row(
      key: DanmakuKeys.timeOffset,
      children: [
        AppIconButton(
          key: DanmakuKeys.timeOffsetMinus,
          tooltip: l10n.danmakuTimeOffsetStepDown,

          onPressed: atMin
              ? null
              : () => onChanged(value - const Duration(milliseconds: 500)),
          icon: const Icon(CupertinoIcons.minus),
        ),
        SizedBox(
          width: 56,
          child: Text(
            '$sign${seconds.toStringAsFixed(1)}s',
            textAlign: TextAlign.center,
            style: theme.textTheme.labelLarge,
          ),
        ),
        AppIconButton(
          key: DanmakuKeys.timeOffsetPlus,
          tooltip: l10n.danmakuTimeOffsetStepUp,

          onPressed: atMax
              ? null
              : () => onChanged(value + const Duration(milliseconds: 500)),
          icon: const Icon(CupertinoIcons.add),
        ),
        AppButton(
          key: DanmakuKeys.timeOffsetZero,
          onPressed: value == Duration.zero
              ? null
              : () => onChanged(Duration.zero),
          style: AppButtonStyle(),
          child: Text(l10n.danmakuTimeOffsetZero),
        ),
      ],
    );
    if (compact) {
      return SizedBox(
        height: 36,
        child: Row(
          children: [
            _CompactLabel(l10n.danmakuTimeOffset),
            Expanded(child: controls),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Row(
        children: [
          Expanded(
            child: Text(
              l10n.danmakuTimeOffset,
              style: theme.textTheme.titleSmall,
            ),
          ),
          controls,
        ],
      ),
    );
  }
}

class _KeywordEditor extends StatefulWidget {
  const _KeywordEditor({
    required this.keywords,
    required this.compact,
    required this.onChanged,
  });

  final List<String> keywords;
  final bool compact;
  final ValueChanged<List<String>> onChanged;

  @override
  State<_KeywordEditor> createState() => _KeywordEditorState();
}

class _KeywordEditorState extends State<_KeywordEditor> {
  late final TextEditingController _controller;
  late final FocusNode _focus;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
    _focus = FocusNode();
    _focus.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChanged);
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    if (!_focus.hasFocus) {
      _commit();
    }
  }

  void _commit() {
    final raw = _controller.text;
    final next = DanmakuDisplaySettings.normalizeKeywords([
      ...widget.keywords,
      raw,
    ]);
    _controller.clear();
    if (_sameKeywords(next, widget.keywords)) {
      return;
    }
    widget.onChanged(next);
  }

  void _remove(String keyword) {
    widget.onChanged([
      for (final item in widget.keywords)
        if (item != keyword) item,
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = AppUiTheme.of(context);
    final field = AppTextField(
      key: DanmakuKeys.keywordInput,
      controller: _controller,
      focusNode: _focus,
      maxLines: 1,
      textInputAction: TextInputAction.done,
      onEditingComplete: _commit,
      onSubmitted: (_) => _commit(),
      placeholder: l10n.danmakuKeywordHint,
    );
    final chips = Wrap(
      key: DanmakuKeys.keywords,
      spacing: AppSpacing.xxs,
      runSpacing: AppSpacing.xxs,
      children: [
        for (final keyword in widget.keywords)
          RemovablePill(
            key: DanmakuKeys.keywordChip(keyword),
            label: keyword,
            compact: widget.compact,
            onDeleted: () => _remove(keyword),
          ),
      ],
    );
    if (widget.compact) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.keywords.isNotEmpty) ...[
            chips,
            const SizedBox(height: AppSpacing.xxs),
          ],
          field,
        ],
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l10n.danmakuBlockedKeywords, style: theme.textTheme.titleSmall),
          if (widget.keywords.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xs),
            chips,
          ],
          const SizedBox(height: AppSpacing.xs),
          field,
        ],
      ),
    );
  }
}

class _HudChoiceBar<T extends Object> extends StatelessWidget {
  const _HudChoiceBar({
    required this.value,
    required this.segments,
    required this.onChanged,
  });

  final T value;
  final List<_DanmakuChoice<T>> segments;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = AppUiTheme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.all(2),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.onSurface.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          children: [
            for (final segment in segments)
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: segment.value == value
                        ? scheme.onSurface.withValues(alpha: 0.92)
                        : const Color(0x00000000),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: AppSurfaceAction(
                    onTap: () => onChanged(segment.value),
                    borderRadius: BorderRadius.circular(999),
                    child: SizedBox(
                      height: 28,
                      child: Center(
                        child: DefaultTextStyle(
                          style:
                              (theme.textTheme.labelSmall ?? const TextStyle())
                                  .copyWith(
                                    fontWeight: segment.value == value
                                        ? FontWeight.w600
                                        : FontWeight.w500,
                                    color: segment.value == value
                                        ? scheme.surface
                                        : scheme.onSurface.withValues(
                                            alpha: 0.64,
                                          ),
                                  ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          child: segment.label,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _CompactLabel extends StatelessWidget {
  const _CompactLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 72,
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: AppUiTheme.of(context).textTheme.labelMedium?.copyWith(
          color: AppUiTheme.of(context).colorScheme.onSurface
              .withValues(alpha: 0.62),
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

bool _sameKeywords(List<String> a, List<String> b) {
  if (a.length != b.length) {
    return false;
  }
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) {
      return false;
    }
  }
  return true;
}

class _DanmakuChoice<T> {
  const _DanmakuChoice({required this.value, required this.label});
  final T value;
  final Widget label;
}
