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

  test('REST paths add the documented API prefix exactly once', () {
    for (final basePath in ['', '/', '/emby', '/emby/']) {
      for (final resource in [
        'Items/movie',
        '/Items/movie',
        '/emby/Items/movie',
      ]) {
        expect(
          joinEmbyApiPath(
            Uri.parse('http://emby.local$basePath'),
            resource,
          ).path,
          '/emby/Items/movie',
        );
      }
    }
  });

  test('REST paths preserve a reverse-proxy mount without duplicating it', () {
    for (final basePath in [
      '/media',
      '/media/',
      '/media/emby',
      '/media/emby/',
    ]) {
      for (final resource in [
        '/Videos/movie/stream.mp4',
        '/emby/Videos/movie/stream.mp4',
        '/media/emby/Videos/movie/stream.mp4',
      ]) {
        expect(
          joinEmbyApiPath(
            Uri.parse('https://emby.local$basePath'),
            resource,
          ).path,
          '/media/emby/Videos/movie/stream.mp4',
        );
      }
    }
    // Joining the user-entered mount itself is not an API operation.
    expect(
      joinEmbyPath(Uri.parse('https://emby.local'), '/media').path,
      '/media',
    );
  });
}
