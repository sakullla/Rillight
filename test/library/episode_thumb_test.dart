import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/emby/emby_models.dart';
import 'package:rillight/library/poster_card.dart';
import 'package:rillight/media_image/media_image.dart';

void main() {
  testWidgets('episode selection and hover preserve the visible image frame', (
    tester,
  ) async {
    var selected = 'second';
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return Row(
                children: [
                  for (final id in ['first', 'second'])
                    EpisodeThumbCard(
                      item: EmbyItem(id: id, name: id, type: 'Episode'),
                      width: 296,
                      selected: selected == id,
                      onTap: () {},
                    ),
                ],
              );
            },
          ),
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
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.byKey(const ValueKey('first'))));
    await tester.pumpAndSettle();
    expectEqualFrames();
    update(() => selected = 'first');
    await tester.pumpAndSettle();
    expectEqualFrames();
    await mouse.removePointer();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
