import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/theme/tokens.dart';
import 'package:rillight/app/widgets/liquid_glass.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/library_nav_prefs.dart';

Future<String?> showMoreLibrariesDialog({
  required BuildContext context,
  required List<EmbyItem> libraries,
}) {
  return showDialog<String>(
    context: context,
    builder: (context) {
      final theme = Theme.of(context);
      final l10n = AppLocalizations.of(context);
      return Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        child: LiquidGlass(
          kind: LiquidGlassKind.panel,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360, maxHeight: 320),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg,
                    AppSpacing.lg,
                    AppSpacing.lg,
                    AppSpacing.sm,
                  ),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      l10n.libraries,
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                ),
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: libraries.length,
                    itemBuilder: (context, index) {
                      final library = libraries[index];
                      return ListTile(
                        key: Key('overflow-more-${library.id}'),
                        title: Text(library.name),
                        onTap: () => Navigator.of(context).pop(library.id),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

Future<void> showLibraryNavDialog({
  required BuildContext context,
  required List<EmbyItem> libraries,
  required LibraryNavController nav,
  required int maxPinned,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) {
      return _LibraryNavDialog(
        libraries: libraries,
        nav: nav,
        maxPinned: maxPinned,
      );
    },
  );
}

class _LibraryNavDialog extends StatefulWidget {
  const _LibraryNavDialog({
    required this.libraries,
    required this.nav,
    required this.maxPinned,
  });

  final List<EmbyItem> libraries;
  final LibraryNavController nav;
  final int maxPinned;

  @override
  State<_LibraryNavDialog> createState() => _LibraryNavDialogState();
}

class _LibraryNavDialogState extends State<_LibraryNavDialog> {
  late List<String> _pinned;
  late final Map<String, EmbyItem> _byId;

  @override
  void initState() {
    super.initState();
    _byId = {for (final library in widget.libraries) library.id: library};
    final layout = arrangeLibraries(
      widget.libraries,
      widget.nav.pinnedIds,
      maxPinned: widget.maxPinned,
      customized: widget.nav.customized,
    );
    _pinned = [for (final library in layout.pinned) library.id];
  }

  List<EmbyItem> get _pinnedLibraries {
    return [
      for (final id in _pinned)
        if (_byId.containsKey(id)) _byId[id]!,
    ];
  }

  List<EmbyItem> get _uncheckedLibraries {
    final pinned = _pinned.toSet();
    return [
      for (final library in widget.libraries)
        if (!pinned.contains(library.id)) library,
    ];
  }

  void _setPinned(bool checked, EmbyItem library) {
    setState(() {
      if (checked) {
        if (_pinned.length >= widget.maxPinned ||
            _pinned.contains(library.id)) {
          return;
        }
        _pinned = [..._pinned, library.id];
        return;
      }
      _pinned = [
        for (final id in _pinned)
          if (id != library.id) id,
      ];
    });
  }

  void _movePinned(int index, int delta) {
    final nextIndex = index + delta;
    if (index < 0 || nextIndex < 0 || nextIndex >= _pinned.length) {
      return;
    }
    setState(() {
      final next = [..._pinned];
      next[nextIndex] = _pinned[index];
      next[index] = _pinned[nextIndex];
      _pinned = next;
    });
  }

  void _onReorderItem(int oldIndex, int newIndex) {
    setState(() {
      final id = _pinned.removeAt(oldIndex);
      _pinned.insert(newIndex, id);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final pinnedLibraries = _pinnedLibraries;
    final unchecked = _uncheckedLibraries;
    return AlertDialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      contentPadding: EdgeInsets.zero,
      content: LiquidGlass(
        kind: LiquidGlassKind.panel,
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.lg,
          AppSpacing.lg,
          AppSpacing.md,
        ),
        child: SizedBox(
          width: 480,
          height: 480,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l10n.customizeNav,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                l10n.customizeNavHint(widget.maxPinned),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: AppSpacing.sm),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(right: AppSpacing.lg),
                  child: CustomScrollView(
                    scrollCacheExtent: const ScrollCacheExtent.pixels(2000),
                    slivers: [
                      SliverReorderableList(
                        itemCount: pinnedLibraries.length,
                        onReorderItem: _onReorderItem,
                        itemBuilder: (context, index) {
                          return _pinnedRow(
                            context,
                            pinnedLibraries[index],
                            index,
                            pinnedLibraries.length,
                          );
                        },
                      ),
                      SliverList(
                        delegate: SliverChildBuilderDelegate((context, index) {
                          return _uncheckedRow(context, unchecked[index]);
                        }, childCount: unchecked.length),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(
                      MaterialLocalizations.of(context).cancelButtonLabel,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  FilledButton(
                    onPressed: () async {
                      await widget.nav.savePinned(_pinned);
                      if (context.mounted) {
                        Navigator.of(context).pop();
                      }
                    },
                    child: Text(l10n.saveNav),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _pinnedRow(
    BuildContext context,
    EmbyItem library,
    int index,
    int count,
  ) {
    final l10n = AppLocalizations.of(context);
    return Material(
      key: ValueKey(library.id),
      type: MaterialType.transparency,
      child: Row(
        children: [
          Checkbox(value: true, onChanged: (_) => _setPinned(false, library)),
          Expanded(
            child: ReorderableDragStartListener(
              index: index,
              child: Row(
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: AppSpacing.sm,
                      ),
                      child: Text(library.name),
                    ),
                  ),
                  IconButton(
                    key: Key('nav-pin-up-${library.id}'),
                    tooltip: l10n.moveNavUp,
                    onPressed: index <= 0 ? null : () => _movePinned(index, -1),
                    icon: const Icon(Icons.arrow_upward, size: 18),
                  ),
                  IconButton(
                    key: Key('nav-pin-down-${library.id}'),
                    tooltip: l10n.moveNavDown,
                    onPressed: index >= count - 1
                        ? null
                        : () => _movePinned(index, 1),
                    icon: const Icon(Icons.arrow_downward, size: 18),
                  ),
                  const Padding(
                    padding: EdgeInsets.only(
                      left: AppSpacing.xs,
                      right: AppSpacing.sm,
                    ),
                    child: Icon(Icons.drag_handle, size: 18),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _uncheckedRow(BuildContext context, EmbyItem library) {
    return ListTile(
      key: ValueKey(library.id),
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Checkbox(
        value: false,
        onChanged: _pinned.length >= widget.maxPinned
            ? null
            : (_) => _setPinned(true, library),
      ),
      title: Text(library.name),
    );
  }
}
