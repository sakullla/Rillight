import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:rillight/player/danmaku/danmaku_keys.dart';
import 'package:rillight/player/danmaku/dandanplay_client.dart';

import '../../test/player/danmaku/danmaku_controller_cases.dart'
    show FakeDandanplayClient;
import 'capture.dart';

extension DanmakuCaptures on CaptureSession {
  Future<void> openDanmaku() async {
    if (platform == 'desktop') {
      await tap(DanmakuKeys.menu);
    } else {
      await tap(const Key('mobile-player-more'));
      await tap(const ValueKey('mobile-player-section-danmaku'));
      await tap(DanmakuKeys.panel);
    }
  }

  Future<void> danmakuPages(
    FakeDandanplayClient client, {
    String prefix = 'danmaku',
  }) async {
    await openDanmaku();
    await save('$prefix-style');
    await tap(DanmakuKeys.toggle);
    await save('$prefix-disabled');
    await tap(DanmakuKeys.toggle);
    await tap(DanmakuKeys.advancedToggle);
    await save('$prefix-advanced');
    await tester.ensureVisible(find.byKey(DanmakuKeys.keywordInput));
    await advance(150);
    await save('$prefix-keyword-filter');
    await tap(DanmakuKeys.search);
    await save('$prefix-search');
    final results = client.searchResponse;
    final gate = Completer<void>();
    client.searchGate = gate;
    await tester.enterText(find.byKey(DanmakuKeys.searchField), '飞屋');
    await tap(DanmakuKeys.searchSubmit);
    expect(find.byKey(DanmakuKeys.searchLoading), findsOneWidget);
    await save('$prefix-search-loading');
    client.searchGate = null;
    gate.complete();
    await advance(500);
    await save('$prefix-search-results');
    await tap(DanmakuKeys.searchAnime(10));
    await save('$prefix-episode-picker');
    client.searchResponse = [];
    await tester.enterText(find.byKey(DanmakuKeys.searchField), '无匹配');
    await tap(DanmakuKeys.searchSubmit);
    await save('$prefix-search-empty');
    client.searchError = const DanmakuApiException(
      DanmakuApiFailureKind.unreachable,
    );
    await tap(DanmakuKeys.searchSubmit);
    await save('$prefix-search-error');
    client.searchError = null;
    client.searchResponse = results;
    await tester.enterText(find.byKey(DanmakuKeys.searchField), '飞屋');
    await tap(DanmakuKeys.searchSubmit);
    if (find.byKey(DanmakuKeys.searchEpisode(100)).evaluate().isEmpty) {
      await tap(DanmakuKeys.searchAnime(10));
    }
    await tap(DanmakuKeys.searchEpisode(100));
    await advance(600);
    await save('$prefix-matched');
  }
}
