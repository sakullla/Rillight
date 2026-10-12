import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/auth/login_widgets.dart';
import 'package:rillight/media_server/capabilities.dart';
import 'package:rillight/media_server/models.dart';
import 'package:rillight/player/playback_title.dart';

Widget _app(Widget child) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(
    body: Center(child: SizedBox(width: 400, child: child)),
  ),
);

void main() {
  testWidgets('provider switcher reports the tapped service only', (
    tester,
  ) async {
    var value = MediaServerType.emby;
    final changes = <MediaServerType>[];
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) => _app(
          ProviderSwitcher(
            value: value,
            onChanged: (next) {
              changes.add(next);
              setState(() => value = next);
            },
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('login-provider-plex')));
    await tester.pumpAndSettle();
    // Tapping the current service again is not a change.
    await tester.tap(find.byKey(const Key('login-provider-plex')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('login-provider-jellyfin')));
    await tester.pumpAndSettle();
    expect(changes, [MediaServerType.plex, MediaServerType.jellyfin]);
    expect(find.byType(ServerTypeMark), findsNWidgets(3));
    expect(tester.takeException(), isNull);
  });

  testWidgets('disabled provider switcher ignores taps', (tester) async {
    await tester.pumpWidget(
      _app(
        const ProviderSwitcher(value: MediaServerType.emby, onChanged: null),
      ),
    );
    await tester.tap(find.byKey(const Key('login-provider-plex')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('advanced section starts collapsed unless it has content', (
    tester,
  ) async {
    Widget section({required bool expanded}) => _app(
      LoginAdvancedSection(
        key: ValueKey(expanded),
        toggleKey: const Key('advanced'),
        initiallyExpanded: expanded,
        children: const [Text('user-agent-field')],
      ),
    );
    await tester.pumpWidget(section(expanded: false));
    expect(find.text('user-agent-field'), findsNothing);
    await tester.tap(find.byKey(const Key('advanced')));
    await tester.pumpAndSettle();
    expect(find.text('user-agent-field'), findsOneWidget);

    await tester.pumpWidget(section(expanded: true));
    await tester.pumpAndSettle();
    expect(find.text('user-agent-field'), findsOneWidget);
  });

  test('playback title splits series and episode into two lines', () {
    const movie = MediaItem(id: 'm', name: 'Up', type: 'Movie');
    expect(playbackTitleParts(movie, fallback: '…'), (
      eyebrow: null,
      title: 'Up',
    ));
    const episode = MediaItem(
      id: 'e',
      name: 'Pilot',
      type: 'Episode',
      seriesName: 'Friends',
      parentIndexNumber: 1,
      indexNumber: 2,
    );
    final parts = playbackTitleParts(episode, fallback: '…');
    expect(parts.eyebrow, 'Friends');
    expect(parts.title, endsWith('Pilot'));
    expect(parts.title, isNot('Pilot'));
    expect(playbackTitleParts(null, fallback: 'loading').title, 'loading');
  });
}
