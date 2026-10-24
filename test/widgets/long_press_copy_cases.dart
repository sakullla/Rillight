import '../helpers/cupertino_test_app.dart';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/ui/ui.dart';
import 'package:rillight/app/widgets/long_press_copy.dart';

void main() {
  late List<String> copied;

  setUp(() => copied = []);

  Future<void> pump(WidgetTester tester, Widget child) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(
      CupertinoTestApp(
        home: CupertinoPageScaffold(child: Center(child: child)),
      ),
    );
  }

  testWidgets('long press copies the full name and confirms briefly', (
    tester,
  ) async {
    const name = '被放逐的作弊赋予魔术师享受随心所欲的第二人生。S01E03.2160p.WEB-DL';
    await pump(
      tester,
      const SizedBox(
        width: 120,
        child: LongPressCopy(
          text: name,
          child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      ),
    );
    await tester.longPress(find.byType(LongPressCopy));
    await tester.pump();
    expect(copied, [name]);
    // The notice shows a shortened name, not the whole (possibly long) text.
    expect(find.textContaining('已复制'), findsOneWidget);
    expect(find.text('已复制：$name'), findsNothing);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('a short tap still reaches the surrounding action', (
    tester,
  ) async {
    var taps = 0;
    await pump(
      tester,
      AppSurfaceAction(
        onTap: () => taps++,
        child: const LongPressCopy(text: '老友记', child: Text('老友记')),
      ),
    );
    await tester.tap(find.text('老友记'));
    await tester.pump();
    expect(taps, 1);
    expect(copied, isEmpty);
    await tester.longPress(find.text('老友记'));
    await tester.pump();
    expect(taps, 1);
    expect(copied, ['老友记']);
    await tester.pump(const Duration(seconds: 3));
  });
}
