import 'models.dart';
import 'playback.dart';

// Local cache and child-process schema. Never use these maps as server payloads.

Map<String, dynamic> encodePublicServerInfo(PublicServerInfo value) => {
  'id': value.id,
  'serverName': value.serverName,
  'version': value.version,
};
PublicServerInfo decodePublicServerInfo(Map<String, dynamic> json) =>
    PublicServerInfo(
      id: json['id'] as String? ?? '',
      serverName: json['serverName'] as String? ?? '',
      version: json['version'] as String?,
    );

Map<String, dynamic> encodeMediaUser(MediaUser value) => {
  'id': value.id,
  'name': value.name,
  'enableNextEpisodeAutoPlay': value.enableNextEpisodeAutoPlay,
  'resumeRewindSeconds': value.resumeRewindSeconds,
};
MediaUser decodeMediaUser(Map<String, dynamic> json) => MediaUser(
  id: json['id'] as String? ?? '',
  name: json['name'] as String? ?? '',
  enableNextEpisodeAutoPlay:
      json['enableNextEpisodeAutoPlay'] as bool? ?? false,
  resumeRewindSeconds: json['resumeRewindSeconds'] as int? ?? 0,
);

Map<String, dynamic> encodeAuthenticationResult(AuthenticationResult value) => {
  'accessToken': value.accessToken,
  'serverId': value.serverId,
  'user': encodeMediaUser(value.user),
};
AuthenticationResult decodeAuthenticationResult(Map<String, dynamic> json) =>
    AuthenticationResult(
      accessToken: json['accessToken'] as String? ?? '',
      serverId: json['serverId'] as String? ?? '',
      user: decodeMediaUser(
        Map<String, dynamic>.from(json['user'] as Map? ?? const {}),
      ),
    );

Map<String, dynamic> encodeMediaUserData(MediaUserData value) => {
  'played': value.played,
  'playbackPositionUs': value.playbackPosition.inMicroseconds,
  'playedPercentage': value.playedPercentage,
  'lastPlayedDate': value.lastPlayedDate?.toIso8601String(),
};
MediaUserData decodeMediaUserData(Map<String, dynamic> json) => MediaUserData(
  played: json['played'] as bool? ?? false,
  playbackPosition: Duration(
    microseconds: json['playbackPositionUs'] as int? ?? 0,
  ),
  playedPercentage: json['playedPercentage'] as double?,
  lastPlayedDate: DateTime.tryParse(json['lastPlayedDate'] as String? ?? ''),
);

Map<String, dynamic> encodeItemChapter(ItemChapter value) => {
  'name': value.name,
  'startPositionUs': value.startPosition.inMicroseconds,
  'imageTag': value.imageTag,
  'imageIndex': value.imageIndex,
  'markerType': value.markerType,
};
ItemChapter decodeItemChapter(Map<String, dynamic> json) => ItemChapter(
  name: json['name'] as String? ?? '',
  startPosition: Duration(microseconds: json['startPositionUs'] as int? ?? 0),
  imageTag: json['imageTag'] as String?,
  imageIndex: json['imageIndex'] as int?,
  markerType: json['markerType'] as String?,
);

Map<String, dynamic> encodeItemMediaStream(ItemMediaStream value) => {
  'index': value.index,
  'type': value.type,
  'label': value.label,
  'codec': value.codec,
  'channels': value.channels,
  'width': value.width,
  'height': value.height,
  'bitRate': value.bitRate,
  'videoRange': value.videoRange,
  'videoRangeType': value.videoRangeType,
  'language': value.language,
  'isDefault': value.isDefault,
  'isForced': value.isForced,
  'isExternal': value.isExternal,
  'profile': value.profile,
  'averageFrameRate': value.averageFrameRate,
  'sampleRate': value.sampleRate,
  'channelLayout': value.channelLayout,
};
ItemMediaStream decodeItemMediaStream(Map<String, dynamic> json) =>
    ItemMediaStream(
      index: json['index'] as int? ?? 0,
      type: json['type'] as String? ?? '',
      label: json['label'] as String?,
      codec: json['codec'] as String?,
      channels: json['channels'] as int?,
      width: json['width'] as int?,
      height: json['height'] as int?,
      bitRate: json['bitRate'] as int?,
      videoRange: json['videoRange'] as String?,
      videoRangeType: json['videoRangeType'] as String?,
      language: json['language'] as String?,
      isDefault: json['isDefault'] as bool?,
      isForced: json['isForced'] as bool?,
      isExternal: json['isExternal'] as bool?,
      profile: json['profile'] as String?,
      averageFrameRate: json['averageFrameRate'] as double?,
      sampleRate: json['sampleRate'] as int?,
      channelLayout: json['channelLayout'] as String?,
    );

Map<String, dynamic> encodeItemMediaSource(ItemMediaSource value) => {
  'id': value.id,
  'name': value.name,
  'container': value.container,
  'size': value.size,
  'bitrate': value.bitrate,
  'width': value.width,
  'height': value.height,
  'streams': value.streams.map(encodeItemMediaStream).toList(),
  'runtimeUs': value.runtime?.inMicroseconds,
};
ItemMediaSource decodeItemMediaSource(Map<String, dynamic> json) =>
    ItemMediaSource(
      id: json['id'] as String? ?? '',
      name: json['name'] as String?,
      container: json['container'] as String?,
      size: json['size'] as int?,
      bitrate: json['bitrate'] as int?,
      width: json['width'] as int?,
      height: json['height'] as int?,
      streams: [
        for (final value in json['streams'] as List? ?? const [])
          decodeItemMediaStream(Map<String, dynamic>.from(value as Map)),
      ],
      runtime: json['runtimeUs'] == null
          ? null
          : Duration(microseconds: json['runtimeUs'] as int),
    );

Map<String, dynamic> encodeItemPerson(ItemPerson value) => {
  'name': value.name,
  'id': value.id,
  'type': value.type,
  'role': value.role,
  'primaryImageTag': value.primaryImageTag,
};
ItemPerson decodeItemPerson(Map<String, dynamic> json) => ItemPerson(
  name: json['name'] as String? ?? '',
  id: json['id'] as String?,
  type: json['type'] as String?,
  role: json['role'] as String?,
  primaryImageTag: json['primaryImageTag'] as String?,
);

Map<String, dynamic> encodeMediaItem(MediaItem value) => {
  'id': value.id,
  'name': value.name,
  'type': value.type,
  'collectionType': value.collectionType,
  'overview': value.overview,
  'productionYear': value.productionYear,
  'premiereDate': value.premiereDate?.toIso8601String(),
  'dateCreated': value.dateCreated?.toIso8601String(),
  'runtimeUs': value.runtime?.inMicroseconds,
  'childCount': value.childCount,
  'seriesName': value.seriesName,
  'seriesId': value.seriesId,
  'seasonId': value.seasonId,
  'parentId': value.parentId,
  'indexNumber': value.indexNumber,
  'indexNumberEnd': value.indexNumberEnd,
  'parentIndexNumber': value.parentIndexNumber,
  'primaryImageTag': value.primaryImageTag,
  'thumbImageTag': value.thumbImageTag,
  'logoImageTag': value.logoImageTag,
  'backdropImageTag': value.backdropImageTag,
  'backdropImageTags': value.backdropImageTags,
  'parentBackdropImageTags': value.parentBackdropImageTags,
  'seriesPrimaryImageTag': value.seriesPrimaryImageTag,
  'parentThumbItemId': value.parentThumbItemId,
  'parentThumbImageTag': value.parentThumbImageTag,
  'parentBackdropItemId': value.parentBackdropItemId,
  'parentBackdropImageTag': value.parentBackdropImageTag,
  'communityRating': value.communityRating,
  'genres': value.genres,
  'externalUrls': value.externalUrls.map(encodeItemExternalUrl).toList(),
  'providerIds': value.providerIds,
  'mediaSources': value.mediaSources.map(encodeItemMediaSource).toList(),
  'chapters': value.chapters.map(encodeItemChapter).toList(),
  'people': value.people.map(encodeItemPerson).toList(),
  'userData': encodeMediaUserData(value.userData),
};
MediaItem decodeMediaItem(Map<String, dynamic> json) => MediaItem(
  id: json['id'] as String? ?? '',
  name: json['name'] as String? ?? '',
  type: json['type'] as String? ?? '',
  collectionType: json['collectionType'] as String?,
  overview: json['overview'] as String?,
  productionYear: json['productionYear'] as int?,
  premiereDate: DateTime.tryParse(json['premiereDate'] as String? ?? ''),
  dateCreated: DateTime.tryParse(json['dateCreated'] as String? ?? ''),
  runtime: json['runtimeUs'] == null
      ? null
      : Duration(microseconds: json['runtimeUs'] as int),
  childCount: json['childCount'] as int?,
  seriesName: json['seriesName'] as String?,
  seriesId: json['seriesId'] as String?,
  seasonId: json['seasonId'] as String?,
  parentId: json['parentId'] as String?,
  indexNumber: json['indexNumber'] as int?,
  indexNumberEnd: json['indexNumberEnd'] as int?,
  parentIndexNumber: json['parentIndexNumber'] as int?,
  primaryImageTag: json['primaryImageTag'] as String?,
  thumbImageTag: json['thumbImageTag'] as String?,
  logoImageTag: json['logoImageTag'] as String?,
  backdropImageTag: json['backdropImageTag'] as String?,
  backdropImageTags: [
    for (final value in json['backdropImageTags'] as List? ?? const [])
      value as String,
  ],
  parentBackdropImageTags: [
    for (final value in json['parentBackdropImageTags'] as List? ?? const [])
      value as String,
  ],
  seriesPrimaryImageTag: json['seriesPrimaryImageTag'] as String?,
  parentThumbItemId: json['parentThumbItemId'] as String?,
  parentThumbImageTag: json['parentThumbImageTag'] as String?,
  parentBackdropItemId: json['parentBackdropItemId'] as String?,
  parentBackdropImageTag: json['parentBackdropImageTag'] as String?,
  communityRating: json['communityRating'] as double?,
  genres: [
    for (final value in json['genres'] as List? ?? const []) value as String,
  ],
  externalUrls: [
    for (final value in json['externalUrls'] as List? ?? const [])
      decodeItemExternalUrl(Map<String, dynamic>.from(value as Map)),
  ],
  providerIds: Map<String, String>.from(
    json['providerIds'] as Map? ?? const {},
  ),
  mediaSources: [
    for (final value in json['mediaSources'] as List? ?? const [])
      decodeItemMediaSource(Map<String, dynamic>.from(value as Map)),
  ],
  chapters: [
    for (final value in json['chapters'] as List? ?? const [])
      decodeItemChapter(Map<String, dynamic>.from(value as Map)),
  ],
  people: [
    for (final value in json['people'] as List? ?? const [])
      decodeItemPerson(Map<String, dynamic>.from(value as Map)),
  ],
  userData: decodeMediaUserData(
    Map<String, dynamic>.from(json['userData'] as Map? ?? const {}),
  ),
);

Map<String, dynamic> encodeItemExternalUrl(ItemExternalUrl value) => {
  'name': value.name,
  'url': value.url,
};
ItemExternalUrl decodeItemExternalUrl(Map<String, dynamic> json) =>
    ItemExternalUrl(
      name: json['name'] as String? ?? '',
      url: json['url'] as String? ?? '',
    );

Map<String, dynamic> encodeItemImageRef(ItemImageRef value) => {
  'itemId': value.itemId,
  'type': value.type,
  'tag': value.tag,
};
ItemImageRef decodeItemImageRef(Map<String, dynamic> json) => ItemImageRef(
  itemId: json['itemId'] as String? ?? '',
  type: json['type'] as String? ?? '',
  tag: json['tag'] as String?,
);

Map<String, dynamic> encodeLibraryCountEntry(LibraryCountEntry value) => {
  'type': value.type,
  'count': value.count,
};
LibraryCountEntry decodeLibraryCountEntry(Map<String, dynamic> json) =>
    LibraryCountEntry(
      type: json['type'] as String? ?? '',
      count: json['count'] as int? ?? 0,
    );

Map<String, dynamic> encodeLibraryCounts(LibraryCounts value) => {
  'movie': value.movie,
  'series': value.series,
  'episode': value.episode,
  'others': value.others.map(encodeLibraryCountEntry).toList(),
};
LibraryCounts decodeLibraryCounts(Map<String, dynamic> json) => LibraryCounts(
  movie: json['movie'] as int?,
  series: json['series'] as int?,
  episode: json['episode'] as int?,
  others: [
    for (final value in json['others'] as List? ?? const [])
      decodeLibraryCountEntry(Map<String, dynamic>.from(value as Map)),
  ],
);

/// Negotiated playback metadata for the child-process startup mailbox. These
/// mirrors must stay field-complete: a dropped field silently downgrades the
/// child's stream negotiation to the legacy path.
Map<String, dynamic> encodeMediaStreamInfo(MediaStreamInfo value) => {
  'index': value.index,
  'type': value.type,
  'codec': value.codec,
  'language': value.language,
  'displayTitle': value.displayTitle,
  'isDefault': value.isDefault,
  'isExternal': value.isExternal,
  'isTextSubtitleStream': value.isTextSubtitleStream,
  'deliveryMethod': value.deliveryMethod,
  'deliveryUrl': value.deliveryUrl,
  'playbackIndex': value.playbackIndex,
  'channels': value.channels,
  'width': value.width,
  'height': value.height,
  'bitRate': value.bitRate,
  'videoRange': value.videoRange,
  'videoRangeType': value.videoRangeType,
};
MediaStreamInfo decodeMediaStreamInfo(Map<String, dynamic> json) =>
    MediaStreamInfo(
      index: json['index'] as int? ?? 0,
      type: json['type'] as String? ?? '',
      codec: json['codec'] as String?,
      language: json['language'] as String?,
      displayTitle: json['displayTitle'] as String?,
      isDefault: json['isDefault'] as bool? ?? false,
      isExternal: json['isExternal'] as bool? ?? false,
      isTextSubtitleStream: json['isTextSubtitleStream'] as bool?,
      deliveryMethod: json['deliveryMethod'] as String?,
      deliveryUrl: json['deliveryUrl'] as String?,
      playbackIndex: json['playbackIndex'] as int?,
      channels: json['channels'] as int?,
      width: json['width'] as int?,
      height: json['height'] as int?,
      bitRate: json['bitRate'] as int?,
      videoRange: json['videoRange'] as String?,
      videoRangeType: json['videoRangeType'] as String?,
    );

Map<String, dynamic> encodePlaybackMediaSource(PlaybackMediaSource value) => {
  'id': value.id,
  'name': value.name,
  'container': value.container,
  'protocol': value.protocol,
  'path': value.path,
  'supportsDirectPlay': value.supportsDirectPlay,
  'supportsDirectStream': value.supportsDirectStream,
  'supportsTranscoding': value.supportsTranscoding,
  'isRemote': value.isRemote,
  'isInfiniteStream': value.isInfiniteStream,
  'directStreamUrl': value.directStreamUrl,
  'transcodingUrl': value.transcodingUrl,
  'transcodingOutputBitrate': value.transcodingOutputBitrate,
  'runtimeUs': value.runtime?.inMicroseconds,
  'defaultAudioStreamIndex': value.defaultAudioStreamIndex,
  'defaultSubtitleStreamIndex': value.defaultSubtitleStreamIndex,
  'size': value.size,
  'bitrate': value.bitrate,
  'width': value.width,
  'height': value.height,
  'mediaStreams': value.mediaStreams.map(encodeMediaStreamInfo).toList(),
};
PlaybackMediaSource decodePlaybackMediaSource(Map<String, dynamic> json) =>
    PlaybackMediaSource(
      id: json['id'] as String? ?? '',
      name: json['name'] as String?,
      container: json['container'] as String?,
      protocol: json['protocol'] as String?,
      path: json['path'] as String?,
      supportsDirectPlay: json['supportsDirectPlay'] as bool? ?? false,
      supportsDirectStream: json['supportsDirectStream'] as bool? ?? false,
      supportsTranscoding: json['supportsTranscoding'] as bool? ?? false,
      isRemote: json['isRemote'] as bool? ?? false,
      isInfiniteStream: json['isInfiniteStream'] as bool? ?? false,
      directStreamUrl: json['directStreamUrl'] as String?,
      transcodingUrl: json['transcodingUrl'] as String?,
      transcodingOutputBitrate: json['transcodingOutputBitrate'] as int?,
      runtime: json['runtimeUs'] == null
          ? null
          : Duration(microseconds: json['runtimeUs'] as int),
      defaultAudioStreamIndex: json['defaultAudioStreamIndex'] as int?,
      defaultSubtitleStreamIndex: json['defaultSubtitleStreamIndex'] as int?,
      size: json['size'] as int?,
      bitrate: json['bitrate'] as int?,
      width: json['width'] as int?,
      height: json['height'] as int?,
      mediaStreams: [
        for (final value in json['mediaStreams'] as List? ?? const [])
          decodeMediaStreamInfo(Map<String, dynamic>.from(value as Map)),
      ],
    );
