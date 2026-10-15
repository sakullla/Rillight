import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/search/recent_searches.dart';

void main() {
  test('newest term first, case-insensitive dedupe and a size limit', () async {
    final store = MemoryRecentSearchStore(['旧词']);
    final recent = RecentSearches(store: store);
    await recent.load();
    expect(recent.terms, ['旧词']);

    await recent.add('  Inception ');
    await recent.add('飞屋');
    await recent.add('inception');
    expect(recent.terms, ['inception', '飞屋', '旧词']);
    expect(store.terms, recent.terms);

    await recent.add('   ');
    expect(recent.terms, hasLength(3));

    for (var i = 0; i < RecentSearches.limit + 4; i++) {
      await recent.add('词$i');
    }
    expect(recent.terms, hasLength(RecentSearches.limit));
    expect(recent.terms.first, '词${RecentSearches.limit + 3}');

    await recent.remove(recent.terms.first);
    expect(recent.terms.first, '词${RecentSearches.limit + 2}');

    await recent.clear();
    expect(recent.terms, isEmpty);
    expect(store.terms, isEmpty);
  });

  test('file store survives a restart and ignores a damaged file', () async {
    final dir = await Directory.systemTemp.createTemp('recent-searches');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/rillight/recent_searches.json');

    final first = RecentSearches(store: FileRecentSearchStore(file));
    await first.add('老友记');
    await first.add('飞屋环游记');

    final second = RecentSearches(store: FileRecentSearchStore(file));
    await second.load();
    expect(second.terms, ['飞屋环游记', '老友记']);

    await file.writeAsString('{not json');
    final third = RecentSearches(store: FileRecentSearchStore(file));
    await third.load();
    expect(third.terms, isEmpty);
  });
}
