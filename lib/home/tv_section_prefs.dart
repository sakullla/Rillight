import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/tv_widgets.dart';
import 'package:rillight/auth/auth_scope.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/catalog_controller.dart';
import 'package:rillight/home/catalog_scope.dart';
import 'package:rillight/home/phone_home_sections.dart';

/// 电视首页区块顺序和显隐。按服务器写入
/// `{applicationSupport}/rillight/tv_home_sections.json`。
/// 不读写 `phone_home_sections.json`，也不从手机文件迁移。
class TvSectionPrefs {
  const TvSectionPrefs({
    this.order = PhoneHomeSectionId.fixed,
    this.hidden = const {},
  });

  final List<String> order;
  final Set<String> hidden;

  Map<String, dynamic> toJson() => {'order': order, 'hidden': hidden.toList()};

  factory TvSectionPrefs.fromJson(Map<String, dynamic> json) {
    final rawOrder = json['order'];
    final rawHidden = json['hidden'];
    return TvSectionPrefs(
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

abstract class TvSectionStore {
  Future<TvSectionPrefs> read(String serverId);

  Future<void> write(String serverId, TvSectionPrefs prefs);
}

class MemoryTvSectionStore implements TvSectionStore {
  MemoryTvSectionStore([Map<String, TvSectionPrefs>? seed])
    : _values = Map<String, TvSectionPrefs>.from(seed ?? const {});

  final Map<String, TvSectionPrefs> _values;

  @override
  Future<TvSectionPrefs> read(String serverId) async =>
      _values[serverId] ?? const TvSectionPrefs();

  @override
  Future<void> write(String serverId, TvSectionPrefs prefs) async {
    _values[serverId] = prefs;
  }
}

class FileTvSectionStore implements TvSectionStore {
  FileTvSectionStore(this.file);

  final File file;

  @override
  Future<TvSectionPrefs> read(String serverId) async {
    final all = await _readAll();
    final json = all[serverId];
    if (json is! Map) {
      return const TvSectionPrefs();
    }
    return TvSectionPrefs.fromJson(Map<String, dynamic>.from(json));
  }

  @override
  Future<void> write(String serverId, TvSectionPrefs prefs) async {
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

/// 电视首页与编辑弹层共用一份顺序。文件按服务器分开。
class TvSectionController extends ChangeNotifier {
  TvSectionController({TvSectionStore? store}) : _store = store;

  static TvSectionController? _app;

  static TvSectionController app() => _app ??= TvSectionController();

  @visibleForTesting
  static void debugResetApp() {
    final current = _app;
    _app = null;
    current?.dispose();
  }

  TvSectionStore? _store;
  String? _serverId;
  TvSectionPrefs _prefs = const TvSectionPrefs();
  bool _disposed = false;

  TvSectionPrefs get prefs => _prefs;

  String? get serverId => _serverId;

  List<String> orderedIds(List<EmbyItem> libraries) {
    return arrangePhoneHomeSections(_prefsForArrange(), _knownIds(libraries));
  }

  List<String> visibleIds(List<EmbyItem> libraries) {
    return [
      for (final id in orderedIds(libraries))
        if (!_prefs.hidden.contains(id)) id,
    ];
  }

  bool isHidden(String id) => _prefs.hidden.contains(id);

  PhoneHomeSectionPrefs _prefsForArrange() {
    return PhoneHomeSectionPrefs(order: _prefs.order, hidden: _prefs.hidden);
  }

  List<String> _knownIds(List<EmbyItem> libraries) {
    return phoneHomeSectionIdsFor(libraries);
  }

  Future<void> load(String serverId) async {
    if (_disposed) {
      return;
    }
    if (_serverId == serverId && _store != null) {
      return;
    }
    final previous = _serverId;
    _serverId = serverId;
    if (previous != serverId) {
      _prefs = const TvSectionPrefs();
      if (!_disposed) {
        notifyListeners();
      }
    }
    _store ??= await openTvSectionStore();
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
    await _save(TvSectionPrefs(order: _prefs.order, hidden: hidden));
  }

  /// 只在当前已知栏目里移动。不在本次片库中的已保存 id 留在原来的相对位置。
  Future<void> move(String id, int delta, List<EmbyItem> libraries) async {
    final known = orderedIds(libraries);
    final index = known.indexOf(id);
    final next = index + delta;
    if (index < 0 || next < 0 || next >= known.length) {
      return;
    }
    final swapped = List<String>.of(known);
    final moved = swapped.removeAt(index);
    swapped.insert(next, moved);
    await _save(
      TvSectionPrefs(order: _mergeMovedOrder(swapped), hidden: _prefs.hidden),
    );
  }

  /// 用调整后的已知顺序替换已保存顺序里的已知栏目，其余 id 原地保留。
  List<String> _mergeMovedOrder(List<String> swappedKnown) {
    final known = swappedKnown.toSet();
    final merged = <String>[];
    var cursor = 0;
    for (final id in _prefs.order) {
      if (!known.contains(id)) {
        merged.add(id);
        continue;
      }
      if (cursor >= swappedKnown.length) {
        continue;
      }
      merged.add(swappedKnown[cursor]);
      cursor++;
    }
    if (cursor < swappedKnown.length) {
      merged.addAll(swappedKnown.sublist(cursor));
    }
    return merged;
  }

  Future<void> _save(TvSectionPrefs prefs) async {
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

MemoryTvSectionStore? _testStore;

Future<TvSectionStore> openTvSectionStore() async {
  if (Platform.environment['FLUTTER_TEST'] == 'true') {
    return _testStore ??= MemoryTvSectionStore();
  }
  try {
    final support = await getApplicationSupportDirectory();
    return FileTvSectionStore(
      File('${support.path}/rillight/tv_home_sections.json'),
    );
  } catch (_) {
    return MemoryTvSectionStore();
  }
}

@visibleForTesting
void debugResetTvSectionStore() {
  _testStore = null;
}

/// 电视首页编辑。显隐用开关，排序用上移、下移，不用拖动手柄。
Future<void> showTvSectionEditor(BuildContext context) {
  final catalog = CatalogScope.of(context);
  final sections = TvSectionController.app();
  final serverId = AuthScope.maybeOf(context)?.session?.server.id ?? '';
  unawaited(sections.load(serverId));
  // 根导航上的对话框不会让壳内路由离开 current，TvFocusRegion 会把焦点抢回去。
  return showDialog<void>(
    context: context,
    useRootNavigator: false,
    builder: (context) {
      final viewport = MediaQuery.sizeOf(context);
      final s = TvDesign.scaleOf(context);
      final width = (viewport.width - 96 * s).clamp(0.0, 560 * s);
      final height = (viewport.height - 54 * s).clamp(0.0, 480 * s);
      return Dialog(
        child: SizedBox(
          key: TvSectionEditor.editorKey,
          width: width,
          height: height,
          child: _TvSectionDialog(controller: sections, catalog: catalog),
        ),
      );
    },
  );
}

class _TvSectionDialog extends StatefulWidget {
  const _TvSectionDialog({required this.controller, required this.catalog});

  final TvSectionController controller;
  final CatalogController catalog;

  @override
  State<_TvSectionDialog> createState() => _TvSectionDialogState();
}

class _TvSectionDialogState extends State<_TvSectionDialog> {
  final _initialFocus = FocusNode();
  var _initialAttempts = 0;
  var _focusedOnce = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focusInitial());
  }

  void _focusInitial() {
    if (!mounted || _focusedOnce || _initialAttempts > 12) {
      return;
    }
    _initialAttempts++;
    final ready =
        _initialFocus.context != null &&
        ModalRoute.of(context)?.isCurrent == true;
    if (!ready) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _focusInitial());
      return;
    }
    if (!_initialFocus.hasPrimaryFocus) {
      _initialFocus.requestFocus();
      // 焦点通知在微任务里。同步落地后下一帧才能画出焦点环。
      FocusManager.instance.applyFocusChangesIfNeeded();
    }
    if (!_initialFocus.hasPrimaryFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _focusInitial());
      return;
    }
    _focusedOnce = true;
    setState(() {});
  }

  @override
  void dispose() {
    _initialFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TvSectionEditor(
      controller: widget.controller,
      catalog: widget.catalog,
      initialFocus: _initialFocus,
    );
  }
}

class TvSectionEditor extends StatelessWidget {
  const TvSectionEditor({
    super.key,
    required this.controller,
    required this.catalog,
    this.initialFocus,
  });

  final TvSectionController controller;
  final CatalogController catalog;
  final FocusNode? initialFocus;

  static const editorKey = Key('tv-home-section-editor');

  static const closeKey = Key('tv-home-section-close');

  static Key tileKey(String id) => Key('tv-home-section-$id');

  static Key visibleKey(String id) => Key('tv-home-section-visible-$id');

  static Key moveUpKey(String id) => Key('tv-home-section-up-$id');

  static Key moveDownKey(String id) => Key('tv-home-section-down-$id');

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([controller, catalog]),
      builder: (context, _) {
        final libraries = catalog.libraries;
        final order = controller.orderedIds(libraries);
        final names = {
          for (final library in libraries) library.id: library.name,
        };
        final s = TvDesign.scaleOf(context);
        return Padding(
          padding: EdgeInsets.fromLTRB(20 * s, 20 * s, 20 * s, 16 * s),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l10n.phoneHomeEdit,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              SizedBox(height: 12 * s),
              Expanded(
                child: ListView(
                  primary: false,
                  padding: EdgeInsets.symmetric(
                    horizontal: 4 * s,
                    vertical: 2 * s,
                  ),
                  children: [
                    for (var index = 0; index < order.length; index++)
                      _row(
                        context,
                        id: order[index],
                        label: _label(l10n, order[index], names),
                        index: index,
                        count: order.length,
                        libraries: libraries,
                        initialFocus: index == 0 ? initialFocus : null,
                      ),
                  ],
                ),
              ),
              SizedBox(height: 12 * s),
              Align(
                alignment: Alignment.centerRight,
                child: TvAction(
                  key: closeKey,
                  pill: true,
                  focusNode: order.length < 2 ? initialFocus : null,
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(l10n.cancelAction),
                ),
              ),
            ],
          ),
        );
      },
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
    required int index,
    required int count,
    required List<EmbyItem> libraries,
    required FocusNode? initialFocus,
  }) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final s = TvDesign.scaleOf(context);
    final visible = !controller.isHidden(id);
    // 一行一个分区:显隐开关 + 名称,右侧上移/下移。上下键在同列间移动。
    return Padding(
      key: tileKey(id),
      padding: EdgeInsets.symmetric(vertical: 3 * s),
      child: Row(
        children: [
          TvAction(
            key: visibleKey(id),
            variant: TvActionVariant.icon,
            selected: visible,
            onPressed: () => controller.setVisible(id, !visible),
            child: Icon(
              visible ? Icons.visibility_rounded : Icons.visibility_off_rounded,
            ),
          ),
          SizedBox(width: 12 * s),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: visible ? null : theme.colorScheme.onSurfaceVariant,
                decoration: visible ? null : TextDecoration.lineThrough,
              ),
            ),
          ),
          TvAction(
            key: moveUpKey(id),
            variant: TvActionVariant.icon,
            onPressed: index == 0
                ? null
                : () => controller.move(id, -1, libraries),
            child: Semantics(
              label: l10n.tvSectionMoveUp,
              child: const Icon(Icons.arrow_upward_rounded),
            ),
          ),
          SizedBox(width: 6 * s),
          TvAction(
            key: moveDownKey(id),
            variant: TvActionVariant.icon,
            focusNode: index == 0 && count > 1 ? initialFocus : null,
            onPressed: index == count - 1
                ? null
                : () => controller.move(id, 1, libraries),
            child: Semantics(
              label: l10n.tvSectionMoveDown,
              child: const Icon(Icons.arrow_downward_rounded),
            ),
          ),
        ],
      ),
    );
  }
}
