import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight/auth/auth_controller.dart';
import 'package:rillight/emby/emby_client.dart';
import 'package:rillight/media_server/device.dart';
import 'package:rillight/media_server/errors.dart';
import 'package:rillight/media_server/media_server_client.dart';

import '../emby/fake_emby_server.dart';

final _transports = Expando<_ImageTransport>();

/// Establish a real selected session; only image bytes are supplied by the
/// controllable fixture. Authorization and late-response guards stay real.
Future<AuthController> authenticatedImageFixture(
  WidgetTester tester,
  MediaServerClient imageSource,
) async {
  return (await tester.runAsync(() async {
    final adapter = _ImageTransport(imageSource);
    final auth = AuthController.memory(
      client: EmbyClient(
        device: const ClientDeviceInfo(
          clientName: 'test',
          deviceName: 'test',
          deviceId: 'authenticated-image-fixture',
          version: '1',
        ),
        dio: Dio(
          BaseOptions(
            connectTimeout: Duration.zero,
            receiveTimeout: Duration.zero,
          ),
        )..httpClientAdapter = adapter,
      ),
    );
    _transports[auth] = adapter;
    await changeImageFixtureAccount(
      auth,
      address: imageSource.baseUrl?.toString() ?? 'https://images.test/emby',
    );
    expect(auth.isLoggedIn, isTrue);
    return auth;
  }))!;
}

Future<void> changeImageFixtureAccount(
  AuthController auth, {
  required String address,
  String username = 'alice',
}) async {
  final transport = _transports[auth]!;
  transport.add(
    FakeEmbyServer(
      baseUrl: Uri.parse(address),
      serverId: Uri.parse(address).host,
      users: const [
        FakeEmbyUser(
          username: 'alice',
          password: 'correct-horse',
          userId: 'alice',
        ),
        FakeEmbyUser(username: 'bob', password: 'correct-horse', userId: 'bob'),
      ],
    ),
  );
  await auth.connect(
    address: address,
    username: username,
    password: 'correct-horse',
  );
  expect(auth.isLoggedIn, isTrue);
}

class _ImageTransport extends FakeEmbyAdapter {
  _ImageTransport(this.source);
  final MediaServerClient source;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final image = RegExp(r'/Items/([^/]+)/Images/([^/]+)(?:/(\d+))?')
        .firstMatch(options.uri.path);
    if (image == null) return super.fetch(options, requestStream, cancelFuture);
    final type = image[2]!;
    final query = options.uri.queryParameters;
    try {
      final bytes = type == 'Chapter'
          ? await source.getChapterImage(
              image[1]!,
              index: int.parse(image[3]!),
              tag: query['tag'],
              maxWidth: int.parse(query['maxWidth'] ?? '400'),
            )
          : await source.getItemImage(
              image[1]!,
              type: type,
              index: int.tryParse(image[3] ?? ''),
              tag: query['tag'],
              maxWidth: int.parse(query['maxWidth'] ?? '280'),
            );
      return ResponseBody.fromBytes(
        bytes,
        200,
        headers: {
          Headers.contentTypeHeader: ['image/png'],
        },
      );
    } on MediaServerException catch (error) {
      if (error.statusCode != null) {
        return ResponseBody.fromString('', error.statusCode!);
      }
      throw DioException(
        requestOptions: options,
        type: error.kind == MediaServerFailureKind.timeout
            ? DioExceptionType.receiveTimeout
            : DioExceptionType.connectionError,
        error: error,
      );
    }
  }
}
