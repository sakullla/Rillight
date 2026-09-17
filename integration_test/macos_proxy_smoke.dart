import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:rillight/player/playback_http_proxy.dart';

// Built as a Release .app and explicitly signed with sandbox entitlements.
// macos/proxy_smoke.py runs both the production rights and a no-server control.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final denied =
      Platform.environment['RILLIGHT_MACOS_EXPECT_SERVER_DENIED'] == '1';
  final watchdog = Timer(const Duration(seconds: 30), () => exit(124));
  try {
    if (!Platform.isMacOS) throw StateError('Requires a signed macOS app');
    await _check(denied).timeout(const Duration(seconds: 20));
    stdout.writeln(
      'RILLIGHT_MACOS_PROXY_SMOKE ${jsonEncode({'passed': true, 'serverDenied': denied})}',
    );
    await stdout.flush();
    watchdog.cancel();
    exit(0);
  } catch (error) {
    stderr.writeln('Sandbox proxy smoke failed: $error');
    await stderr.flush();
    watchdog.cancel();
    exit(1);
  }
}

Future<void> _check(bool denied) async {
  if (denied) {
    try {
      final proxy = await PlaybackHttpProxy.create();
      await proxy.close();
    } on SocketException catch (error) {
      // A timeout, invalid address or unrelated plugin failure is not a valid
      // negative control. macOS must deny the production listener itself.
      if ([1, 13].contains(error.osError?.errorCode)) return;
      rethrow;
    }
    throw StateError(
      'Listener succeeded without the network.server entitlement',
    );
  }

  final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final origin = Uri.parse('http://127.0.0.1:${upstream.port}');
  PlaybackHttpProxy? proxy;
  final client = HttpClient();
  var authorized = false;
  upstream.listen((request) async {
    authorized =
        request.uri.path == '/media' &&
        request.headers.value('X-Emby-Token') == 'synthetic-sandbox-token';
    request.response.statusCode = authorized
        ? HttpStatus.ok
        : HttpStatus.forbidden;
    request.response.write('sandbox-proxy-payload');
    await request.response.close();
  });
  try {
    proxy = await PlaybackHttpProxy.create(
      origin: origin,
      headers: {'X-Emby-Token': 'synthetic-sandbox-token'},
    );
    final request = await client.getUrl(
      proxy.register(origin.resolve('/media')),
    );
    final response = await request.close();
    final body = await utf8.decoder.bind(response).join();
    if (!authorized ||
        response.statusCode != HttpStatus.ok ||
        body != 'sandbox-proxy-payload') {
      throw StateError(
        'The production proxy did not complete the loopback request',
      );
    }
  } finally {
    client.close(force: true);
    await proxy?.close();
    await upstream.close(force: true);
  }
}
