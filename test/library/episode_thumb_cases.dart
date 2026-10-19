import '../helpers/cupertino_test_app.dart';

import 'package:rillight/app/ui/ui.dart' as ui;

import '../helpers/widget_harness.dart';
import '../helpers/settle.dart';

import 'dart:ui' show PointerDeviceKind;

import 'package:rillight/app/ui/ui.dart';
import 'package:flutter_test/flutter_test.dart' hide testWidgets;
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/media_server/models.dart';
import 'package:rillight/library/poster_card.dart';
import 'package:rillight/media_image/media_image.dart';

void main() {
  testWidgets('episode selection and hover preserve the visible image frame', (
    tester,
  ) async {
    var selected = 'second';
    late StateSetter update;
    await tester.pumpWidget(
      CupertinoTestApp(
        locale: const Locale('zh'),
        localizationsDelegates: [
          ...[
            AppLocalizations.delegate,
            ...GlobalCupertinoLocalizations.delegates,
          ],
          ui.GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: CupertinoPageScaffold(
          child: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return Row(
                children: [
                  for (final id in ['first', 'second'])
                    EpisodeThumbCard(
                      item: MediaItem(
                        id: id,
                        name: id,
                        type: 'Episode',
                        userData: const MediaUserData(playedPercentage: 42),
                      ),
                      width: 296,
                      selected: selected == id,
                      onTap: () {},
                    ),
                ],
              );
            },
          ),
        ),
        builder: (context, child) => ui.AppUiTheme(
          data: AppUiTheme.of(context).brightness == Brightness.dark
              ? ui.AppUiTheme.dark()
              : ui.AppUiTheme.light(),
          child: child ?? const SizedBox.shrink(),
        ),
      ),
    );
    void expectEqualFrames() {
      final images = tester.widgetList<MediaImage>(find.byType(MediaImage));
      expect(images.length, 2);
      Size? size;
      for (final id in ['first', 'second']) {
        final frame = tester.getRect(
          find.byKey(ValueKey('episode-thumb-frame-$id')),
        );
        final picture = tester.getRect(find.byKey(ValueKey(id)));
        // The border lives outside the picture in both states, so switching
        // selection cannot obscure additional pixels of the current episode.
        expect(picture.left - frame.left, 3);
        expect(frame.right - picture.right, 3);
        expect(picture.top - frame.top, 3);
        expect(frame.bottom - picture.bottom, 3);
        size ??= picture.size;
        expect(picture.size, size);
      }
    }

    expectEqualFrames();
    BoxDecoration frameOf(String id) {
      return tester
              .widget<Container>(
                find.byKey(ValueKey('episode-thumb-frame-$id')),
              )
              .decoration!
          as BoxDecoration;
    }

    // Selection does not paint a primary corner. Both frames stay neutral.
    final scheme = AppUiTheme.of(
      tester.element(find.byType(EpisodeThumbCard).first),
    ).colorScheme;
    expect(frameOf('first').color, scheme.surfaceContainerHighest);
    expect(frameOf('second').color, scheme.surfaceContainerHighest);
    for (final id in ['first', 'second']) {
      final picture = tester.getRect(find.byKey(ValueKey(id)));
      final bar = tester.getRect(
        find.byKey(ValueKey('episode-thumb-progress-$id')),
      );
      expect(bar.left - picture.left, greaterThanOrEqualTo(8));
      expect(picture.right - bar.right, greaterThanOrEqualTo(8));
      expect(picture.bottom - bar.bottom, greaterThanOrEqualTo(7));
      expect(bar.height, lessThanOrEqualTo(3));
      expect(
        tester
            .widget<DecoratedBox>(
              find
                  .descendant(
                    of: find.byKey(ValueKey('episode-thumb-progress-$id')),
                    matching: find.byType(DecoratedBox),
                  )
                  .first,
            )
            .decoration,
        isA<BoxDecoration>().having(
          (decoration) => decoration.boxShadow,
          'boxShadow',
          anyOf(isNull, isEmpty),
        ),
      );
    }
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.byKey(const ValueKey('first'))));
    await settle(tester);
    expectEqualFrames();
    update(() => selected = 'first');
    await settle(tester);
    expectEqualFrames();
    await mouse.removePointer();
    await settle(tester);
    expect(tester.takeException(), isNull);
  });
}
