import 'package:flutter/material.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/player/danmaku/danmaku_display_settings.dart';
import 'package:rillight/player/danmaku/danmaku_keys.dart';

/// 弹幕显示表单的三种布局:播放器常用 / 播放器高级 / 设置页全量展开。
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
            _BasicGroup(value: value, onChanged: onChanged, compact: false),
            const SizedBox(height: AppSpacing.md),
            _AdvancedGroup(
              value: value,
              onChanged: onChanged,
              compact: false,
              showRestore: false,
            ),
          ],
        );
    }
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
    return Theme(
      data: _formTheme(context, compact),
      child: Column(
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
              ButtonSegment(
                value: kDanmakuFontScaleSteps[0],
                label: Text(l10n.danmakuFontScaleSmall),
              ),
              ButtonSegment(
                value: kDanmakuFontScaleSteps[1],
                label: Text(l10n.danmakuFontScaleMedium),
              ),
              ButtonSegment(
                value: kDanmakuFontScaleSteps[2],
                label: Text(l10n.danmakuFontScaleLarge),
              ),
              ButtonSegment(
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
              ButtonSegment(
                value: kDanmakuSpeedSteps[0],
                label: Text(l10n.danmakuSpeedSlow),
              ),
              ButtonSegment(
                value: kDanmakuSpeedSteps[1],
                label: Text(l10n.danmakuSpeedNormal),
              ),
              ButtonSegment(
                value: kDanmakuSpeedSteps[2],
                label: Text(l10n.danmakuSpeedFast),
              ),
              ButtonSegment(
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
              ButtonSegment(
                value: kDanmakuAreaFractionSteps[0],
                label: Text(l10n.danmakuAreaQuarter),
              ),
              ButtonSegment(
                value: kDanmakuAreaFractionSteps[1],
                label: Text(l10n.danmakuAreaHalf),
              ),
              ButtonSegment(
                value: kDanmakuAreaFractionSteps[2],
                label: Text(l10n.danmakuAreaThreeQuarters),
              ),
              ButtonSegment(
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
      ),
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
    return Theme(
      data: _formTheme(context, compact),
      child: Column(
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
            onChanged: (followPlaybackRate) => onChanged(
              value.copyWith(followPlaybackRate: followPlaybackRate),
            ),
          ),
          _SegmentedRow<DanmakuDensity>(
            key: DanmakuKeys.density,
            label: l10n.danmakuDensity,
            compact: compact,
            value: value.density,
            segments: [
              ButtonSegment(
                value: DanmakuDensity.auto,
                label: Text(l10n.danmakuDensityAuto),
              ),
              ButtonSegment(
                value: DanmakuDensity.sparse,
                label: Text(l10n.danmakuDensitySparse),
              ),
              ButtonSegment(
                value: DanmakuDensity.dense,
                label: Text(l10n.danmakuDensityDense),
              ),
              ButtonSegment(
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
              child: TextButton.icon(
                key: DanmakuKeys.restoreDefaults,
                onPressed: () => onChanged(const DanmakuDisplaySettings()),
                style: TextButton.styleFrom(
                  visualDensity: compact
                      ? VisualDensity.compact
                      : VisualDensity.standard,
                ),
                icon: const Icon(Icons.settings_backup_restore_rounded),
                label: Text(l10n.danmakuRestoreDefaults),
              ),
            ),
        ],
      ),
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
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final slider = SliderTheme(
      data: SliderTheme.of(context).copyWith(
        overlayShape: SliderComponentShape.noOverlay,
        trackHeight: compact ? 3 : 4,
        thumbShape: RoundSliderThumbShape(enabledThumbRadius: compact ? 5 : 8),
        activeTrackColor: compact ? scheme.onSurface : null,
        inactiveTrackColor: compact
            ? scheme.onSurface.withValues(alpha: 0.18)
            : null,
        thumbColor: compact ? scheme.onSurface : null,
      ),
      child: Slider(
        key: DanmakuKeys.opacity,
        value: value.clamp(kDanmakuOpacityMin, 1.0),
        min: kDanmakuOpacityMin,
        max: 1,
        onChanged: onChanged,
      ),
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
  final List<ButtonSegment<T>> segments;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
    final buttons = SegmentedButton<T>(
      showSelectedIcon: false,
      emptySelectionAllowed: false,
      style: ButtonStyle(
        visualDensity: VisualDensity.standard,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 4),
        ),
        minimumSize: const WidgetStatePropertyAll(Size(0, 40)),
        textStyle: WidgetStatePropertyAll(theme.textTheme.labelSmall),
      ),
      segments: segments,
      selected: {value},
      onSelectionChanged: (selected) {
        if (selected.isEmpty) {
          return;
        }
        onChanged(selected.first);
      },
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(label, style: theme.textTheme.titleSmall),
          const SizedBox(height: AppSpacing.xs),
          buttons,
        ],
      ),
    );
  }
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
        compact: compact,
        onSelected: (showScroll) =>
            onChanged(value.copyWith(showScroll: showScroll)),
      ),
      _TypeChip(
        key: DanmakuKeys.typeTop,
        label: l10n.danmakuTypeTop,
        selected: value.showTop,
        compact: compact,
        onSelected: (showTop) => onChanged(value.copyWith(showTop: showTop)),
      ),
      _TypeChip(
        key: DanmakuKeys.typeBottom,
        label: l10n.danmakuTypeBottom,
        selected: value.showBottom,
        compact: compact,
        onSelected: (showBottom) =>
            onChanged(value.copyWith(showBottom: showBottom)),
      ),
      _TypeChip(
        key: DanmakuKeys.typeColorful,
        label: l10n.danmakuColorful,
        selected: value.colorful,
        compact: compact,
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
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Wrap(
        key: DanmakuKeys.types,
        spacing: AppSpacing.xxs,
        runSpacing: AppSpacing.xxs,
        children: chips,
      ),
    );
  }
}

class _TypeChip extends StatelessWidget {
  const _TypeChip({
    super.key,
    required this.label,
    required this.selected,
    required this.compact,
    required this.onSelected,
  });

  final String label;
  final bool selected;
  final bool compact;
  final ValueChanged<bool> onSelected;

  @override
  Widget build(BuildContext context) {
    if (!compact) {
      return FilterChip(
        label: Text(label),
        selected: selected,
        onSelected: onSelected,
        visualDensity: VisualDensity.standard,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      );
    }
    final scheme = Theme.of(context).colorScheme;
    final selectedFill = scheme.onSurface.withValues(alpha: 0.92);
    final idleFill = scheme.onSurface.withValues(alpha: 0.08);
    return Material(
      color: selected ? selectedFill : idleFill,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        onTap: () => onSelected(!selected),
        borderRadius: BorderRadius.circular(999),
        child: Center(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
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
      return SwitchListTile.adaptive(
        title: Text(title),
        value: value,
        onChanged: onChanged,
        contentPadding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
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
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ),
          Switch.adaptive(
            value: value,
            onChanged: onChanged,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
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
    final theme = Theme.of(context);
    final atMin = value <= -kDanmakuTimeOffsetMax;
    final atMax = value >= kDanmakuTimeOffsetMax;
    final seconds = value.inMilliseconds / 1000;
    final sign = seconds > 0 ? '+' : '';
    final controls = Row(
      key: DanmakuKeys.timeOffset,
      children: [
        IconButton(
          key: DanmakuKeys.timeOffsetMinus,
          tooltip: l10n.danmakuTimeOffsetStepDown,
          visualDensity: VisualDensity.compact,
          onPressed: atMin
              ? null
              : () => onChanged(value - const Duration(milliseconds: 500)),
          icon: const Icon(Icons.remove_rounded),
        ),
        SizedBox(
          width: 56,
          child: Text(
            '$sign${seconds.toStringAsFixed(1)}s',
            textAlign: TextAlign.center,
            style: theme.textTheme.labelLarge,
          ),
        ),
        IconButton(
          key: DanmakuKeys.timeOffsetPlus,
          tooltip: l10n.danmakuTimeOffsetStepUp,
          visualDensity: VisualDensity.compact,
          onPressed: atMax
              ? null
              : () => onChanged(value + const Duration(milliseconds: 500)),
          icon: const Icon(Icons.add_rounded),
        ),
        TextButton(
          key: DanmakuKeys.timeOffsetZero,
          onPressed: value == Duration.zero
              ? null
              : () => onChanged(Duration.zero),
          style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
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
    final theme = Theme.of(context);
    final field = TextField(
      key: DanmakuKeys.keywordInput,
      controller: _controller,
      focusNode: _focus,
      maxLines: 1,
      textInputAction: TextInputAction.done,
      onEditingComplete: _commit,
      onSubmitted: (_) => _commit(),
      decoration: InputDecoration(
        isDense: true,
        hintText: l10n.danmakuKeywordHint,
        filled: widget.compact,
        border: widget.compact
            ? OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadii.sm),
                borderSide: BorderSide.none,
              )
            : const OutlineInputBorder(),
      ),
    );
    final chips = Wrap(
      key: DanmakuKeys.keywords,
      spacing: AppSpacing.xxs,
      runSpacing: AppSpacing.xxs,
      children: [
        for (final keyword in widget.keywords)
          InputChip(
            key: DanmakuKeys.keywordChip(keyword),
            label: Text(keyword),
            onDeleted: () => _remove(keyword),
            visualDensity: widget.compact
                ? VisualDensity.compact
                : VisualDensity.standard,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
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
          SizedBox(height: 36, child: field),
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
  final List<ButtonSegment<T>> segments;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
                child: Material(
                  color: segment.value == value
                      ? scheme.onSurface.withValues(alpha: 0.92)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(999),
                  child: InkWell(
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
                          child: segment.label ?? const SizedBox.shrink(),
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
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          color: Theme.of(
            context,
          ).colorScheme.onSurface.withValues(alpha: 0.62),
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

ThemeData _formTheme(BuildContext context, bool compact) {
  final theme = Theme.of(context);
  if (!compact) {
    return theme;
  }
  return theme.copyWith(
    visualDensity: VisualDensity.compact,
    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
  );
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
