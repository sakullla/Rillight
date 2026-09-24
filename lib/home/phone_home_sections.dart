import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/emby/emby_models.dart';

/// 手机首页区块 id。片库「最近添加」用 [libraryLatest]。
abstract final class PhoneHomeSectionId {
  static const banner = 'banner';
  static const resume = 'resume';
  static const nextUp = 'nextUp';
  static const latestMovies = 'latestMovies';
  static const latestSeries = 'latestSeries';
  static const libraries = 'libraries';

  static const fixed = <String>[
    banner,
    resume,
    nextUp,
    latestMovies,
    latestSeries,
    libraries,
  ];

  static String libraryLatest(String libraryId) => 'library:$libraryId';

  static String? libraryIdOf(String sectionId) {
    const prefix = 'library:';
    if (!sectionId.startsWith(prefix)) {
      return null;
    }
    final id = sectionId.substring(prefix.length);
    return id.isEmpty ? null : id;
  }
}

/// 本机首页区块顺序与隐藏。缺省顺序即 [PhoneHomeSectionId.fixed]，全部显示。
class PhoneHomeSectionPrefs {
  const PhoneHomeSectionPrefs({
    this.order = PhoneHomeSectionId.fixed,
    this.hidden = const {},
  });

  final List<String> order;
  final Set<String> hidden;

  Map<String, dynamic> toJson() => {'order': order, 'hidden': hidden.toList()};

  factory PhoneHomeSectionPrefs.fromJson(Map<String, dynamic> json) {
    final rawOrder = json['order'];
    final rawHidden = json['hidden'];
    return PhoneHomeSectionPrefs(
      order: rawOrder is List
          ? [
              for (final id in rawOrder)
                if (id != null && id.toString().isNotEmpty) id.toString(),
            ]
          : PhoneHomeSectionId.fixed,
      hidden: rawHidden is List
          ? {
              for (final id in rawHidden)
                if (id != null && id.toString().isNotEmpty) id.toString(),
            }
          : const {},
    );
  }
}

/// 已知区块按已保存顺序排列，新出现的媒体库行接在末尾。
List<String> arrangePhoneHomeSections(
  PhoneHomeSectionPrefs prefs,
  List<String> knownIds,
) {
  final known = knownIds.toSet();
  final ordered = <String>[
    for (final id in prefs.order)
      if (known.contains(id)) id,
  ];
  for (final id in knownIds) {
    if (!ordered.contains(id)) {
      ordered.add(id);
    }
  }
  return ordered;
}

List<String> phoneHomeSectionIdsFor(List<EmbyItem> libraries) {
  return [
    ...PhoneHomeSectionId.fixed,
    for (final library in libraries)
      PhoneHomeSectionId.libraryLatest(library.id),
  ];
}

abstract class PhoneHomeSectionStore {
  Future<PhoneHomeSectionPrefs> read(String serverId);

  Future<void> write(String serverId, PhoneHomeSectionPrefs prefs);
}

class MemoryPhoneHomeSectionStore implements PhoneHomeSectionStore {
  MemoryPhoneHomeSectionStore([Map<String, PhoneHomeSectionPrefs>? seed])
    : _values = Map<String, PhoneHomeSectionPrefs>.from(seed ?? const {});

  final Map<String, PhoneHomeSectionPrefs> _values;

  @override
  Future<PhoneHomeSectionPrefs> read(String serverId) async =>
      _values[serverId] ?? const PhoneHomeSectionPrefs();

  @override
  Future<void> write(String serverId, PhoneHomeSectionPrefs prefs) async {
    _values[serverId] = prefs;
  }
}

class FilePhoneHomeSectionStore implements PhoneHomeSectionStore {
  FilePhoneHomeSectionStore(this.file);

  final File file;

  @override
  Future<PhoneHomeSectionPrefs> read(String serverId) async {
    final all = await _readAll();
    final json = all[serverId];
    if (json is! Map) {
      return const PhoneHomeSectionPrefs();
    }
    return PhoneHomeSectionPrefs.fromJson(Map<String, dynamic>.from(json));
  }

  @override
  Future<void> write(String serverId, PhoneHomeSectionPrefs prefs) async {
    final all = await _readAll();
    all[serverId] = prefs.toJson();
    await file.parent.create(recursive: true);
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(all));
  }

  Future<Map<String, dynamic>> _readAll() async {
    try {
      if (!await file.exists()) {
        return {};
      }
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
    } catch (_) {}
    return {};
  }
}

/// 首页与「我的」共用一份顺序。文件按服务器分开，不读写片库钉选。
class PhoneHomeSectionController extends ChangeNotifier {
  PhoneHomeSectionController({PhoneHomeSectionStore? store}) : _store = store;

  static PhoneHomeSectionController? _app;

  /// 底栏首页和「我的」路由不经过同一个 State，用这一份让隐藏和排序立刻反映到首页。
  static PhoneHomeSectionController app() =>
      _app ??= PhoneHomeSectionController();

  @visibleForTesting
  static void debugResetApp() {
    final current = _app;
    _app = null;
    current?.dispose();
  }

  PhoneHomeSectionStore? _store;
  String? _serverId;
  PhoneHomeSectionPrefs _prefs = const PhoneHomeSectionPrefs();
  bool _disposed = false;

  PhoneHomeSectionPrefs get prefs => _prefs;

  String? get serverId => _serverId;

  List<String> orderedIds(List<EmbyItem> libraries) {
    return arrangePhoneHomeSections(_prefs, phoneHomeSectionIdsFor(libraries));
  }

  List<String> visibleIds(List<EmbyItem> libraries) {
    return [
      for (final id in orderedIds(libraries))
        if (!_prefs.hidden.contains(id)) id,
    ];
  }

  bool isHidden(String id) => _prefs.hidden.contains(id);

  Future<void> load(String serverId) async {
    if (_disposed) {
      return;
    }
    if (_serverId == serverId && _store != null) {
      return;
    }
    _serverId = serverId;
    _store ??= await openPhoneHomeSectionStore();
    final prefs = await _store!.read(serverId);
    if (_disposed || _serverId != serverId) {
      return;
    }
    _prefs = prefs;
    notifyListeners();
  }

  Future<void> setVisible(String id, bool visible) async {
    final hidden = Set<String>.of(_prefs.hidden);
    if (visible) {
      hidden.remove(id);
    } else {
      hidden.add(id);
    }
    await _save(PhoneHomeSectionPrefs(order: _prefs.order, hidden: hidden));
  }

  /// 只重排正在显示的行，未显示的行保持在后面。
  Future<void> reorderVisible(
    int oldIndex,
    int newIndex,
    List<EmbyItem> libraries,
  ) async {
    final order = orderedIds(libraries);
    final shown = [
      for (final id in order)
        if (!isHidden(id)) id,
    ];
    final hidden = [
      for (final id in order)
        if (isHidden(id)) id,
    ];
    if (oldIndex < 0 || oldIndex >= shown.length) {
      return;
    }
    if (newIndex < 0 || newIndex >= shown.length) {
      return;
    }
    final moved = shown.removeAt(oldIndex);
    shown.insert(newIndex, moved);
    await _save(
      PhoneHomeSectionPrefs(
        order: [...shown, ...hidden],
        hidden: _prefs.hidden,
      ),
    );
  }

  Future<void> move(String id, int delta, List<EmbyItem> libraries) async {
    final order = orderedIds(libraries);
    final index = order.indexOf(id);
    final next = index + delta;
    if (index < 0 || next < 0 || next >= order.length) {
      return;
    }
    final swapped = List<String>.of(order);
    final moved = swapped.removeAt(index);
    swapped.insert(next, moved);
    await _save(PhoneHomeSectionPrefs(order: swapped, hidden: _prefs.hidden));
  }

  Future<void> _save(PhoneHomeSectionPrefs prefs) async {
    _prefs = prefs;
    if (!_disposed) {
      notifyListeners();
    }
    final serverId = _serverId;
    final store = _store;
    if (serverId == null || store == null) {
      return;
    }
    await store.write(serverId, prefs);
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

Future<PhoneHomeSectionStore> openPhoneHomeSectionStore() async {
  if (Platform.environment['FLUTTER_TEST'] == 'true') {
    return MemoryPhoneHomeSectionStore();
  }
  try {
    final support = await getApplicationSupportDirectory();
    return FilePhoneHomeSectionStore(
      File('${support.path}/rillight/phone_home_sections.json'),
    );
  } catch (_) {
    return MemoryPhoneHomeSectionStore();
  }
}

/// 首页编辑页里的显示、隐藏和排序。片库页不读这里。
class PhoneHomeSectionEditor extends StatelessWidget {
  const PhoneHomeSectionEditor({
    super.key,
    required this.controller,
    required this.libraries,
  });

  final PhoneHomeSectionController controller;
  final List<EmbyItem> libraries;

  static Key tileKey(String id) => Key('phone-home-section-$id');

  static Key visibleKey(String id) => Key('phone-home-section-visible-$id');

  static Key moveUpKey(String id) => Key('phone-home-section-up-$id');

  static Key moveDownKey(String id) => Key('phone-home-section-down-$id');

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final order = controller.orderedIds(libraries);
    final names = {for (final library in libraries) library.id: library.name};
    final shown = [
      for (final id in order)
        if (!controller.isHidden(id)) id,
    ];
    final hidden = [
      for (final id in order)
        if (controller.isHidden(id)) id,
    ];
    return ReorderableListView(
      header: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          AppSpacing.sm,
          AppSpacing.md,
          AppSpacing.xs,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.phoneHomeEditHint,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            Text(l10n.phoneHomeShown, style: theme.textTheme.titleSmall),
          ],
        ),
      ),
      padding: const EdgeInsets.only(bottom: AppSpacing.lg),
      buildDefaultDragHandles: false,
      onReorderItem: (oldIndex, newIndex) {
        unawaited(controller.reorderVisible(oldIndex, newIndex, libraries));
      },
      footer: hidden.isEmpty
          ? null
          : Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.md,
                AppSpacing.lg,
                AppSpacing.md,
                0,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l10n.phoneHomeHidden, style: theme.textTheme.titleSmall),
                  const SizedBox(height: AppSpacing.xs),
                  for (final id in hidden)
                    _row(
                      context,
                      id: id,
                      label: _label(l10n, id, names),
                      draggable: false,
                    ),
                ],
              ),
            ),
      children: [
        for (var index = 0; index < shown.length; index++)
          _row(
            context,
            id: shown[index],
            label: _label(l10n, shown[index], names),
            index: index,
          ),
      ],
    );
  }

  String _label(AppLocalizations l10n, String id, Map<String, String> names) {
    final libraryId = PhoneHomeSectionId.libraryIdOf(id);
    if (libraryId != null) {
      return l10n.phoneHomeLibraryLatest(names[libraryId] ?? libraryId);
    }
    return switch (id) {
      PhoneHomeSectionId.banner => l10n.phoneHomeSectionBanner,
      PhoneHomeSectionId.resume => l10n.resumeRow,
      PhoneHomeSectionId.nextUp => l10n.phoneHomeSectionNextUp,
      PhoneHomeSectionId.latestMovies => l10n.phoneHomeSectionLatestMovies,
      PhoneHomeSectionId.latestSeries => l10n.phoneHomeSectionLatestSeries,
      PhoneHomeSectionId.libraries => l10n.phoneHomeSectionLibraries,
      _ => id,
    };
  }

  Widget _row(
    BuildContext context, {
    required String id,
    required String label,
    int? index,
    bool draggable = true,
  }) {
    final theme = Theme.of(context);
    final visible = !controller.isHidden(id);
    final handle = Icon(
      Icons.drag_handle,
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Material(
      key: tileKey(id),
      color: Colors.transparent,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
        child: Row(
          children: [
            if (draggable && index != null)
              ReorderableDragStartListener(
                index: index,
                child: SizedBox(
                  width: 48,
                  height: 48,
                  child: Center(child: handle),
                ),
              )
            else
              const SizedBox(width: 48, height: 48),
            Expanded(
              child: Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: visible ? null : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            Switch(
              key: visibleKey(id),
              value: visible,
              onChanged: (value) => controller.setVisible(id, value),
            ),
          ],
        ),
      ),
    );
  }
}

/// 编辑器外层间距，和「我的」其它分组的卡片内边距对齐。
const EdgeInsets phoneHomeSectionEditorPadding = EdgeInsets.symmetric(
  vertical: AppSpacing.sm,
);
