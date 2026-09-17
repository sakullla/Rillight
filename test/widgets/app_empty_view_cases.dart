import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/app/theme.dart';
import 'package:rillight/app/widgets/app_empty_view.dart';

void main() {
  testWidgets('AppEmptyView shows icon, message and optional action', (
    tester,
  ) async {
    var actions = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: const Scaffold(
          body: AppEmptyView(message: '这里什么都没有', actionLabel: '刷新'),
        ),
      ),
    );
    expect(find.text('这里什么都没有'), findsOneWidget);
    expect(find.byIcon(Icons.inbox_outlined), findsOneWidget);
    // 未提供 onAction 时不渲染按钮。
    expect(find.byType(OutlinedButton), findsNothing);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: AppEmptyView(
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
