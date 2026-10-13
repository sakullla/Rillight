import '../helpers/widget_harness.dart';
import '../helpers/settle.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart' hide testWidgets;
import 'package:rillight/app/tv_widgets.dart';
import 'package:rillight/media_server/models.dart';

void main() {
  testWidgets('root dialog keeps its editor focus above a nested TV route', (
    tester,
  ) async {
    final editor = FocusNode();
    addTearDown(editor.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Navigator(
          onGenerateRoute: (_) => MaterialPageRoute<void>(
            builder: (context) => Scaffold(
              body: TvFocusRegion(
                child: Center(
                  child: TvAction(
                    autofocus: true,
                    onPressed: () {
                      // A void callback is common for opening settings dialogs.
                      showDialog<void>(
                        context: context,
                        builder: (_) => AlertDialog(
                          content: TextField(
                            focusNode: editor,
                            autofocus: true,
                          ),
                        ),
                      );
                    },
                    child: const Text('Edit'),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await settle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await settle(tester);
    expect(editor.hasPrimaryFocus, isTrue);
    expect(tester.testTextInput.isVisible, isTrue);
    tester.view.viewInsets = const FakeViewPadding(bottom: 240);
    addTearDown(tester.view.resetViewInsets);
    await settle(tester);
    expect(editor.hasPrimaryFocus, isTrue);
    // updateEditingValue does not forcibly refocus the field like enterText.
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(text: 'abc'),
    );
    await tester.pump();
    expect(find.text('abc'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final trailing in [false, true]) {
    testWidgets('row arrows stay within lazy row, trailing=$trailing', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(960, 540);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final nodes = <String, FocusNode>{};
      Widget row(String name, int count) => TvItemRow(
        title: name,
        items: List.generate(
          count,
          (i) => MediaItem(id: '$name-$i', name: '$name-$i', type: 'Movie'),
        ),
        trailing: trailing
            ? (_, metrics) =>
                  TvAction(onPressed: () {}, child: Text('$name-more'))
            : null,
        cardBuilder: (_, item, node, metrics) {
          nodes[item.id] = node;
          return TvAction(
            focusNode: node,
            onPressed: () {},
            child: Text(item.id),
          );
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(children: [row('upper', 4), row('lower', 15)]),
          ),
        ),
      );
      await settle(tester);
      nodes['lower-0']!.requestFocus();
      await settle(tester);
      for (var i = 1; i < 15; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await settle(tester);
        expect(nodes['lower-$i']!.hasPrimaryFocus, isTrue, reason: 'item $i');
      }
      if (trailing) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await settle(tester);
      }
      final end = FocusManager.instance.primaryFocus;
      for (var i = 0; i < 3; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await settle(tester);
        expect(FocusManager.instance.primaryFocus, same(end));
      }
      for (var i = trailing ? 14 : 13; i >= 0; i--) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        await settle(tester);
        expect(nodes['lower-$i']!.hasPrimaryFocus, isTrue);
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await settle(tester);
      expect(nodes['lower-0']!.hasPrimaryFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await settle(tester);
      expect(
        nodes.values.where((n) => n.hasPrimaryFocus).single.debugLabel,
        startsWith('tv-row-upper'),
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
