import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

import '../product.dart';
import 'update_service.dart';

enum UpdateDownloadFailure {
  network,
  timeout,
  disk,
  checksum,
  unsafeAsset,
  cancelled,
}

class UpdateDownloadException implements Exception {
  const UpdateDownloadException(this.failure);
  final UpdateDownloadFailure failure;
}

/// Bound to one candidate and one artifact, even when later checks find a release.
class VerifiedUpdate {
  const VerifiedUpdate({
    required this.release,
    required this.asset,
    required this.file,
    required this.sha256,
    required this.length,
  });
  final AppRelease release;
  final ReleaseAsset asset;
  final File file;
  final String sha256;
  final int length;
}

typedef UpdateByteProgress = void Function(int received, int? total);

/// Strict GNU SHA256SUMS subset emitted by the release workflow. Every nonempty
/// line must be valid; duplicate aliases of the target are deliberately rejected.
String updateChecksumFor(String manifest, String assetName) {
  String? result;
  for (final line in const LineSplitter().convert(manifest)) {
    if (line.trim().isEmpty) continue;
    final match = RegExp(r'^([0-9a-fA-F]{64}) [ *](.+)$').firstMatch(line);
    if (match == null) {
      throw const UpdateDownloadException(UpdateDownloadFailure.checksum);
    }
    var name = match.group(2)!;
    if (name.startsWith('dist/')) name = name.substring(5);
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._+-]*$').hasMatch(name) ||
        name.contains('..')) {
      throw const UpdateDownloadException(UpdateDownloadFailure.checksum);
    }
    if (name == assetName) {
      if (result != null) {
        throw const UpdateDownloadException(UpdateDownloadFailure.checksum);
      }
      result = match.group(1)!.toLowerCase();
    }
  }
  if (result == null) {
    throw const UpdateDownloadException(UpdateDownloadFailure.checksum);
  }
  return result;
}

/// Own unauthenticated transport; redirects are manually validated before any
/// connection. A new directory and .part file are used for every retry.
class UpdateDownloader {
  UpdateDownloader({Dio? dio, Future<Directory> Function()? cacheDirectory})
    : _dio = dio ?? Dio(),
      _ownsDio = dio == null,
      _cacheDirectory = cacheDirectory ?? _defaultCache;

  final Dio _dio;
  final bool _ownsDio;
  final Future<Directory> Function() _cacheDirectory;

  static Future<Directory> _defaultCache() async {
    final temporary = await getTemporaryDirectory();
    return Directory(
      '${temporary.path}${Platform.pathSeparator}rillight-updates',
    );
  }

  Future<VerifiedUpdate> download({
    required AppRelease release,
    required ReleaseAsset asset,
    required CancelToken cancelToken,
    required UpdateByteProgress onProgress,
    required void Function() onVerifying,
  }) async {
    Directory? session;
    RandomAccessFile? output;
    var complete = false;
    try {
      _checkCancelled(cancelToken);
      if (!release.ownsAsset(asset)) {
        throw const UpdateDownloadException(UpdateDownloadFailure.unsafeAsset);
      }
      final sums = release.assets
          .where((item) => item.name == 'SHA256SUMS')
          .toList();
      if (sums.length != 1 || !release.ownsAsset(sums.single)) {
        throw const UpdateDownloadException(UpdateDownloadFailure.checksum);
      }
      final cache = await _cacheDirectory();
      await cache.create(recursive: true);
      _checkCancelled(cancelToken);
      session = await cache.createTemp('session-');
      final part = File(
        '${session.path}${Platform.pathSeparator}${asset.name}.part',
      );
      output = await part.open(mode: FileMode.write);
      final response = await _open(asset.url, cancelToken);
      final contentLength = int.tryParse(
        response.headers.value(Headers.contentLengthHeader) ?? '',
      );
      final total = contentLength != null && contentLength > 0
          ? contentLength
          : (asset.size != null && asset.size! > 0 ? asset.size : null);
      var received = 0;
      final throttle = Stopwatch()..start();
      onProgress(received, total);
      await for (final bytes in response.data!.stream.timeout(
        const Duration(seconds: 30),
      )) {
        _checkCancelled(cancelToken);
        await output.writeFrom(bytes);
        received += bytes.length;
        if ((total != null && received > total) ||
            (asset.size != null && asset.size! > 0 && received > asset.size!)) {
          throw const UpdateDownloadException(UpdateDownloadFailure.checksum);
        }
        if (throttle.elapsedMilliseconds >= 100) {
          onProgress(received, total);
          throttle.reset();
        }
      }
      await output.flush();
      await output.close();
      output = null;
      _checkCancelled(cancelToken);
      if (received == 0 ||
          (total != null && received != total) ||
          (asset.size != null && asset.size! > 0 && received != asset.size)) {
        throw const UpdateDownloadException(UpdateDownloadFailure.checksum);
      }
      onProgress(received, total);
      onVerifying();
      final checksumResponse = await _open(sums.single.url, cancelToken);
      final manifestBytes = <int>[];
      await for (final bytes in checksumResponse.data!.stream.timeout(
        const Duration(seconds: 30),
      )) {
        _checkCancelled(cancelToken);
        manifestBytes.addAll(bytes);
        if (manifestBytes.length > 1024 * 1024) {
          throw const UpdateDownloadException(UpdateDownloadFailure.checksum);
        }
      }
      final expected = updateChecksumFor(
        utf8.decode(manifestBytes),
        asset.name,
      );
      final actual = await _hash(part, cancelToken: cancelToken);
      _checkCancelled(cancelToken);
      if (actual != expected) {
        throw const UpdateDownloadException(UpdateDownloadFailure.checksum);
      }
      final file = await part.rename(
        '${session.path}${Platform.pathSeparator}${asset.name}',
      );
      _checkCancelled(cancelToken);
      complete = true;
      return VerifiedUpdate(
        release: release,
        asset: asset,
        file: file,
        sha256: expected,
        length: received,
      );
    } on UpdateDownloadException {
      rethrow;
    } on DioException catch (error) {
      throw UpdateDownloadException(switch (error.type) {
        DioExceptionType.cancel => UpdateDownloadFailure.cancelled,
        DioExceptionType.connectionTimeout ||
        DioExceptionType.sendTimeout ||
        DioExceptionType.receiveTimeout => UpdateDownloadFailure.timeout,
        _ => UpdateDownloadFailure.network,
      });
    } on TimeoutException {
      throw const UpdateDownloadException(UpdateDownloadFailure.timeout);
    } on FileSystemException {
      throw const UpdateDownloadException(UpdateDownloadFailure.disk);
    } on FormatException {
      throw const UpdateDownloadException(UpdateDownloadFailure.checksum);
    } catch (_) {
      throw const UpdateDownloadException(UpdateDownloadFailure.network);
    } finally {
      try {
        await output?.close();
      } on FileSystemException {
        /* Failure still invalidates the partial file. */
      }
      if (!complete && session != null) {
        try {
          await session.delete(recursive: true);
        } on FileSystemException {
          /* A leftover partial is never adopted. */
        }
      }
    }
  }

  /// Called immediately before system handoff, including retries after permission
  /// settings. Never trust a ready flag or a previously observed file length.
  Future<bool> verify(VerifiedUpdate update) async {
    try {
      if (!update.release.ownsAsset(update.asset) ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(update.sha256) ||
          await FileSystemEntity.type(update.file.path, followLinks: false) !=
              FileSystemEntityType.file) {
        return false;
      }
      final before = await update.file.stat();
      if (before.size != update.length || update.length <= 0) return false;
      final hash = await _hash(update.file);
      final after = await update.file.stat();
      return hash == update.sha256 &&
          before.size == after.size &&
          before.modified == after.modified;
    } on FileSystemException {
      return false;
    }
  }

  Future<String> _hash(File file, {CancelToken? cancelToken}) async {
    final sink = Sha256().newHashSink();
    await for (final bytes in file.openRead()) {
      if (cancelToken != null) _checkCancelled(cancelToken);
      sink.add(bytes);
    }
    sink.close();
    final hash = await sink.hash();
    return hash.bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  Future<Response<ResponseBody>> _open(Uri initial, CancelToken token) async {
    var uri = initial;
    for (var redirect = 0; redirect <= 5; redirect++) {
      _checkCancelled(token);
      if (!_allowedTransport(uri)) {
        throw const UpdateDownloadException(UpdateDownloadFailure.unsafeAsset);
      }
      final response = await _dio
          .getUri<ResponseBody>(
            uri,
            options: Options(
              responseType: ResponseType.stream,
              followRedirects: false,
              validateStatus: (status) =>
                  status == 200 ||
                  const [301, 302, 303, 307, 308].contains(status),
              headers: {
                'User-Agent': '$kHttpClientName/$kAppVersion',
                'Accept': 'application/octet-stream',
              },
              sendTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 30),
            ),
            cancelToken: token,
          )
          .timeout(
            const Duration(seconds: 45),
            onTimeout: () {
              token.cancel();
              throw TimeoutException('Asset request timed out');
            },
          );
      _checkCancelled(token);
      if (response.statusCode == 200) return response;
      await response.data?.stream.listen(null).cancel();
      final location = response.headers.value('location');
      if (location == null) {
        throw const UpdateDownloadException(UpdateDownloadFailure.network);
      }
      final next = uri.resolve(location);
      if (next.host == 'github.com' && next != initial) {
        throw const UpdateDownloadException(UpdateDownloadFailure.unsafeAsset);
      }
      uri = next;
    }
    throw const UpdateDownloadException(UpdateDownloadFailure.network);
  }

  static bool _allowedTransport(Uri uri) =>
      uri.scheme == 'https' &&
      uri.userInfo.isEmpty &&
      uri.port == 443 &&
      uri.fragment.isEmpty &&
      const {
        'github.com',
        'release-assets.githubusercontent.com',
        'objects.githubusercontent.com',
      }.contains(uri.host);

  static void _checkCancelled(CancelToken token) {
    if (token.isCancelled) {
      throw const UpdateDownloadException(UpdateDownloadFailure.cancelled);
    }
  }

  void dispose() {
    if (_ownsDio) _dio.close(force: true);
  }
}
