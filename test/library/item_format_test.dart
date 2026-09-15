import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/library/item_format.dart';

void main() {
  test('plainOverview strips tags and entities', () {
    expect(
      plainOverview('<p>Hello<br/>world &amp; friends</p>'),
      'Hello\nworld & friends',
    );
    expect(plainOverview('  '), isNull);
    expect(plainOverview(null), isNull);
  });
}
