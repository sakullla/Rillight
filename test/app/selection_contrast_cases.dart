import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/ui/ui.dart';
import 'package:rillight/home/catalog_keys.dart';
import 'package:rillight/library/season_switcher.dart';
import 'package:rillight/media_server/models.dart';

import '../helpers/cupertino_test_app.dart';

double _contrast(Color a, Color b) {
  final values = [a.computeLuminance(), b.computeLuminance()]..sort();
  return (values.last + .05) / (values.first + .05);
}

void main() {
  for (final (name, tones) in [
    ('dark', AppPalette.darkTones),
    ('light', AppPalette.lightTones),
  ]) {
    test('$name selection border keeps a visible boundary', () {
      expect(
        _contrast(tones.accent, tones.accentContainer),
        greaterThanOrEqualTo(3),
        reason: 'accent border on accentContainer',
      );
      expect(
        _contrast(tones.accent, tones.surface),
        greaterThanOrEqualTo(3),
        reason: 'accent border on surface',
      );
    });
  }

  for (final theme in [AppUiTheme.dark(), AppUiTheme.light()]) {
    testWidgets('selected season tab paints the selection decoration in '
        '${theme.brightness}', (tester) async {
      final scheme = theme.colorScheme;
      await tester.pumpWidget(
        CupertinoTestApp(
          theme: theme,
          home: Center(
            child: SeasonSwitcher(
              platform: SeasonSwitcherPlatform.phone,
              seasons: const [
                MediaItem(id: 's1', name: '第一季', type: 'Season'),
                MediaItem(id: 's2', name: '第二季', type: 'Season'),
              ],
              currentId: 's1',
              onSelected: (_) {},
            ),
          ),
        ),
      );
      final face = tester.widget<AnimatedContainer>(
        find.descendant(
          of: find.byKey(CatalogKeys.seasonTab('s1')),
          matching: find.byKey(AppButton.faceKey),
        ),
      );
      final decoration = face.decoration! as ShapeDecoration;
      expect(decoration.color, scheme.primaryContainer);
      final side = (decoration.shape as OutlinedBorder).side;
      expect(side.width, AppSelectionDecoration.borderWidth);
      expect(side.color, scheme.primary);

      final text = tester.widget<RichText>(
        find.descendant(of: find.text('第一季'), matching: find.byType(RichText)),
      );
      expect(text.text.style!.color, scheme.onPrimaryContainer);
    });
  }
}
