import 'package:flutter/material.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/theme/tokens.dart';

/// 搜索、片库和「更多」共用的筛选入口。
///
/// 按钮只负责打开同一张观看状态选择。已选项由调用方画成可去掉的条目。
class CatalogFilterButton extends StatelessWidget {
  const CatalogFilterButton({
    super.key,
    required this.watch,
    required this.onChanged,
    this.buttonKey = CatalogFilterButton.defaultKey,
  });

  static const defaultKey = Key('catalog-filter');

  /// `IsPlayed`、`IsUnplayed`，空表示全部。
  final String? watch;
  final ValueChanged<String?> onChanged;
  final Key buttonKey;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final active = watch != null;
    return IconButton(
      key: buttonKey,
      tooltip: l10n.libraryFilter,
      onPressed: () =>
          showCatalogWatchFilter(context, watch: watch, onChanged: onChanged),
      icon: Icon(
        Icons.filter_list,
        color: active ? Theme.of(context).colorScheme.primary : null,
      ),
    );
  }
}

Future<void> showCatalogWatchFilter(
  BuildContext context, {
  required String? watch,
  required ValueChanged<String?> onChanged,
}) {
  return showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    builder: (context) {
      final l10n = AppLocalizations.of(context);
      return Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.lg,
          AppSpacing.lg,
          AppSpacing.xl,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.libraryFilterWatch,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: AppSpacing.md),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [
                _choice(
                  key: const Key('catalog-filter-watch-all'),
                  label: l10n.libraryFilterAll,
                  selected: watch == null,
                  onSelected: () {
                    onChanged(null);
                    Navigator.pop(context);
                  },
                ),
                _choice(
                  key: const Key('catalog-filter-watch-played'),
                  label: l10n.mobileWatched,
                  selected: watch == 'IsPlayed',
                  onSelected: () {
                    onChanged('IsPlayed');
                    Navigator.pop(context);
                  },
                ),
                _choice(
                  key: const Key('catalog-filter-watch-unplayed'),
                  label: l10n.mobileUnwatched,
                  selected: watch == 'IsUnplayed',
                  onSelected: () {
                    onChanged('IsUnplayed');
                    Navigator.pop(context);
                  },
                ),
              ],
            ),
          ],
        ),
      );
    },
  );
}

/// 已选观看状态。点掉即回到全部。
class CatalogWatchChip extends StatelessWidget {
  const CatalogWatchChip({
    super.key,
    required this.watch,
    required this.onClear,
  });

  final String watch;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final label = watch == 'IsPlayed'
        ? l10n.mobileWatched
        : l10n.mobileUnwatched;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.xs,
        AppSpacing.md,
        0,
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: InputChip(label: Text(label), onDeleted: onClear),
      ),
    );
  }
}

Widget _choice({
  required Key key,
  required String label,
  required bool selected,
  required VoidCallback onSelected,
}) {
  return ChoiceChip(
    key: key,
    label: Text(label),
    selected: selected,
    onSelected: (_) => onSelected(),
  );
}
