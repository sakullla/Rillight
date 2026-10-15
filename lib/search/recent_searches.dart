import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 最近搜索词的持久化。测试环境只在内存里保存。
abstract class RecentSearchStore {
  Future<List<String>> read();

  Future<void> write(List<String> terms);
}

class MemoryRecentSearchStore implements RecentSearchStore {
  MemoryRecentSearchStore([List<String>? terms]) : terms = [...?terms];

  List<String> terms;

  @override
  Future<List<String>> read() async => [...terms];

  @override
  Future<void> write(List<String> terms) async {
    this.terms = [...terms];
  }
}

class FileRecentSearchStore implements RecentSearchStore {
  FileRecentSearchStore(this.file);

  final File file;

  @override
  Future<List<String>> read() async {
    try {
      if (!await file.exists()) return const [];
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map && decoded['terms'] is List) {
        return [
          for (final term in decoded['terms'] as List)
            if (term is String && term.trim().isNotEmpty) term.trim(),
        ];
      }
    } catch (_) {}
    return const [];
  }

  @override
  Future<void> write(List<String> terms) async {
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode({'terms': terms}));
  }
}

Future<RecentSearchStore> _openStore() async {
  if (Platform.environment['FLUTTER_TEST'] == 'true') {
    return MemoryRecentSearchStore();
  }
  try {
    final support = await getApplicationSupportDirectory();
    return FileRecentSearchStore(
      File('${support.path}/rillight/recent_searches.json'),
    );
  } catch (_) {
    return MemoryRecentSearchStore();
  }
}

/// 手机搜索页的「最近搜索」。新词排到最前，去重，最多保留 [limit] 条。
class RecentSearches extends ChangeNotifier {
  RecentSearches({this._store});

  static const limit = 12;

  /// 整个应用共用一份;第一次读取时才打开存储。
  static final RecentSearches instance = RecentSearches();

  RecentSearchStore? _store;
  List<String> _terms = const [];
  Future<void>? _loading;
  bool _loaded = false;

  List<String> get terms => _terms;
  bool get loaded => _loaded;

  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    final store = _store ??= await _openStore();
    final terms = await store.read();
    if (_loaded) return;
    _loaded = true;
    _terms = List.unmodifiable(terms.take(limit));
    notifyListeners();
  }

  Future<void> add(String term) async {
    final value = term.trim();
    if (value.isEmpty) return;
    await load();
    final next = [
      value,
      for (final existing in _terms)
        if (existing.toLowerCase() != value.toLowerCase()) existing,
    ].take(limit).toList();
    if (listEquals(next, _terms)) return;
    _terms = List.unmodifiable(next);
    notifyListeners();
    await _persist();
  }

  Future<void> remove(String term) async {
    await load();
    final next = [
      for (final existing in _terms)
        if (existing != term) existing,
    ];
    if (next.length == _terms.length) return;
    _terms = List.unmodifiable(next);
    notifyListeners();
    await _persist();
  }

  Future<void> clear() async {
    await load();
    if (_terms.isEmpty) return;
    _terms = const [];
    notifyListeners();
    await _persist();
  }

  Future<void> _persist() async {
    try {
      final store = _store ??= await _openStore();
      await store.write(_terms);
    } catch (_) {
      // 写盘失败只影响下次启动，不打断搜索。
    }
  }

  @visibleForTesting
  void debugReset([RecentSearchStore? store]) {
    _store = store;
    _terms = const [];
    _loading = null;
    _loaded = false;
  }
}
