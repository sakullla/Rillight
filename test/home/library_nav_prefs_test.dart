import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/library_nav_prefs.dart';

EmbyItem _lib(String id, String name) {
  return EmbyItem(id: id, name: name, type: 'CollectionFolder');
}

void main() {
  test('empty pins keep the first max libraries in catalog order', () {
    final libraries = [
      _lib('a', 'A'),
      _lib('b', 'B'),
      _lib('c', 'C'),
      _lib('d', 'D'),
    ];
    final layout = arrangeLibraries(libraries, const [], maxPinned: 2);
    expect(layout.pinned.map((item) => item.id), ['a', 'b']);
    expect(layout.overflow.map((item) => item.id), ['c', 'd']);
  });

  test('saved pin order is kept and unknown ids are dropped', () {
    final libraries = [_lib('a', 'A'), _lib('b', 'B'), _lib('c', 'C')];
    final layout = arrangeLibraries(libraries, const [
      'c',
      'gone',
      'a',
    ], maxPinned: 5);
    expect(layout.pinned.map((item) => item.id), ['c', 'a']);
    expect(layout.overflow.map((item) => item.id), ['b']);
  });

  test('customized pins hide the rest from overflow', () {
    final libraries = [
      _lib('a', 'A'),
      _lib('b', 'B'),
      _lib('c', 'C'),
      _lib('d', 'D'),
    ];
    final layout = arrangeLibraries(
      libraries,
      const ['a', 'c'],
      maxPinned: 5,
      customized: true,
    );
    expect(layout.pinned.map((item) => item.id), ['a', 'c']);
    expect(layout.overflow, isEmpty);
    expect(layout.hidden.map((item) => item.id), ['b', 'd']);
  });

  test('stale preference read does not replace the current server', () async {
    final inner = MemoryLibraryNavStore({
      'a': const LibraryNavPrefs(pinnedIds: ['lib-a'], customized: true),
      'b': const LibraryNavPrefs(pinnedIds: ['lib-b'], customized: true),
    });
    final store = _GatedNavStore(inner);
    store.hold['a'] = Completer<void>();
    final nav = LibraryNavController(store: store);
    final first = nav.load('a');
    await nav.load('b');
    expect(nav.pinnedIds, ['lib-b']);
    store.hold['a']!.complete();
    await first;
    expect(nav.pinnedIds, ['lib-b']);
    nav.dispose();
  });
}

class _GatedNavStore implements LibraryNavStore {
  _GatedNavStore(this.inner);

  final LibraryNavStore inner;
  final Map<String, Completer<void>> hold = {};

  @override
  Future<LibraryNavPrefs> read(String serverId) async {
    final gate = hold[serverId];
    if (gate != null) {
      await gate.future;
    }
    return inner.read(serverId);
  }

  @override
  Future<void> write(String serverId, LibraryNavPrefs prefs) {
    return inner.write(serverId, prefs);
  }
}
