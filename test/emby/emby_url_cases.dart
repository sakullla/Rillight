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

  test('normalizes internationalized hostnames to DNS ASCII', () {
    for (final input in [
      'https://例子.example/',
      'https://%E4%BE%8B%E5%AD%90.example',
      'https://例子。example',
      'https://xn--fsqu00a.example',
    ]) {
      final url = normalizeEmbyBaseUrl(input);
      expect(url.toString(), 'https://xn--fsqu00a.example');
      expect(normalizeEmbyBaseUrl(url.toString()), url);
    }
    expect(
      normalizeEmbyBaseUrl('BÜCHER.example:8096').toString(),
      'http://xn--bcher-kva.example:8096',
    );
  });

  test('internationalized hosts preserve ports and escaped proxy paths', () {
    final url = normalizeEmbyBaseUrl('https://例子.example:8920/媒体/a%2Fb/');
    expect(url.host, 'xn--fsqu00a.example');
    expect(url.port, 8920);
    expect(url.path, '/%E5%AA%92%E4%BD%93/a%2Fb');
    expect(
      joinEmbyApiPath(url, '/System/Info/Public').toString(),
      'https://xn--fsqu00a.example:8920/'
      '%E5%AA%92%E4%BD%93/a%2Fb/emby/System/Info/Public',
    );
  });

  test('keeps IP literals and local hostnames usable', () {
    for (final address in [
      'http://127.0.0.1:8096',
      'http://[::1]:8096',
      'http://[fe80::1%25eth0]:8096',
      'http://localhost:8096',
      'https://a.123.example',
    ]) {
      expect(normalizeEmbyBaseUrl(address), Uri.parse(address));
    }
  });

  test('malformed escaped hosts produce a private invalid-address error', () {
    for (final address in [
      'https://%FF.example',
      'https://bad%20host.example',
      'https://例子..example',
      'https://[invalid]',
    ]) {
      expect(
        () => normalizeEmbyBaseUrl(address),
        throwsA(
          isA<EmbyException>()
              .having(
                (error) => error.kind,
                'kind',
                EmbyFailureKind.invalidAddress,
              )
              .having((error) => error.detail, 'detail', isNull),
        ),
      );
    }
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
