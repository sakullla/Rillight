import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/home/hero_playback_actions.dart';
import 'package:rillight/player/player_window_host.dart';

void main() {
  testWidgets('resume and details share a row and resume opens the real host', (
    tester,
  ) async {
    final host = OverlayPlayerWindowHost();
    addTearDown(host.dispose);
    var details = false;
    final item = EmbyItem.fromJson({
      'Id': 'episode',
      'Name': 'Episode',
      'Type': 'Episode',
      'UserData': {'PlaybackPositionTicks': 120000000, 'PlayedPercentage': 20},
    });
    expect(item.canResume, isTrue);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: PlayerWindowScope(
          host: host,
          child: Scaffold(
            body: Center(
              child: HeroPlaybackActions(
                item: item,
                onDetails: () => details = true,
              ),
            ),
          ),
        ),
      ),
    );
    final resume = find.byKey(const ValueKey('hero-resume-episode'));
    final info = find.widgetWithText(OutlinedButton, '详情');
    expect(tester.getTopLeft(resume).dy, tester.getTopLeft(info).dy);
    await tester.tap(resume);
    await tester.pump();
    expect(host.current?.itemId, 'episode');
    expect(host.current?.autoResume, isTrue);
    expect(details, isFalse);
    await tester.tap(info);
    expect(details, isTrue);
    expect(tester.takeException(), isNull);
  });
}
