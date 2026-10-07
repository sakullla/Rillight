import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/library/episode_list.dart';

void main() {
  testWidgets('long seasons are lazy and distant episodes remain reachable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final scroll = ScrollController();
    final selected = ValueNotifier(0);
    addTearDown(scroll.dispose);
    addTearDown(selected.dispose);
    final episodes = List.generate(
      200,
      (index) => EmbyItem(
        id: 'episode-$index',
        name: '分集 $index',
        type: 'Episode',
        indexNumber: index + 1,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Scaffold(
          body: ValueListenableBuilder(
            valueListenable: selected,
            builder: (context, index, _) => CustomScrollView(
              controller: scroll,
              slivers: [
                const SliverToBoxAdapter(child: SizedBox(height: 600)),
                EpisodeList(
                  episodes: episodes,
                  currentId: 'episode-$index',
                  revealToken: index,
                  loading: false,
                  error: null,
                  onRetry: null,
                  hasMore: false,
                  loadingMore: false,
                  onLoadMore: () {},
                  headerAction: const SizedBox.shrink(),
                  onTap: (_) {},
                  onPlay: (_) {},
                  onTogglePlayed: (_) {},
                  busyPlayedIds: const {},
                  onMore: null,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(EpisodeRow).evaluate().length, lessThan(16));
    expect(find.byKey(const ValueKey('episode-row-episode-199')), findsNothing);

    selected.value = 180;
    await tester.pumpAndSettle();
    final target = find.byKey(const ValueKey('episode-row-episode-180'));
    expect(target, findsOneWidget);
    expect(
      tester.getRect(target).overlaps(const Rect.fromLTWH(0, 0, 1440, 900)),
      isTrue,
    );
    expect(find.byType(EpisodeRow).evaluate().length, lessThan(16));

    // Revisiting the selected row through normal scrolling must not trigger
    // another automatic seek merely because its element was recreated.
    scroll.jumpTo(0);
    await tester.pumpAndSettle();
    expect(scroll.offset, 0);
    selected.value = 199;
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('episode-row-episode-199')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
