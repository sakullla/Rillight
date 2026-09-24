import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/library/detail_extras.dart';
import 'package:rillight/library/provider_marks.dart';

void main() {
  test('dead trakt id search becomes a title search', () {
    expect(
      resolveExternalLink(
        'https://app.trakt.tv/search/tmdb/489?id_type=movie',
        title: '心灵捕手',
      ),
      Uri.https('trakt.tv', '/search', {'query': '心灵捕手'}),
    );
  });

  test('imdb and tmdb urls stay as the server sent them', () {
    expect(
      resolveExternalLink('https://www.imdb.com/title/tt0119217'),
      Uri.parse('https://www.imdb.com/title/tt0119217'),
    );
    expect(
      resolveExternalLink('https://www.themoviedb.org/movie/489'),
      Uri.parse('https://www.themoviedb.org/movie/489'),
    );
  });

  test('external link marks follow the site, not a fixed set of three', () {
    expect(
      ProviderMark.match('TheTVDB', 'https://thetvdb.com/series/81189'),
      ProviderMark.tvdb,
    );
    expect(
      ProviderMark.match(
        'TheMovieDb Collection',
        'https://www.themoviedb.org/collection/10',
      ),
      ProviderMark.tmdb,
    );
    expect(
      ProviderMark.match('豆瓣', 'https://movie.douban.com/subject/1292656'),
      ProviderMark.douban,
    );
    expect(
      ProviderMark.match('MusicBrainz', 'https://musicbrainz.org/artist/abc'),
      ProviderMark.musicbrainz,
    );
    expect(
      ProviderMark.match('Bangumi', 'https://bgm.tv/subject/12'),
      ProviderMark.bangumi,
    );
    expect(ProviderMark.match('Official', 'https://example.com/title'), isNull);
  });
}
