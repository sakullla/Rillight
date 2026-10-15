import 'authentication.dart';
import 'errors.dart';
import 'resources.dart';
export 'models.dart';

import 'package:dio/dio.dart';

import 'device.dart';
import 'models.dart';
import 'capabilities.dart';

import 'package:rillight/media_server/playback.dart';

/// A source-scoped session. Implementations own all protocol paths and codecs.
/// Guarded sessions must check the lease both before sending and after receipt.
abstract class MediaServerClient
    implements
        MediaAuthentication,
        MediaCatalog,
        MediaPlaybackResources,
        MediaArtwork {
  InteractiveAuthentication? get interactiveAuthentication;
  AccountResourceAuthentication? get accountAuthentication;

  ClientDeviceInfo get device;
  MediaServerType get serviceType;
  ServiceCapabilities get capabilities;

  Uri? get baseUrl;
  String? get accessToken;
  String? get userId;
  String get userAgent;
  String? get customUserAgent;
  bool get hasSession;
  Map<String, String> get sessionHeaders;
  void Function()? get onSessionExpired;
  set onSessionExpired(void Function()? value);
  Future<bool> Function()? get onRefreshSession;
  set onRefreshSession(Future<bool> Function()? value);
  MediaServerClient createDetached();

  static const itemFields = 'detail';
  static const gridFields = 'grid';
  static const homePosterFields = 'poster';
  static const detailWithPeople = 'detailWithPeople';
  static const imageTypes = 'posterAndBackdrop';
  static const detailImageTypes = 'withChapters';
  static const featuredImageTypes = 'withLogo';

  MediaServerClient withRequestGuard(void Function() guard);
  void setUserAgent(String? userAgent);
  void attachSession({
    required Uri baseUrl,
    required String accessToken,
    required String userId,
    String? userAgent,
  });
  void clearSession();
}

extension MediaServerPlaybackStop on MediaServerClient {
  /// Some server endpoints impose their own whole-list order.
  bool supportsShelfSorting(String source) =>
      !capabilities.serverOrderedShelves.contains(source);

  /// Inspect metadata without retaining a provider's preflight resources.
  Future<PlaybackInfo> inspectPlaybackInfo({
    required String itemId,
    String? mediaSourceId,
    int? maxStreamingBitrate,
    Duration? startPosition,
    int? subtitleStreamIndex,
  }) async {
    final info = await getPlaybackInfo(
      itemId: itemId,
      mediaSourceId: mediaSourceId,
      maxStreamingBitrate: maxStreamingBitrate,
      startPosition: startPosition,
      subtitleStreamIndex: subtitleStreamIndex,
    );
    try {
      await info.resources?.release();
    } catch (_) {
      throw PlaybackPreparationException(
        info.resources!,
        MediaServerFailureKind.unknown,
      );
    }
    return info;
  }

  Future<void> stopPlayback(PlaybackReport report) async {
    try {
      await reportStopped(report);
    } finally {
      await releasePlayback(report);
    }
  }
}

/// 可选能力：用户收藏。Emby 与 Jellyfin 支持；不实现它的服务不显示收藏操作。
abstract interface class MediaFavorites {
  Future<void> setFavorite(String itemId, {required bool favorite});
}

abstract interface class CatalogNotifications {
  void start();
  Future<void> stop();
}

abstract interface class MediaAuthentication {
  Future<PublicServerInfo> getPublicInfo(Uri baseUrl);
  Future<AuthenticationResult> authenticateByName({
    required Uri baseUrl,
    required String username,
    required String password,
    required String serverId,
  });
  Future<void> logout();
  Future<MediaUser> getUser({CancelToken? cancelToken});
  Future<void> changePassword({
    String? currentPassword,
    required String newPassword,
  });
}

abstract interface class MediaCatalog {
  CatalogNotifications? watchCatalog({
    required Future<void> Function() onUserDataChanged,
    required Future<void> Function() onLibraryChanged,
  });
  Future<List<MediaItem>> getResumeItems({
    int limit = 24,
    int? startIndex,
    String? sortBy,
    String? sortOrder,
  });
  Future<MediaItemPage> queryResumeItems({
    int limit = 24,
    int? startIndex,
    String? sortBy,
    String? sortOrder,
    String fields = MediaServerClient.gridFields,
  });
  Future<List<MediaItem>> getNextUp({
    int limit = 24,
    int? startIndex,
    String? sortBy,
    String? sortOrder,
  });
  Future<MediaItemPage> queryNextUp({
    String? parentId,
    int limit = 24,
    int? startIndex,
    String? sortBy,
    String? sortOrder,
    String fields = MediaServerClient.gridFields,
  });
  Future<List<MediaItem>> getLatestItems({
    required String includeItemTypes,
    bool groupItems = true,
    int limit = 24,
  });
  Future<List<MediaItem>> getViews();
  Future<List<MediaItem>> getItems({
    String? parentId,
    String? searchTerm,
    String? includeItemTypes,
    bool recursive = false,
    int? limit,
    int? startIndex,
    String? sortBy,
    String? sortOrder,
    List<String>? filters,
    List<String>? genres,
    List<int>? years,
    List<String>? personIds,
    String fields = MediaServerClient.itemFields,
  });
  Future<MediaItemPage> queryItems({
    String? parentId,
    String? searchTerm,
    String? includeItemTypes,
    bool recursive = false,
    int? limit,
    int? startIndex,
    String? sortBy,
    String? sortOrder,
    List<String>? filters,
    List<String>? genres,
    List<int>? years,
    List<String>? personIds,
    String fields = MediaServerClient.gridFields,
    String imageTypes = MediaServerClient.imageTypes,
  });
  Future<List<MediaItem>> searchByName(String searchTerm, {int? startIndex});
  Future<List<String>> getLibraryGenres(String? parentId);
  Future<List<MediaItem>> getSimilar(
    String itemId, {
    int? limit,
    String? sortBy,
    String? sortOrder,
  });
  Future<MediaItemPage> querySimilar(
    String itemId, {
    int? limit,
    String? sortBy,
    String? sortOrder,
    String fields = MediaServerClient.gridFields,
  });
  Future<MediaItem> getItem(
    String itemId, {
    String? fields,
    CancelToken? cancelToken,
  });
  Future<void> markPlayed(String itemId);
  Future<void> markUnplayed(String itemId);
  Future<void> hideFromResume(String itemId);
  Future<LibraryCounts> getItemCounts();
  Future<MediaItem?> getPreviousEpisode(MediaItem episode);
  Future<MediaItem?> getNextEpisode(MediaItem episode);
}

abstract interface class MediaPlaybackResources {
  Future<void> releasePlayback(PlaybackReport report);
  ResolvedPlayback? resolvePlayback({
    required PlaybackInfo info,
    required String itemId,
    String? mediaSourceId,
    bool forceTranscode = false,
  });
  Uri resolveResource(String resource);
  Future<PlaybackInfo> getPlaybackInfo({
    required String itemId,
    int? maxStreamingBitrate,
    Duration? startPosition,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
    String? mediaSourceId,
    PlaybackCapabilities? capabilities,
    bool forceTranscode = false,
  });
  Future<void> reportPlaying(PlaybackReport report);
  Future<void> reportProgress(PlaybackReport report);
  Future<void> reportStopped(PlaybackReport report);
  Uri subtitleStreamUrl({
    required String itemId,
    required String mediaSourceId,
    required int index,
    String format = 'srt',
  });
  Future<List<int>> readAuthorizedBytes(
    Uri uri, {
    Duration receiveTimeout = const Duration(seconds: 60),
    int attempts = 3,
    int? maxBytes,
  });
}

abstract interface class MediaArtwork {
  Future<MediaPreview?> openPreview(String itemId);
  Future<List<int>> getPrimaryImage(
    String itemId, {
    String? tag,
    int maxWidth = 280,
    CancelToken? cancelToken,
  });
  Future<List<int>> getChapterImage(
    String itemId, {
    required int index,
    String? tag,
    int maxWidth = 400,
    CancelToken? cancelToken,
  });
  Future<List<int>> getItemImage(
    String itemId, {
    String type = 'Primary',
    String? tag,
    int? index,
    int maxWidth = 280,
    CancelToken? cancelToken,
  });
  Future<List<int>> getOriginalItemImage(
    String itemId, {
    String type = 'Backdrop',
    String? tag,
    int? index,
    CancelToken? cancelToken,
  });
}
