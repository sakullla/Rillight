import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/ui/ui.dart';
import 'package:rillight/library/mobile_series_page.dart';

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
            child: PhoneSeasonTab(
              label: '第一季',
              selected: true,
              onPressed: () {},
            ),
          ),
        ),
      );
      final container = tester.widget<AnimatedContainer>(
        find.byType(AnimatedContainer).first,
      );
      final decoration = container.decoration! as BoxDecoration;
      expect(decoration.color, scheme.primaryContainer);
      final border = decoration.border! as Border;
      expect(border.top.width, AppSelectionDecoration.borderWidth);
      expect(border.top.color, scheme.primary);

      final text = tester.widget<RichText>(
        find.descendant(of: find.text('第一季'), matching: find.byType(RichText)),
      );
      expect(text.text.style!.color, scheme.onPrimaryContainer);
    });
  }
}
