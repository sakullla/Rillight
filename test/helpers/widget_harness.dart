import 'package:flutter_test/flutter_test.dart' as flutter;

/// Layout/action tests do not need to construct the accessibility tree on
/// every frame. Accessibility regressions opt in or call ensureSemantics.
void testWidgets(
  String description,
  flutter.WidgetTesterCallback callback, {
  bool? skip,
  flutter.Timeout? timeout,
  bool semanticsEnabled = false,
  flutter.TestVariant<Object?> variant = const flutter.DefaultTestVariant(),
  Object? tags,
  int? retry,
}) => flutter.testWidgets(
  description,
  callback,
  skip: skip,
  timeout: timeout,
  semanticsEnabled: semanticsEnabled,
  variant: variant,
  tags: tags,
  retry: retry,
);
