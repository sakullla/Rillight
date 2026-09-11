import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/emby/emby_device.dart';
import 'package:rillight/emby/emby_errors.dart';

import '../emby/fake_emby_server.dart';

const _device = EmbyDeviceInfo(
  clientName: '灯川 Rillight',
  deviceName: 'test',
  deviceId: 'device-catalog',
  version: '0.1.0',
);

void main() {
  late FakeEmbyServer server;
  late FakeEmbyAdapter adapter;
  late EmbyClient client;

  setUp(() async {
    server = FakeEmbyServer();
    adapter = FakeEmbyAdapter([server]);
    client = EmbyClient(device: _device, dio: dioForFakeEmby(adapter));
    final auth = await client.authenticateByName(
      baseUrl: server.baseUrl,
      username: 'alice',
      password: 'correct-horse',
      serverId: server.serverId,
    );
    client.attachSession(
      baseUrl: server.baseUrl,
      accessToken: auth.accessToken,
      userId: auth.user.id,
    );
  });

  test(
    'resume items are user-scoped movies and episodes with progress',
    () async {
      final items = await client.getResumeItems();
      expect(items, hasLength(1));
      expect(items.single.id, 'movie-inception');
      expect(items.single.playbackProgress, closeTo(0.4, 0.001));
      expect(
        server.requests.any(
          (request) => request.startsWith('GET /Users/user-alice/Items/Resume'),
        ),
        isTrue,
      );
    },
  );

  test('NextUp 404 is surfaced with status code', () async {
    server.nextUpStatus = 404;
    expect(
      () => client.getNextUp(),
      throwsA(
        isA<EmbyException>().having((error) => error.statusCode, 'status', 404),
      ),
    );
  });

  test('latest movies and grouped series use user-scoped Latest', () async {
    final movies = await client.getLatestItems(includeItemTypes: 'Movie');
    final series = await client.getLatestItems(
      includeItemTypes: 'Episode',
      groupItems: true,
    );
    expect(movies.map((item) => item.id), contains('movie-up'));
    expect(series.map((item) => item.id), contains('series-friends'));
    expect(
      server.requests.any(
        (request) =>
            request.contains('/Users/user-alice/Items/Latest') &&
            request.contains('IncludeItemTypes=Movie'),
      ),
      isTrue,
    );
  });

  test('search requires a non-empty term and does not request', () async {
    final before = List<String>.from(server.requests);
    expect(() => client.searchByName('  '), throwsArgumentError);
    expect(server.requests, before);
  });

  test('search hits movies and series by name', () async {
    final items = await client.searchByName('Inception');
    expect(items.map((item) => item.id), ['movie-inception']);
    expect(
      server.requests.any(
        (request) => request.contains('SearchTerm=Inception'),
      ),
      isTrue,
    );
  });

  test('mark played updates resume eligibility on the server', () async {
    await client.markPlayed('movie-inception');
    final resume = await client.getResumeItems();
    expect(resume, isEmpty);
    final item = await client.getItem('movie-inception');
    expect(item.userData.played, isTrue);
  });

  test('views and library items stay on user paths', () async {
    final views = await client.getViews();
    expect(
      views.map((item) => item.id),
      containsAll(['view-movies', 'view-tv']),
    );
    final movies = await client.getItems(parentId: 'view-movies');
    expect(movies.map((item) => item.type).toSet(), {'Movie'});
    expect(
      server.requests.any(
        (request) => request.startsWith('GET /Users/user-alice/Views'),
      ),
      isTrue,
    );
  });

  test(
    'cover bytes fail for a broken image without dropping the item',
    () async {
      expect(
        () => client.getPrimaryImage('movie-broken', tag: 'tag-broken'),
        throwsA(isA<EmbyException>()),
      );
      final ok = await client.getPrimaryImage('movie-up', tag: 'tag-up');
      expect(ok, isNotEmpty);
    },
  );
}
