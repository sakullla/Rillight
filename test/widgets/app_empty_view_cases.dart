import '../helpers/cupertino_test_app.dart';
import '../helpers/widget_harness.dart';

import 'package:rillight/app/ui/ui.dart';
import 'package:flutter_test/flutter_test.dart' hide testWidgets;
import 'package:rillight/app/ui/app_icons.dart';
import 'package:rillight/app/widgets/app_empty_view.dart';

void main() {
  testWidgets('AppEmptyView shows icon, message and optional action', (
    tester,
  ) async {
    var actions = 0;
    await tester.pumpWidget(
      CupertinoTestApp(
        theme: AppUiTheme.dark(),
        home: const CupertinoPageScaffold(
          child: AppEmptyView(message: '这里什么都没有', actionLabel: '刷新'),
        ),
      ),
    );
    expect(find.text('这里什么都没有'), findsOneWidget);
    expect(find.byIcon(AppIcons.empty), findsOneWidget);
    // 未提供 onAction 时不渲染按钮。
    expect(find.byType(AppButton), findsNothing);

    await tester.pumpWidget(
      CupertinoTestApp(
        theme: AppUiTheme.dark(),
        home: CupertinoPageScaffold(
          child: AppEmptyView(
            message: '这里什么都没有',
            actionLabel: '刷新',
            onAction: () => actions++,
          ),
        ),
      ),
    );
    await tester.tap(find.text('刷新'));
    expect(actions, 1);
  });
}
