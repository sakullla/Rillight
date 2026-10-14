import '../helpers/widget_harness.dart';
import '../helpers/settle.dart';

import 'package:rillight/app/ui/ui.dart';
import 'package:flutter_test/flutter_test.dart' hide testWidgets;
import 'package:rillight/app/l10n/app_localizations.dart';
import 'package:rillight/player/network_throughput.dart';

Widget host({num speed = 0, double fontSize = 12, double width = 400}) =>
    CupertinoApp(
      locale: const Locale('zh'),
      localizationsDelegates: [
        AppLocalizations.delegate,
        ...GlobalCupertinoLocalizations.delegates,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: CupertinoPageScaffold(
        child: SizedBox(
          width: width,
          child: Builder(
            builder: (context) => AppTooltip(
              message: AppLocalizations.of(context).playerNetworkSpeedTooltip,
              child: NetworkSpeedReadout(
                bytesPerSecond: speed,
                textStyle: TextStyle(fontSize: fontSize),
              ),
            ),
          ),
        ),
      ),
    );

void main() {
  testWidgets('live upstream speed remains visible, including a zero rate', (
    tester,
  ) async {
    await tester.pumpWidget(host(speed: 2 * 1024 * 1024));
    expect(find.text('2.0 MB/s'), findsOneWidget);
    expect(find.textContaining('缓存'), findsNothing);

    await tester.pumpWidget(host());
    expect(find.text('0 KB/s'), findsOneWidget);
    expect(find.textContaining('缓存'), findsNothing);
  });

  testWidgets('speed tooltip contains no cache-range diagnostics', (
    tester,
  ) async {
    await tester.pumpWidget(host(speed: 1024));
    await tester.longPress(find.text('1 KB/s'));
    await settle(tester);

    expect(find.text('实时网速'), findsOneWidget);
    expect(find.textContaining('缓存时间范围'), findsNothing);
    expect(find.textContaining('前方缓存'), findsNothing);
  });

  testWidgets('TV-sized typography remains readable in a narrow layout', (
    tester,
  ) async {
    await tester.pumpWidget(host(fontSize: 24, width: 180));

    expect(tester.widget<Text>(find.text('0 KB/s')).style!.fontSize, 24);
    final mark = find.byWidgetPredicate(
      (widget) =>
          widget is CustomPaint && widget.painter is InboundSpeedMarkPainter,
    );
    expect(tester.getSize(mark), const Size(16, 22));
    expect(tester.takeException(), isNull);
  });
}
