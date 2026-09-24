import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/presentation_environment.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/app/tv_widgets.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/library/detail_extras.dart';
import 'package:rillight/library/provider_marks.dart';

Widget _wrap(
  Widget child, {
  PresentationEnvironment environment = PresentationEnvironment.desktop,
}) {
  // 桌面平台分支直达 launchUrl,避免测试默认 android 走进 webview。
  return MaterialApp(
    theme: AppTheme.dark().copyWith(platform: TargetPlatform.windows),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: PresentationScope(
      environment: environment,
      child: Scaffold(body: Center(child: child)),
    ),
  );
}

void main() {
  test('dead trakt id search becomes a title search', () {
    expect(
      resolveExternalLink(
        'https://app.trakt.tv/search/tmdb/489?id_type=movie',
        title: '心灵捕手',
      ),
      Uri.https('trakt.tv', '/search', {'query': '心灵捕手'}),
    );
  });

  test('imdb and tmdb urls stay as the server sent them', () {
    expect(
      resolveExternalLink('https://www.imdb.com/title/tt0119217'),
      Uri.parse('https://www.imdb.com/title/tt0119217'),
    );
    expect(
      resolveExternalLink('https://www.themoviedb.org/movie/489'),
      Uri.parse('https://www.themoviedb.org/movie/489'),
    );
  });

  test('external link marks follow the site, not a fixed set of three', () {
    expect(
      ProviderMark.match('TheTVDB', 'https://thetvdb.com/series/81189'),
      ProviderMark.tvdb,
    );
    expect(
      ProviderMark.match(
        'TheMovieDb Collection',
        'https://www.themoviedb.org/collection/10',
      ),
      ProviderMark.tmdb,
    );
    expect(
      ProviderMark.match('豆瓣', 'https://movie.douban.com/subject/1292656'),
      ProviderMark.douban,
    );
    expect(
      ProviderMark.match('MusicBrainz', 'https://musicbrainz.org/artist/abc'),
      ProviderMark.musicbrainz,
    );
    expect(
      ProviderMark.match('Bangumi', 'https://bgm.tv/subject/12'),
      ProviderMark.bangumi,
    );
    expect(ProviderMark.match('Official', 'https://example.com/title'), isNull);
  });

  testWidgets('renders the section with one button per resolvable link', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        const DetailExternalLinks(
          links: [
            ItemExternalUrl(
              name: 'IMDb',
              url: 'https://www.imdb.com/title/tt0119217',
            ),
            ItemExternalUrl(
              name: 'TMDB',
              url: 'https://www.themoviedb.org/movie/489',
            ),
          ],
        ),
      ),
    );

    expect(find.text('外部链接'), findsOneWidget);
    expect(find.text('IMDb'), findsOneWidget);
    expect(find.text('TMDB'), findsOneWidget);
  });

  testWidgets('hides the whole section without resolvable links', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(const DetailExternalLinks(links: [])));
    expect(find.text('外部链接'), findsNothing);

    await tester.pumpWidget(
      _wrap(
        const DetailExternalLinks(
          links: [ItemExternalUrl(name: 'Bad', url: 'ftp://example.com/x')],
        ),
      ),
    );
    expect(find.text('外部链接'), findsNothing);
    expect(find.text('Bad'), findsNothing);
  });

  testWidgets('keeps text, label marks and background monochrome', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        const DetailExternalLinks(
          links: [
            ItemExternalUrl(
              name: 'TMDB',
              url: 'https://www.themoviedb.org/movie/489',
            ),
            ItemExternalUrl(
              name: 'TVmaze',
              url: 'https://www.tvmaze.com/shows/1',
            ),
          ],
        ),
      ),
    );

    final context = tester.element(find.byType(DetailExternalLinks));
    final scheme = Theme.of(context).colorScheme;

    // 名称文字单色,不用品牌色。
    final name = tester.widget<Text>(find.text('TMDB'));
    expect(name.style?.color, scheme.onSurfaceVariant);
    // 文字型短标同样单色。
    final label = tester.widget<Text>(find.text('maze'));
    expect(label.style?.color, scheme.onSurfaceVariant);
    // 中性底。
    final material = tester.widget<Material>(
      find.byKey(
        const ValueKey('external-link-https://www.themoviedb.org/movie/489'),
      ),
    );
    expect(material.color, scheme.surfaceContainerHigh);
    // 整区任何文字都不铺品牌色。
    for (final mark in ProviderMark.values) {
      expect(
        find.byWidgetPredicate(
          (widget) => widget is Text && widget.style?.color == mark.color,
        ),
        findsNothing,
        reason: '${mark.name} brand color must not tint text',
      );
    }
  });

  testWidgets('shows a visible hint when the platform refuses to launch', (
    tester,
  ) async {
    const channel = MethodChannel('plugins.flutter.io/url_launcher');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async => false);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await tester.pumpWidget(
      _wrap(
        const DetailExternalLinks(
          links: [
            ItemExternalUrl(
              name: 'IMDb',
              url: 'https://www.imdb.com/title/tt0119217',
            ),
          ],
        ),
      ),
    );
    await tester.tap(
      find.byKey(
        const ValueKey('external-link-https://www.imdb.com/title/tt0119217'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.text('外部链接 · 加载失败'), findsOneWidget);
  });

  testWidgets('shows a visible hint when launching throws', (tester) async {
    const channel = MethodChannel('plugins.flutter.io/url_launcher');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => throw PlatformException(code: 'unavailable'),
    );
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await tester.pumpWidget(
      _wrap(
        const DetailExternalLinks(
          links: [
            ItemExternalUrl(
              name: 'IMDb',
              url: 'https://www.imdb.com/title/tt0119217',
            ),
          ],
        ),
      ),
    );
    await tester.tap(
      find.byKey(
        const ValueKey('external-link-https://www.imdb.com/title/tt0119217'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(tester.takeException(), isNull);
    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets('tv link buttons join the dpad focus sequence and open', (
    tester,
  ) async {
    const channel = MethodChannel('plugins.flutter.io/url_launcher');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async => false);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await tester.pumpWidget(
      _wrap(
        environment: PresentationEnvironment.tv,
        const DetailExternalLinks(
          links: [
            ItemExternalUrl(
              name: 'IMDb',
              url: 'https://www.imdb.com/title/tt0119217',
            ),
            ItemExternalUrl(
              name: 'TMDB',
              url: 'https://www.themoviedb.org/movie/489',
            ),
          ],
        ),
      ),
    );

    expect(find.byType(TvAction), findsNWidgets(2));

    Finder focusedAction() => find.byWidgetPredicate(
      (widget) =>
          widget is Semantics &&
          widget.properties.focused == true &&
          widget.properties.button == true,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(
      find.descendant(of: focusedAction(), matching: find.text('IMDb')),
      findsOneWidget,
    );

    // 确认键触发打开;平台拒绝时落入失败提示而非崩溃。
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(SnackBar), findsOneWidget);
  });
}
