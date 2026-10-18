import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'webdav_config.dart';

const kWebDavBackupFileName = 'rillight-backup.json';
const kWebDavTimeout = Duration(seconds: 15);

enum WebDavFailureKind { credentialError, unreachable, httpError }

sealed class WebDavConnectionResult {
  const WebDavConnectionResult();
}

class WebDavConnectionSuccess extends WebDavConnectionResult {
  const WebDavConnectionSuccess();
}

class WebDavConnectionCredentialError extends WebDavConnectionResult {
  const WebDavConnectionCredentialError(this.statusCode);
  final int statusCode;
}

class WebDavConnectionDirectoryMissing extends WebDavConnectionResult {
  const WebDavConnectionDirectoryMissing(this.statusCode);
  final int statusCode;
}

class WebDavConnectionHttpError extends WebDavConnectionResult {
  const WebDavConnectionHttpError(this.statusCode);
  final int statusCode;
}

class WebDavConnectionUnreachable extends WebDavConnectionResult {
  const WebDavConnectionUnreachable(this.cause);
  final Object? cause;
}

sealed class WebDavUploadResult {
  const WebDavUploadResult();
}

class WebDavUploadSuccess extends WebDavUploadResult {
  const WebDavUploadSuccess();
}

class WebDavUploadFailure extends WebDavUploadResult {
  const WebDavUploadFailure(this.kind, {this.statusCode, this.cause});
  final WebDavFailureKind kind;
  final int? statusCode;
  final Object? cause;
}

sealed class WebDavDownloadResult {
  const WebDavDownloadResult();
}

class WebDavDownloadSuccess extends WebDavDownloadResult {
  const WebDavDownloadSuccess(this.bytes);
  final Uint8List bytes;
}

class WebDavDownloadNoBackup extends WebDavDownloadResult {
  const WebDavDownloadNoBackup();
}

class WebDavDownloadFailure extends WebDavDownloadResult {
  const WebDavDownloadFailure(this.kind, {this.statusCode, this.cause});
  final WebDavFailureKind kind;
  final int? statusCode;
  final Object? cause;
}

class WebDavClient {
  WebDavClient({
    required this.address,
    required this.username,
    required this.password,
    this.directory = '',
    Dio? dio,
  }) : dio = dio ?? Dio() {
    this.dio.options
      ..connectTimeout = kWebDavTimeout
      ..sendTimeout = kWebDavTimeout
      ..receiveTimeout = kWebDavTimeout;
  }

  WebDavClient.fromConfig(WebDavConfig config, {Dio? dio})
    : this(
        address: config.address,
        username: config.username,
        password: config.password,
        directory: config.directory,
        dio: dio,
      );

  final String address;
  final String username;
  final String password;
  final String directory;
  final Dio dio;

  String get _authorization =>
      'Basic ${base64Encode(utf8.encode('$username:$password'))}';

  Uri? _baseUri() {
    final uri = Uri.tryParse(address.trim());
    if (uri == null ||
        uri.host.isEmpty ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      return null;
    }
    return uri;
  }

  Uri _directoryUri(Uri base) {
    final dir = directory.trim().replaceAll(RegExp(r'^/+|/+$'), '');
    var path = base.path.replaceFirst(RegExp(r'/+$'), '');
    if (dir.isNotEmpty) path = '$path/$dir';
    return Uri.parse(
      '${base.scheme}://${base.authority}${path.isEmpty ? '/' : path}',
    );
  }

  Future<Response<Uint8List>> _request(
    Uri uri,
    String method, {
    Map<String, String> headers = const {},
    Object? data,
  }) {
    // ResponseType.bytes makes dio hand back a Uint8List, never a decoded
    // stream or JSON value, so a single generic covers every verb here.
    return dio.requestUri<Uint8List>(
      uri,
      data: data,
      options: Options(
        method: method,
        headers: {'Authorization': _authorization, ...headers},
        responseType: ResponseType.bytes,
        validateStatus: (_) => true,
      ),
    );
  }

  Future<WebDavConnectionResult> testConnection() async {
    final base = _baseUri();
    if (base == null) {
      return WebDavConnectionUnreachable(
        ArgumentError.value(address, 'address', 'must be an http/https URL'),
      );
    }
    try {
      final response = await _request(
        _directoryUri(base),
        'PROPFIND',
        headers: {'Depth': '0'},
      );
      final status = response.statusCode ?? 0;
      if (status == 401 || status == 403) {
        return WebDavConnectionCredentialError(status);
      }
      if (status == 404) return WebDavConnectionDirectoryMissing(status);
      if (status >= 200 && status < 300) return const WebDavConnectionSuccess();
      return WebDavConnectionHttpError(status);
    } on Object catch (error) {
      return WebDavConnectionUnreachable(error);
    }
  }

  Future<WebDavUploadResult> upload(Uint8List bytes) async {
    final base = _baseUri();
    if (base == null) {
      return WebDavUploadFailure(
        WebDavFailureKind.unreachable,
        cause: ArgumentError.value(
          address,
          'address',
          'must be an http/https URL',
        ),
      );
    }
    try {
      final dirUri = _directoryUri(base);
      final mkcol = await _request(dirUri, 'MKCOL');
      final mkcolStatus = mkcol.statusCode ?? 0;
      const directoryReady = {200, 201, 204, 301, 405};
      if (!directoryReady.contains(mkcolStatus)) {
        return WebDavUploadFailure(
          _failureKind(mkcolStatus),
          statusCode: mkcolStatus,
        );
      }
      final put = await _request(
        dirUri.replace(path: '${dirUri.path}/$kWebDavBackupFileName'),
        'PUT',
        headers: {'Content-Type': 'application/json'},
        data: bytes,
      );
      final putStatus = put.statusCode ?? 0;
      if (putStatus >= 200 && putStatus < 300) {
        return const WebDavUploadSuccess();
      }
      return WebDavUploadFailure(
        _failureKind(putStatus),
        statusCode: putStatus,
      );
    } on Object catch (error) {
      return WebDavUploadFailure(WebDavFailureKind.unreachable, cause: error);
    }
  }

  Future<WebDavDownloadResult> download() async {
    final base = _baseUri();
    if (base == null) {
      return WebDavDownloadFailure(
        WebDavFailureKind.unreachable,
        cause: ArgumentError.value(
          address,
          'address',
          'must be an http/https URL',
        ),
      );
    }
    final dirUri = _directoryUri(base);
    try {
      final response = await _request(
        dirUri.replace(path: '${dirUri.path}/$kWebDavBackupFileName'),
        'GET',
      );
      final status = response.statusCode ?? 0;
      if (status == 404) return const WebDavDownloadNoBackup();
      if (status < 200 || status >= 300) {
        return WebDavDownloadFailure(_failureKind(status), statusCode: status);
      }
      final body = response.data;
      if (body == null) {
        return const WebDavDownloadFailure(WebDavFailureKind.httpError);
      }
      return WebDavDownloadSuccess(body);
    } on Object catch (error) {
      return WebDavDownloadFailure(WebDavFailureKind.unreachable, cause: error);
    }
  }

  WebDavFailureKind _failureKind(int status) => status == 401 || status == 403
      ? WebDavFailureKind.credentialError
      : WebDavFailureKind.httpError;
}
