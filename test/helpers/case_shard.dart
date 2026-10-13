import 'package:flutter_test/flutter_test.dart' as flutter;

/// Partition registrations, not execution: each generated entrypoint registers
/// one disjoint subset. Direct execution of a case module registers all cases.
class CaseShard {
  CaseShard(this.parts, {this.defaultSemantics = false});

  final int parts;
  final bool defaultSemantics;
  int? _part;
  int _index = 0;

  void register(int part, void Function() main, {required int expectedParts}) {
    if (parts != expectedParts || part < 0 || part >= parts) {
      throw StateError(
        'Case shard configuration changed. Run '
        'python tool/test_execution/generate_suites.py.',
      );
    }
    _part = part;
    _index = 0;
    main();
  }

  bool get _selected => _index++ % parts == _part || _part == null;

  void testWidgets(
    String description,
    flutter.WidgetTesterCallback callback, {
    Object? tags,
    flutter.Timeout? timeout,
    bool? skip,
    bool? semanticsEnabled,
    flutter.TestVariant<Object?> variant = const flutter.DefaultTestVariant(),
  }) {
    if (!_selected) return;
    flutter.testWidgets(
      description,
      callback,
      tags: tags,
      timeout: timeout,
      skip: skip,
      semanticsEnabled: semanticsEnabled ?? defaultSemantics,
      variant: variant,
    );
  }

  void test(
    String description,
    dynamic Function() callback, {
    Object? tags,
    flutter.Timeout? timeout,
    Object? skip,
  }) {
    if (!_selected) return;
    flutter.test(
      description,
      callback,
      tags: tags,
      timeout: timeout,
      skip: skip,
    );
  }
}
