import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:rillight/emby/emby_models.dart';

/// 每个服务器一组顶栏钉选顺序。未自定义时用片库默认前 N 个,其余进更多。
/// 自定义后未勾选的不出现在顶栏、更多和首页片库。
class LibraryNavPrefs {
  const LibraryNavPrefs({this.pinnedIds = const [], this.customized = false});

  final List<String> pinnedIds;
  final bool customized;

  Map<String, dynamic> toJson() => {
    'pinnedIds': pinnedIds,
    'customized': customized,
  };

  factory LibraryNavPrefs.fromJson(Map<String, dynamic> json) {
    final raw = json['pinnedIds'];
    final pinnedIds = raw is List
        ? [
            for (final id in raw)
              if (id != null && id.toString().isNotEmpty) id.toString(),
          ]
        : const <String>[];
    return LibraryNavPrefs(
      pinnedIds: pinnedIds,
      customized: json['customized'] == true || pinnedIds.isNotEmpty,
    );
  }
}

class LibraryNavLayout {
  const LibraryNavLayout({
    required this.pinned,
    required this.overflow,
    this.hidden = const [],
  });

  final List<EmbyItem> pinned;
  final List<EmbyItem> overflow;
  final List<EmbyItem> hidden;
}

LibraryNavLayout arrangeLibraries(
  List<EmbyItem> libraries,
  List<String> pinnedIds, {
  required int maxPinned,
  bool customized = false,
}) {
  if (libraries.isEmpty || maxPinned <= 0) {
    return const LibraryNavLayout(pinned: [], overflow: []);
  }
  final byId = {for (final library in libraries) library.id: library};
  var pinned = [
    for (final id in pinnedIds)
      if (byId.containsKey(id)) byId[id]!,
  ];
  if (!customized && pinned.isEmpty) {
    pinned = libraries.take(maxPinned).toList();
  } else if (pinned.length > maxPinned) {
    pinned = pinned.take(maxPinned).toList();
  }
  final pinnedSet = {for (final library in pinned) library.id};
  final rest = [
    for (final library in libraries)
      if (!pinnedSet.contains(library.id)) library,
  ];
  if (customized) {
    return LibraryNavLayout(pinned: pinned, overflow: const [], hidden: rest);
  }
  return LibraryNavLayout(pinned: pinned, overflow: rest);
}

abstract class LibraryNavStore {
  Future<LibraryNavPrefs> read(String serverId);

  Future<void> write(String serverId, LibraryNavPrefs prefs);
}

class MemoryLibraryNavStore implements LibraryNavStore {
  MemoryLibraryNavStore([Map<String, LibraryNavPrefs>? seed])
    : _values = Map<String, LibraryNavPrefs>.from(seed ?? const {});

  final Map<String, LibraryNavPrefs> _values;

  @override
  Future<LibraryNavPrefs> read(String serverId) async =>
      _values[serverId] ?? const LibraryNavPrefs();

  @override
  Future<void> write(String serverId, LibraryNavPrefs prefs) async {
    _values[serverId] = prefs;
  }
}

class FileLibraryNavStore implements LibraryNavStore {
  FileLibraryNavStore(this.file);

  final File file;

  @override
  Future<LibraryNavPrefs> read(String serverId) async {
    final all = await _readAll();
    final json = all[serverId];
    if (json is! Map) {
      return const LibraryNavPrefs();
    }
    return LibraryNavPrefs.fromJson(Map<String, dynamic>.from(json));
  }

  @override
  Future<void> write(String serverId, LibraryNavPrefs prefs) async {
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

class LibraryNavController extends ChangeNotifier {
  LibraryNavController({LibraryNavStore? store}) : _store = store;

  LibraryNavStore? _store;
  String? _serverId;
  List<String> _pinnedIds = const [];
  bool _customized = false;
  bool _disposed = false;

  String? get serverId => _serverId;

  List<String> get pinnedIds => _pinnedIds;

  bool get customized => _customized;

  LibraryNavLayout layout(List<EmbyItem> libraries, {required int maxPinned}) {
    return arrangeLibraries(
      libraries,
      _pinnedIds,
      maxPinned: maxPinned,
      customized: _customized,
    );
  }

  Future<void> load(String serverId) async {
    if (_serverId == serverId && _store != null) {
      return;
    }
    _serverId = serverId;
    _store ??= await openLibraryNavStore();
    final prefs = await _store!.read(serverId);
    if (_disposed || _serverId != serverId) {
      return;
    }
    _pinnedIds = prefs.pinnedIds;
    _customized = prefs.customized;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  Future<void> savePinned(List<String> pinnedIds) async {
    _pinnedIds = List<String>.from(pinnedIds);
    _customized = true;
    notifyListeners();
    final serverId = _serverId;
    final store = _store;
    if (serverId == null || store == null) {
      return;
    }
    await store.write(
      serverId,
      LibraryNavPrefs(pinnedIds: _pinnedIds, customized: true),
    );
  }
}

class LibraryNavScope extends InheritedNotifier<LibraryNavController> {
  const LibraryNavScope({
    super.key,
    required LibraryNavController controller,
    required super.child,
  }) : super(notifier: controller);

  static LibraryNavController? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<LibraryNavScope>()
        ?.notifier;
  }
}

Future<LibraryNavStore> openLibraryNavStore() async {
  try {
    final support = await getApplicationSupportDirectory();
    return FileLibraryNavStore(
      File('${support.path}/rillight/library_nav.json'),
    );
  } catch (_) {
    return MemoryLibraryNavStore();
  }
}
