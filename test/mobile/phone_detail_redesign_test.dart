import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/presentation_environment.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/library/episode_detail_sections.dart';
import 'package:rillight/library/mobile_detail_page.dart';
import 'package:rillight/library/mobile_series_page.dart';

const _minute = 60 * 10000000;

Widget _phone(Widget child, {double width = 412}) {
  return MaterialApp(
    locale: const Locale('zh'),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    theme: AppTheme.phoneDark(),
    home: PresentationScope(
      environment: PresentationEnvironment.phone,
      child: MediaQuery(
        data: MediaQueryData(size: Size(width, 900)),
        child: Scaffold(body: child),
      ),
    ),
  );
}

void _ignore(String _) {}

void _noop() {}

EmbyItem _episode(int index, {bool played = false}) => EmbyItem(
  id: 'episode-$index',
  name: '第 $index 集',
  type: 'Episode',
  seasonId: 'season-1',
  indexNumber: index,
  parentIndexNumber: 1,
  runTimeTicks: 24 * _minute,
  userData: EmbyUserData(played: played),
);

MobileSeriesPage _series({
  required List<EmbyItem> seasons,
  required List<EmbyItem> episodes,
  bool hasMore = false,
  int? episodeTotal,
}) {
  return MobileSeriesPage(
    item: const EmbyItem(
      id: 'series',
      name: '剧',
      type: 'Series',
      genres: ['动画', '奇幻'],
    ),
    seasons: seasons,
    seasonId: 'season-1',
    episodes: episodes,
    episodesLoading: false,
    episodeError: null,
    hasMore: hasMore,
    episodeTotal: episodeTotal,
    playTargetId: 'episode-2',
    similar: const [],
    onPickEpisode: _noop,
    onSelectSeason: _ignore,
    onOpenEpisode: _ignore,
    onRetryEpisodes: _noop,
    onLoadMore: _noop,
    onOpenItem: _ignore,
    onOpenSimilar: _noop,
  );
}

Widget _slivers(MobileSeriesPage page) => Builder(
  builder: (context) => CustomScrollView(slivers: page.buildSlivers(context)),
);

void main() {
  group('phoneTechBadges', () {
    test('summarises resolution, HDR, immersive audio and subtitles', () {
      const source = ItemMediaSource(
        id: 'source',
        streams: [
          ItemMediaStream(
            index: 0,
            type: 'Video',
            codec: 'hevc',
            height: 2160,
            videoRange: 'HDR',
            videoRangeType: 'DOVIWithHDR10',
          ),
          ItemMediaStream(index: 1, type: 'Audio', codec: 'aac', channels: 2),
          ItemMediaStream(
            index: 2,
            type: 'Audio',
            codec: 'truehd',
            channels: 8,
            profile: 'Dolby TrueHD + Dolby Atmos',
            isDefault: true,
          ),
          ItemMediaStream(index: 3, type: 'Subtitle', codec: 'srt'),
        ],
      );
      expect(phoneTechBadges(source), [
        '4K',
        'DOLBY VISION',
        'ATMOS',
        '7.1',
        'CC',
      ]);
    });

    test('plain stereo SDR shows only the resolution', () {
      const source = ItemMediaSource(
        id: 'source',
        streams: [
          ItemMediaStream(index: 0, type: 'Video', height: 1080),
          ItemMediaStream(index: 1, type: 'Audio', channels: 2),
        ],
      );
      expect(phoneTechBadges(source), ['1080P']);
      expect(phoneTechBadges(null), isEmpty);
    });
  });

  group('season summary', () {
    testWidgets('a single season names itself and counts watched episodes', (
      tester,
    ) async {
      await tester.pumpWidget(
        _phone(
          _slivers(
            _series(
              seasons: [
                EmbyItem(
                  id: 'season-1',
                  name: '第 1 季',
                  type: 'Season',
                  productionYear: 2026,
                  childCount: 2,
                  overview: '圣女隐瞒身份的第一年。',
                ),
              ],
              episodes: [_episode(1, played: true), _episode(2)],
              episodeTotal: 2,
            ),
          ),
        ),
      );
      await tester.pump();

      // 一季时不画单独一颗季标签，季名写在概况卡里。
      expect(find.byKey(const Key('phone-season-list')), findsNothing);
      expect(find.byType(PhoneSeasonTab), findsNothing);
      final summary = find.byKey(MobileSeriesPage.seasonSummaryKey);
      expect(summary, findsOneWidget);
      expect(
        find.descendant(of: summary, matching: find.text('第 1 季')),
        findsOneWidget,
      );
      expect(find.text('2026 · 2 集'), findsOneWidget);
      expect(find.text('已看 1/2'), findsOneWidget);
      expect(find.text('圣女隐瞒身份的第一年。'), findsOneWidget);
      // 已看只由剧照上的勾表达。
      expect(find.byKey(const Key('phone-episode-watched')), findsOneWidget);
      expect(find.text('已看'), findsNothing);
      expect(find.byKey(const Key('phone-episode-current')), findsOneWidget);
      expect(find.byKey(PhoneGenreChips.rowKey), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('several seasons use tabs and do not repeat the name', (
      tester,
    ) async {
      await tester.pumpWidget(
        _phone(
          _slivers(
            _series(
              seasons: const [
                EmbyItem(
                  id: 'season-1',
                  name: '第 1 季',
                  type: 'Season',
                  productionYear: 2024,
                ),
                EmbyItem(id: 'season-2', name: '第 2 季', type: 'Season'),
              ],
              episodes: [_episode(1, played: true), _episode(2)],
              hasMore: true,
              episodeTotal: 40,
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byKey(const Key('phone-season-list')), findsOneWidget);
      expect(find.byType(PhoneSeasonTab), findsNWidgets(2));
      expect(
        tester
            .widget<PhoneSeasonTab>(
              find.widgetWithText(PhoneSeasonTab, '第 1 季'),
            )
            .selected,
        isTrue,
      );
      expect(find.text('第 1 季'), findsOneWidget);
      expect(find.text('2024 · 40 集'), findsOneWidget);
      // 分页没载完时不猜已看比例。
      expect(find.textContaining('已看 '), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('phone info table', () {
    final item = EmbyItem(
      id: 'movie',
      name: '片',
      type: 'Movie',
      runTimeTicks: 106 * _minute,
      premiereDate: DateTime(1974, 12, 15),
      dateCreated: DateTime(2026, 10, 3),
    );
    const source = ItemMediaSource(
      id: 'source',
      container: 'mkv',
      size: 2684354560,
      bitrate: 12400000,
    );

    testWidgets('phone lists dates, runtime and file facts', (tester) async {
      await tester.pumpWidget(
        _phone(
          SingleChildScrollView(
            child: EpisodeMetadataSection(item: item, source: source),
          ),
        ),
      );
      expect(find.text('详细信息'), findsOneWidget);
      expect(find.text('首播日期'), findsOneWidget);
      expect(find.text('1974-12-15'), findsOneWidget);
      expect(find.text('1小时46分钟'), findsOneWidget);
      expect(find.text('2026-10-03'), findsOneWidget);
      expect(find.text('MKV'), findsOneWidget);
      expect(find.text('2.50 GB'), findsOneWidget);
      expect(find.text('12.4 Mbps'), findsOneWidget);
      // 数值右对齐到卡片内边距。
      final value = tester.getRect(find.text('MKV'));
      final width = tester.getSize(find.byType(Scaffold)).width;
      expect(value.right, closeTo(width - 16 - 16, 1));
    });

    testWidgets('desktop keeps the short metadata section', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          theme: AppTheme.dark(),
          home: Scaffold(
            body: EpisodeMetadataSection(item: item, source: source),
          ),
        ),
      );
      expect(find.text('元数据'), findsOneWidget);
      expect(find.text('2026-10-03'), findsOneWidget);
      expect(find.text('MKV'), findsNothing);
    });
  });
}
