import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/emby/emby_errors.dart';
import 'package:rillight/emby/emby_url.dart';

void main() {
  test('defaults missing scheme to http and strips trailing slash', () {
    expect(
      normalizeEmbyBaseUrl('192.168.1.8:8096/'),
      Uri.parse('http://192.168.1.8:8096'),
    );
  });

  test('keeps https and optional subpath', () {
    expect(
      normalizeEmbyBaseUrl(' https://emby.example.com/emby/ '),
      Uri.parse('https://emby.example.com/emby'),
    );
  });

  test('rejects empty and non-http schemes', () {
    expect(
      () => normalizeEmbyBaseUrl('  '),
      throwsA(
        isA<EmbyException>().having(
          (error) => error.kind,
          'kind',
          EmbyFailureKind.invalidAddress,
        ),
      ),
    );
    expect(
      () => normalizeEmbyBaseUrl('ftp://emby.local'),
      throwsA(
        isA<EmbyException>().having(
          (error) => error.kind,
          'kind',
          EmbyFailureKind.invalidAddress,
        ),
      ),
    );
  });

  test('joins paths without dropping a subpath prefix', () {
    expect(
      joinEmbyPath(
        Uri.parse('http://emby.local/emby'),
        '/System/Info/Public',
      ).toString(),
      'http://emby.local/emby/System/Info/Public',
    );
  });
}
