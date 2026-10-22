import '../helpers/cupertino_test_app.dart';
import '../helpers/widget_harness.dart';

import 'package:rillight/app/ui/ui.dart';
import 'package:flutter_test/flutter_test.dart' hide testWidgets;
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/presentation_environment.dart';
import 'package:rillight/media_server/models.dart';
import 'package:rillight/library/episode_detail_sections.dart';
import 'package:rillight/library/mobile_detail_page.dart';
import 'package:rillight/library/mobile_series_page.dart';
import 'package:rillight/media_image/media_image.dart';
import 'package:rillight/home/catalog_keys.dart';

const _minute = 60 * 10000000;

Widget _phone(Widget child, {double width = 412, AppUiThemeData? theme}) {
  return CupertinoTestApp(
    locale: const Locale('zh'),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: [
      AppLocalizations.delegate,
      ...GlobalCupertinoLocalizations.delegates,
    ],
    theme: theme ?? AppUiTheme.phoneDark(),
    home: PresentationScope(
      environment: PresentationEnvironment.phone,
      child: MediaQuery(
        data: MediaQueryData(size: Size(width, 900)),
        child: CupertinoPageScaffold(child: child),
      ),
    ),
  );
}

void _ignore(String _) {}

void _noop() {}

MediaItem _episode(int index, {bool played = false}) => MediaItem(
  id: 'episode-$index',
  name: '第 $index 集',
  type: 'Episode',
  seasonId: 'season-1',
  indexNumber: index,
  parentIndexNumber: 1,
  runtime: Duration(microseconds: (24 * _minute) ~/ 10),
  userData: MediaUserData(played: played),
);

MobileSeriesPage _series({
  required List<MediaItem> seasons,
  required List<MediaItem> episodes,
  bool hasMore = false,
  int? episodeTotal,
  ValueChanged<String> onSelectSeason = _ignore,
}) {
  return MobileSeriesPage(
    item: const MediaItem(
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
    onSelectSeason: onSelectSeason,
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
                MediaItem(
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

      // 一季时不画单独一颗季标签，也不再有季海报概况卡；
      // 集数与已看进度只是分区标题下的一行小字。
      expect(find.byKey(const Key('phone-season-list')), findsNothing);
      expect(find.byKey(CatalogKeys.season('season-1')), findsNothing);
      final summary = find.byKey(MobileSeriesPage.seasonSummaryKey);
      expect(summary, findsOneWidget);
      expect(
        find.descendant(of: summary, matching: find.text('2 集 · 已看 1/2')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: summary, matching: find.byType(MediaImage)),
        findsNothing,
      );
      expect(find.text('第 1 季'), findsNothing);
      expect(find.text('圣女隐瞒身份的第一年。'), findsNothing);
      // 已看只由剧照上的勾表达。
      expect(find.byKey(const Key('phone-episode-watched')), findsOneWidget);
      expect(find.text('已看'), findsNothing);
      expect(find.byKey(const Key('phone-episode-current')), findsOneWidget);
      final currentIcon = tester.widget<Icon>(
        find.byKey(const Key('phone-episode-current')),
      );
      expect(currentIcon.color, const Color(0xffffffff));
      final plate =
          tester
                  .widget<DecoratedBox>(
                    find
                        .ancestor(
                          of: find.byKey(const Key('phone-episode-current')),
                          matching: find.byType(DecoratedBox),
                        )
                        .first,
                  )
                  .decoration
              as BoxDecoration;
      expect(plate.shape, BoxShape.circle);
      expect(plate.color!.a, greaterThan(0.7));
      expect(find.byKey(PhoneGenreChips.rowKey), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('light current episode uses the accent play disc', (
      tester,
    ) async {
      await tester.pumpWidget(
        _phone(
          _slivers(
            _series(
              seasons: [
                const MediaItem(
                  id: 'season-1',
                  name: '第 1 季',
                  type: 'Season',
                  childCount: 2,
                ),
              ],
              episodes: [_episode(1, played: true), _episode(2)],
              episodeTotal: 2,
            ),
          ),
          theme: AppUiTheme.phoneLight(),
        ),
      );
      await tester.pump();
      final icon = tester.widget<Icon>(
        find.byKey(const Key('phone-episode-current')),
      );
      expect(icon.color, AppUiTheme.phoneLight().colorScheme.onPrimary);
    });

    testWidgets('several seasons use tabs and do not repeat the name', (
      tester,
    ) async {
      await tester.pumpWidget(
        _phone(
          _slivers(
            _series(
              seasons: const [
                MediaItem(
                  id: 'season-1',
                  name: '第 1 季',
                  type: 'Season',
                  productionYear: 2024,
                ),
                MediaItem(id: 'season-2', name: '第 2 季', type: 'Season'),
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
      expect(find.byKey(CatalogKeys.season('season-1')), findsOneWidget);
      expect(find.byKey(CatalogKeys.season('season-2')), findsOneWidget);
      expect(_seasonSelected(tester, 'season-1'), isTrue);
      expect(find.text('第 1 季'), findsOneWidget);
      expect(find.text('40 集'), findsOneWidget);
      // 分页没载完时不猜已看比例。
      expect(find.textContaining('已看 '), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('many seasons fold into a picker that opens a bottom sheet', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final picked = <String>[];
      await tester.pumpWidget(
        _phone(
          _slivers(
            _series(
              seasons: [
                for (var index = 1; index <= 8; index++)
                  MediaItem(
                    id: 'season-$index',
                    name: '第 $index 季',
                    type: 'Season',
                  ),
              ],
              episodes: [_episode(1), _episode(2)],
              episodeTotal: 2,
              onSelectSeason: picked.add,
            ),
          ),
          width: 360,
        ),
      );
      await tester.pump();

      // 八季在 360 宽放不下一排标签：折叠为「当前季 ˅」入口。
      expect(find.byKey(const Key('phone-season-list')), findsOneWidget);
      expect(find.byKey(CatalogKeys.seasonPicker), findsOneWidget);
      expect(find.byKey(CatalogKeys.season('season-1')), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(CatalogKeys.seasonPicker),
          matching: find.text('第 1 季'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(CatalogKeys.seasonPicker));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('season-switcher-sheet')), findsOneWidget);
      await tester.tap(find.byKey(CatalogKeys.seasonOption('season-5')));
      await tester.pumpAndSettle();
      expect(picked, ['season-5']);
      expect(find.byKey(const Key('season-switcher-sheet')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('episode rows keep one height and at most two overview lines', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(412, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const long =
          '一段很长很长的分集简介，会在手机宽度下折成好几行，但在列表里最多只显示'
          '两行，其余用省略号收起，行高也不随简介长短变化。再补一句让它更长一些。';
      MediaItem episode(int index, {String? name, String? overview}) =>
          MediaItem(
            id: 'episode-$index',
            name: name ?? '第 $index 集',
            type: 'Episode',
            seasonId: 'season-1',
            indexNumber: index,
            parentIndexNumber: 1,
            overview: overview,
            runtime: Duration(microseconds: (24 * _minute) ~/ 10),
            premiereDate: DateTime(2024, 1, index),
          );
      await tester.pumpWidget(
        _phone(
          _slivers(
            _series(
              seasons: const [
                MediaItem(id: 'season-1', name: '第 1 季', type: 'Season'),
              ],
              episodes: [
                episode(1),
                episode(2, name: '一个很长的分集标题会在手机上折成两行显示出来', overview: long),
                episode(3, overview: '短简介。'),
              ],
              episodeTotal: 3,
            ),
          ),
        ),
      );
      await tester.pump();

      final heights = [
        for (var index = 1; index <= 3; index++)
          tester
              .getSize(find.byKey(CatalogKeys.episode('episode-$index')))
              .height,
      ];
      expect(heights[1], closeTo(heights[0], .5));
      expect(heights[2], closeTo(heights[0], .5));
      for (final text in tester.widgetList<Text>(
        find.byKey(const Key('phone-episode-overview')),
      )) {
        expect(text.maxLines, 2);
      }
      // 当前集（episode-2）同时有左侧主色条和播放标记，不只靠底色。
      expect(find.byKey(const Key('phone-episode-current')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('phone info table', () {
    final item = MediaItem(
      id: 'movie',
      name: '片',
      type: 'Movie',
      runtime: Duration(microseconds: (106 * _minute) ~/ 10),
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
      final width = tester.getSize(find.byType(CupertinoPageScaffold)).width;
      expect(value.right, closeTo(width - 16 - 16, 1));
    });

    testWidgets('desktop keeps the short metadata section', (tester) async {
      await tester.pumpWidget(
        CupertinoTestApp(
          locale: const Locale('zh'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: [
            AppLocalizations.delegate,
            ...GlobalCupertinoLocalizations.delegates,
          ],
          theme: AppUiTheme.dark(),
          home: CupertinoPageScaffold(
            child: EpisodeMetadataSection(item: item, source: source),
          ),
        ),
      );
      expect(find.text('元数据'), findsOneWidget);
      expect(find.text('2026-10-03'), findsOneWidget);
      expect(find.text('MKV'), findsNothing);
    });

    testWidgets(
      'EpisodeMediaStreamsSection shows version selector row on phone when multiple sources exist',
      (tester) async {
        const s1 = ItemMediaSource(
          id: 'src-4k',
          name: '4K HDR',
          streams: [
            ItemMediaStream(
              index: 0,
              type: 'Video',
              codec: 'hevc',
              height: 2160,
            ),
            ItemMediaStream(
              index: 1,
              type: 'Audio',
              codec: 'truehd',
              label: '国语杜比',
              isDefault: true,
            ),
          ],
        );
        const s2 = ItemMediaSource(
          id: 'src-1080p',
          name: '1080p SDR',
          streams: [
            ItemMediaStream(
              index: 0,
              type: 'Video',
              codec: 'h264',
              height: 1080,
            ),
            ItemMediaStream(
              index: 2,
              type: 'Audio',
              codec: 'aac',
              label: '英语立体声',
              isDefault: true,
            ),
          ],
        );
        String selectedId = s1.id;
        await tester.pumpWidget(
          PresentationScope(
            environment: PresentationEnvironment.phone,
            child: CupertinoTestApp(
              locale: const Locale('zh'),
              supportedLocales: AppLocalizations.supportedLocales,
              localizationsDelegates: const [
                AppLocalizations.delegate,
                ...GlobalCupertinoLocalizations.delegates,
              ],
              theme: AppUiTheme.dark(),
              home: StatefulBuilder(
                builder: (context, setState) {
                  final active = selectedId == s2.id ? s2 : s1;
                  return CupertinoPageScaffold(
                    child: EpisodeMediaStreamsSection(
                      source: active,
                      sources: const [s1, s2],
                      selectedSourceId: selectedId,
                      onSelectSource: (id) => setState(() => selectedId = id),
                      onAudio: (_) {},
                    ),
                  );
                },
              ),
            ),
          ),
        );
        final versionRow = find.byKey(
          EpisodeMediaStreamsSection.phoneVersionRowKey,
        );
        expect(versionRow, findsOneWidget);
        // 版本行只写当前片源；可选项收在点开后的底部单选表里。
        expect(
          find.descendant(of: versionRow, matching: find.text('4K HDR')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('phone-detail-version-src-1080p')),
          findsNothing,
        );
        expect(find.text('国语杜比'), findsOneWidget);
        expect(find.text('英语立体声'), findsNothing);

        await tester.tap(versionRow);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('phone-detail-version-src-4k')),
          findsOneWidget,
        );
        await tester.tap(
          find.byKey(const ValueKey('phone-detail-version-src-1080p')),
        );
        await tester.pumpAndSettle();
        expect(selectedId, 'src-1080p');
        expect(
          find.byKey(const ValueKey('phone-detail-version-src-1080p')),
          findsNothing,
        );
        expect(
          find.descendant(of: versionRow, matching: find.text('1080p SDR')),
          findsOneWidget,
        );
        expect(find.text('英语立体声'), findsOneWidget);
        expect(find.text('国语杜比'), findsNothing);
      },
    );
  });
}

/// 共享季切换器手机标签（`CatalogKeys.season(id)`）是否为选中态。
bool _seasonSelected(WidgetTester tester, String id) => tester
    .widget<AppButton>(
      find.descendant(
        of: find.byKey(CatalogKeys.season(id)),
        matching: find.byType(AppButton),
      ),
    )
    .selected;
