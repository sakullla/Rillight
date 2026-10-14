import '../helpers/cupertino_test_app.dart';

import 'package:rillight/app/ui/ui.dart' as ui;

import '../helpers/widget_harness.dart';
import '../helpers/settle.dart';

import 'package:flutter/gestures.dart';
import 'package:rillight/app/ui/ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart' hide testWidgets;
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/media_server/models.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/home/library_tiles.dart';
import 'package:rillight/home/media_shelf.dart';

void main() {
  for (final libraries in [false, true]) {
    testWidgets(
      '${libraries ? 'library' : 'poster'} hover fits the rail clip',
      (tester) async {
        final items = [
          for (var i = 0; i < 8; i++)
            MediaItem(
              id: '$i',
              name: '卡片$i',
              type: libraries ? 'CollectionFolder' : 'Movie',
            ),
        ];
        await tester.pumpWidget(
          CupertinoTestApp(
            theme: AppUiTheme.dark(),
            localizationsDelegates: [
              ...[
                AppLocalizations.delegate,
                ...GlobalCupertinoLocalizations.delegates,
              ],
              ui.GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: AppLocalizations.supportedLocales,
            home: CupertinoPageScaffold(
              child: libraries
                  ? LibraryTiles(libraries: items)
                  : MediaShelf(
                      shelfId: 'test',
                      title: '最近添加',
                      items: items,
                      onTap: (_) {},
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
        final card = find.byKey(
          libraries ? CatalogKeys.library('0') : CatalogKeys.item('0'),
        );
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: Offset.zero);
        addTearDown(mouse.removePointer);
        await mouse.moveTo(tester.getCenter(card));
        await settle(tester);
        final box = tester.renderObject<RenderBox>(card);
        final viewport = RenderAbstractViewport.of(box) as RenderBox;
        final rect = MatrixUtils.transformRect(
          box.getTransformTo(viewport),
          Offset.zero & box.size,
        );
        expect(rect.top, greaterThanOrEqualTo(-.01));
        expect(rect.bottom, lessThanOrEqualTo(viewport.size.height + .01));
      },
    );
  }
}
