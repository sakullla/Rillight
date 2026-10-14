import 'package:rillight/app/ui/ui.dart' as ui;

import '../helpers/widget_harness.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart' hide testWidgets;
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/app/presentation_environment.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/app/tv_widgets.dart';
import 'package:rillight/media_server/models.dart';
import 'package:rillight/library/detail_extras.dart';
import 'package:rillight/library/provider_marks.dart';

Widget _wrap(
  Widget child, {
  PresentationEnvironment environment = PresentationEnvironment.desktop,
}) {
  // 桌面平台分支直达 launchUrl,避免测试默认 android 走进 webview。
  return MaterialApp(
    theme: AppTheme.dark().copyWith(platform: TargetPlatform.windows),
    localizationsDelegates: [
      ...AppLocalizations.localizationsDelegates,
      ui.GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    home: PresentationScope(
      environment: environment,
      child: Scaffold(body: Center(child: child)),
    ),
    builder: (context, child) => ui.AppUiTheme(
      data: Theme.of(context).brightness == Brightness.dark
          ? ui.AppUiTheme.dark()
          : ui.AppUiTheme.light(),
      child: child ?? const SizedBox.shrink(),
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
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

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
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

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
    final scheme = ui.AppUiTheme.of(context).colorScheme;

    final name = tester.widget<Text>(find.text('TMDB'));
    expect(name.style?.color, scheme.onSurfaceVariant);

    final label = tester.widget<Text>(find.text('maze'));
    expect(label.style?.color, scheme.onSurfaceVariant);

    final material = tester.widget<Container>(
      find.byKey(
        const ValueKey('external-link-https://www.themoviedb.org/movie/489'),
      ),
    );
    expect(
      (material.decoration! as BoxDecoration).color,
      scheme.surfaceContainerHigh,
    );

    for (final mark in ProviderMark.values) {
      expect(
        find.byWidgetPredicate(
          (widget) => widget is Text && widget.style?.color == mark.color,
        ),
        findsNothing,
        reason: '${mark.name} brand color must not tint text',
      );
    }
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

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

    expect(find.byKey(const Key('app-notice')), findsOneWidget);
    expect(find.text('外部链接 · 加载失败'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

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
    expect(find.byKey(const Key('app-notice')), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

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

    await tester.sendKeyEvent(LogicalKeyboardKey.select, platform: 'android');
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byKey(const Key('app-notice')), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}
