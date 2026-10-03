import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:rillight/auth/auth_controller.dart';

/// 电视主动开启的一次性局域网辅助连接。
///
/// 只在用户打开时于本进程启动临时 HTTPS,不发现设备、不访问公网。
/// 二维码和地址只含源、端口、配对号和证书指纹。手机提交后须遥控器确认
/// 才会调用 [AuthController.connect];拒绝、过期、取消和未配对请求不建立会话。
class TvLanAssist extends ChangeNotifier {
  TvLanAssist({
    this.lifetime = const Duration(minutes: 3),
    this.phoneGrace = const Duration(seconds: 2),
    InternetAddress? bindAddress,
    this.advertiseHost,
    Random? random,
  }) : _bindAddress = bindAddress,
       _random = random ?? Random.secure();

  final Duration lifetime;

  /// 结果确定后留给手机取最终页面的时间。到点仍关闭入口。
  final Duration phoneGrace;
  final String? advertiseHost;
  final InternetAddress? _bindAddress;
  final Random _random;

  TvLanPhase _phase = TvLanPhase.idle;
  TvLanOffer? _offer;
  _HeldSubmission? _pending;
  String? _password;
  HttpServer? _server;
  Timer? _timer;
  DateTime? _expiresAt;
  Future<void>? _closing;
  bool _reserved = false;
  bool _disposed = false;
  bool _announcedConnecting = false;
  bool _finalSent = false;
  final List<HttpRequest> _watchers = [];
  Completer<void>? _finalDelivered;

  TvLanPhase get phase => _phase;
  TvLanOffer? get offer => _offer;

  /// 本次配对的截止时间。等待界面用它显示有效期。
  DateTime? get expiresAt => _expiresAt;

  /// 还没写完响应、正在等阶段变化的手机请求。
  int get phoneWaiters => _watchers.length;

  /// 待确认的服务器与账号。不含密码。
  TvLanSubmission? get pending {
    final held = _pending;
    if (held == null) {
      return null;
    }
    return TvLanSubmission(server: held.server, account: held.account);
  }

  bool get isTerminal =>
      _phase == TvLanPhase.confirmed ||
      _phase == TvLanPhase.rejected ||
      _phase == TvLanPhase.expired ||
      _phase == TvLanPhase.cancelled ||
      _phase == TvLanPhase.failed;

  /// 绑定端口并出示二维码。重复打开已在进行的会话不会另起入口。
  ///
  /// 套接字放在根 zone,避免测试用的假异步时钟挡住这一次本地服务。
  Future<void> open() {
    if (_disposed || _phase != TvLanPhase.idle) {
      return Future<void>.value();
    }
    return Zone.root.run(_openInRoot);
  }

  Future<void> _openInRoot() async {
    try {
      final host = await _chooseHost();
      final material = _issueCertificate(host);
      final context = SecurityContext(withTrustedRoots: false)
        ..useCertificateChainBytes(utf8.encode(material.certificatePem))
        ..usePrivateKeyBytes(utf8.encode(material.privateKeyPem));
      final server = await HttpServer.bindSecure(
        _bindAddress ?? InternetAddress.anyIPv4,
        0,
        context,
      );
      if (_disposed) {
        await server.close(force: true);
        return;
      }
      _server = server;
      final manual = Uri(
        scheme: 'https',
        host: host,
        port: server.port,
        path: '/',
        queryParameters: {'id': material.pairingId, 'fp': material.fingerprint},
      );
      final qrText = manual.toString();
      _offer = TvLanOffer(
        manualUrl: qrText,
        qrText: qrText,
        fingerprint: material.fingerprint,
        pairingId: material.pairingId,
        port: server.port,
        host: host,
        certificateDer: material.certificateDer,
        qrModules: TvLanQr.encode(qrText),
      );
      _expiresAt = DateTime.now().add(lifetime);
      _phase = TvLanPhase.waiting;
      _timer = Timer(lifetime, _expire);
      _notify();
      unawaited(_serve(server));
    } on Exception {
      if (!_disposed && _phase == TvLanPhase.idle) {
        _phase = TvLanPhase.failed;
        _notify();
      }
      await _shutdown();
    }
  }

  /// 遥控器确认后才登录。非待确认状态不会调用 [AuthController.connect]。
  ///
  /// 成功才换成新会话。失败时保留确认前的会话和令牌，并先把结果页写给手机。
  Future<bool> confirm(AuthController auth) async {
    if (_disposed || _phase != TvLanPhase.pending) {
      return false;
    }
    final held = _pending;
    final password = _password;
    if (held == null || password == null) {
      return false;
    }
    _password = null;
    _pending = null;
    _phase = TvLanPhase.connecting;
    _timer?.cancel();
    _notify();
    await _flushWatchers();
    var accepted = false;
    try {
      accepted = await auth.connect(
        address: held.server,
        username: held.account,
        password: password,
        preserveSessionOnFailure: true,
      );
    } finally {
      if (!_disposed) {
        _phase = accepted ? TvLanPhase.confirmed : TvLanPhase.failed;
        _notify();
        await _deliverFinalThenClose();
      }
    }
    return accepted;
  }

  /// 拒绝当前提交,不登录,并关闭入口。
  Future<void> reject() async {
    if (_disposed || _phase != TvLanPhase.pending) {
      return;
    }
    await _finish(TvLanPhase.rejected);
  }

  /// 用户退出辅助。不修改已有会话。
  Future<void> cancel() async {
    if (_disposed ||
        isTerminal ||
        _phase == TvLanPhase.idle ||
        _phase == TvLanPhase.connecting) {
      return;
    }
    await _finish(TvLanPhase.cancelled);
  }

  /// 浏览器警告无法继续时结束辅助,不猜测原因。
  Future<void> markIncomplete() async {
    if (_disposed ||
        isTerminal ||
        _phase == TvLanPhase.idle ||
        _phase == TvLanPhase.connecting) {
      return;
    }
    await _finish(TvLanPhase.failed);
  }

  Future<void> _finish(TvLanPhase phase) async {
    final submitted = _phase == TvLanPhase.pending;
    _wipe();
    _phase = phase;
    _timer?.cancel();
    _notify();
    if (submitted) {
      await _deliverFinalThenClose();
    } else {
      await _shutdown();
    }
  }

  Future<void> close() => _shutdown();

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    if (_phase == TvLanPhase.waiting || _phase == TvLanPhase.pending) {
      _wipe();
      _phase = TvLanPhase.cancelled;
    }
    unawaited(_shutdown());
    super.dispose();
  }

  Future<String> _chooseHost() async {
    final forced = advertiseHost;
    if (forced != null && forced.isNotEmpty) {
      return forced;
    }
    try {
      final interfaces = await NetworkInterface.list(
        includeLinkLocal: false,
        type: InternetAddressType.IPv4,
      );
      final addresses = <String>[];
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          if (!address.isLoopback && _ipv4(address.address) != null) {
            addresses.add(address.address);
          }
        }
      }
      for (final address in addresses) {
        if (_isPrivate(address)) {
          return address;
        }
      }
      if (addresses.isNotEmpty) {
        return addresses.first;
      }
    } catch (_) {
      // 没有可用网卡时仍给出本机地址,用户可改用遥控器登录。
    }
    return InternetAddress.loopbackIPv4.address;
  }

  _CertificateMaterial _issueCertificate(String host) {
    final key = _P256.generate(_random);
    final pairingId = _pairingId();
    final now = DateTime.now().toUtc();
    final certificate = _buildCertificate(
      key: key,
      host: host,
      serial: _serial(),
      notBefore: now.subtract(const Duration(hours: 1)),
      notAfter: now.add(const Duration(days: 1)),
    );
    final fingerprint = _hex(_sha256(certificate));
    return _CertificateMaterial(
      pairingId: pairingId,
      fingerprint: fingerprint,
      certificateDer: Uint8List.fromList(certificate),
      certificatePem: _pem('CERTIFICATE', certificate),
      privateKeyPem: _pem('PRIVATE KEY', key.pkcs8),
    );
  }

  String _pairingId() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  List<int> _serial() {
    final bytes = List<int>.generate(8, (_) => _random.nextInt(256));
    bytes[0] = (bytes[0] & 0x7f) | 0x01;
    return bytes;
  }

  void _expire() {
    if (_phase != TvLanPhase.waiting && _phase != TvLanPhase.pending) {
      return;
    }
    final submitted = _phase == TvLanPhase.pending;
    _wipe();
    _phase = TvLanPhase.expired;
    _notify();
    if (submitted) {
      unawaited(_deliverFinalThenClose());
    } else {
      unawaited(_shutdown());
    }
  }

  void _wipe() {
    _password = null;
    _pending = null;
    _reserved = false;
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  Future<void> _deliverFinalThenClose() async {
    await _flushWatchers();
    if (!_finalSent && phoneGrace > Duration.zero) {
      final done = Completer<void>();
      _finalDelivered = done;
      try {
        await done.future.timeout(phoneGrace);
      } on TimeoutException {
        // 手机没有来取最终页面时仍关闭入口。
      }
      _finalDelivered = null;
    }
    await _shutdown();
  }

  void _noteFinalDelivered() {
    _finalSent = true;
    final done = _finalDelivered;
    if (done != null && !done.isCompleted) {
      done.complete();
    }
  }

  Future<void> _flushWatchers() async {
    final pending = List<HttpRequest>.of(_watchers);
    _watchers.clear();
    if (_phase == TvLanPhase.connecting && pending.isNotEmpty) {
      _announcedConnecting = true;
    }
    for (final request in pending) {
      try {
        await _reply(request, HttpStatus.ok, _phoneStatePage());
        if (isTerminal) {
          _noteFinalDelivered();
        }
      } catch (_) {}
    }
  }

  Future<void> _servePhone(HttpRequest request) async {
    if (isTerminal) {
      await _reply(request, HttpStatus.ok, _phoneStatePage());
      _noteFinalDelivered();
      return;
    }
    if (_phase == TvLanPhase.connecting && !_announcedConnecting) {
      _announcedConnecting = true;
      await _reply(request, HttpStatus.ok, _phoneStatePage());
      return;
    }
    if (_phase == TvLanPhase.pending || _phase == TvLanPhase.connecting) {
      _watchers.add(request);
      return;
    }
    await _reply(request, HttpStatus.notFound, _phoneMessage('无法使用此连接。'));
  }

  Future<void> _shutdown() {
    _timer?.cancel();
    final closing = _closing;
    if (closing != null) {
      return closing;
    }
    final server = _server;
    _server = null;
    _watchers.clear();
    if (server == null) {
      return _closing = Future<void>.value();
    }
    final Future<void> closed = Zone.root.run<Future<void>>(() async {
      try {
        await server.close(force: true).timeout(const Duration(seconds: 2));
      } on TimeoutException {
        // 套接字迟迟不退出时不再挡住确认和后续清理。
      }
    });
    return _closing = closed;
  }

  Future<void> _serve(HttpServer server) async {
    try {
      await for (final request in server) {
        try {
          await _handle(request);
        } catch (_) {
          try {
            await request.response.close();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  Future<void> _handle(HttpRequest request) async {
    final id = request.uri.queryParameters['id'];
    final fingerprint = request.uri.queryParameters['fp'];
    final offer = _offer;
    if (offer == null ||
        id == null ||
        !_same(id, offer.pairingId) ||
        fingerprint != offer.fingerprint) {
      await _reply(request, HttpStatus.notFound, _phoneMessage('无法使用此连接。'));
      return;
    }
    final path = request.uri.path.isEmpty ? '/' : request.uri.path;
    if (request.method == 'GET' && (path == '/' || path == '/status')) {
      if (_phase == TvLanPhase.waiting && path == '/') {
        await _reply(
          request,
          HttpStatus.ok,
          _phoneForm(
            fingerprint: offer.fingerprint,
            pairingId: offer.pairingId,
          ),
        );
        return;
      }
      if (_phase != TvLanPhase.waiting && _phase != TvLanPhase.idle) {
        await _servePhone(request);
        return;
      }
    }
    if (isTerminal) {
      await _reply(request, HttpStatus.gone, _phoneMessage('无法使用此连接。'));
      return;
    }
    if (request.method == 'POST' && path == '/submit') {
      await _submit(request);
      return;
    }
    await _reply(
      request,
      HttpStatus.methodNotAllowed,
      _phoneMessage('无法使用此连接。'),
    );
  }

  Future<void> _submit(HttpRequest request) async {
    if (_phase != TvLanPhase.waiting || _reserved || _pending != null) {
      await _reply(request, HttpStatus.conflict, _phoneMessage('已经提交过了。'));
      return;
    }
    _reserved = true;
    String body;
    try {
      body = await _readBody(request);
    } catch (_) {
      _reserved = false;
      await _reply(request, HttpStatus.badRequest, _phoneMessage('无法使用此连接。'));
      return;
    }
    if (_phase != TvLanPhase.waiting || _pending != null) {
      _reserved = false;
      await _reply(request, HttpStatus.gone, _phoneMessage('无法使用此连接。'));
      return;
    }
    final form = Uri.splitQueryString(body);
    final address = (form['address'] ?? '').trim();
    final username = (form['username'] ?? '').trim();
    final password = form['password'] ?? '';
    if (address.isEmpty ||
        username.isEmpty ||
        address.length > 512 ||
        username.length > 256 ||
        password.length > 256) {
      _reserved = false;
      await _reply(request, HttpStatus.badRequest, _phoneMessage('请填写服务器和账号。'));
      return;
    }
    _pending = _HeldSubmission(server: address, account: username);
    _password = password;
    _phase = TvLanPhase.pending;
    _notify();
    await _reply(request, HttpStatus.ok, _phoneStatePage());
  }

  Future<String> _readBody(HttpRequest request) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in request) {
      if (builder.length + chunk.length > 4096) {
        throw StateError('body too large');
      }
      builder.add(chunk);
    }
    return utf8.decode(builder.takeBytes());
  }

  String _statusTarget() {
    final offer = _offer;
    if (offer == null) {
      return '/status';
    }
    return '/status?id=${offer.pairingId}&fp=${offer.fingerprint}';
  }

  String _phoneStatePage() => _phoneStateFor(_phase, _statusTarget());

  Future<void> _reply(HttpRequest request, int status, String body) async {
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType(
      'text',
      'html',
      charset: 'utf-8',
    );
    request.response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    request.response.write(body);
    await request.response.close();
  }
}

enum TvLanPhase {
  idle,
  waiting,
  pending,
  connecting,
  confirmed,
  rejected,
  expired,
  cancelled,
  failed,
}

class TvLanOffer {
  const TvLanOffer({
    required this.manualUrl,
    required this.qrText,
    required this.fingerprint,
    required this.pairingId,
    required this.port,
    required this.host,
    required this.certificateDer,
    required this.qrModules,
  });

  final String manualUrl;
  final String qrText;
  final String fingerprint;
  final String pairingId;
  final int port;
  final String host;
  final Uint8List certificateDer;
  final List<List<bool>> qrModules;
}

class TvLanSubmission {
  const TvLanSubmission({required this.server, required this.account});

  final String server;
  final String account;
}

class TvLanQrImage extends StatelessWidget {
  const TvLanQrImage({super.key, required this.modules});

  final List<List<bool>> modules;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size(220, 220),
      painter: _QrPainter(modules),
    );
  }
}

class _HeldSubmission {
  const _HeldSubmission({required this.server, required this.account});

  final String server;
  final String account;
}

class _CertificateMaterial {
  const _CertificateMaterial({
    required this.pairingId,
    required this.fingerprint,
    required this.certificateDer,
    required this.certificatePem,
    required this.privateKeyPem,
  });

  final String pairingId;
  final String fingerprint;
  final Uint8List certificateDer;
  final String certificatePem;
  final String privateKeyPem;
}

class _QrPainter extends CustomPainter {
  const _QrPainter(this.modules);

  final List<List<bool>> modules;

  @override
  void paint(Canvas canvas, Size size) {
    final count = modules.length;
    const quiet = 4;
    final scale = size.shortestSide / (count + quiet * 2);
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xffffffff),
    );
    final paint = Paint()..color = const Color(0xff000000);
    for (var y = 0; y < count; y++) {
      for (var x = 0; x < count; x++) {
        if (!modules[y][x]) {
          continue;
        }
        canvas.drawRect(
          Rect.fromLTWH((x + quiet) * scale, (y + quiet) * scale, scale, scale),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _QrPainter oldDelegate) =>
      !identical(oldDelegate.modules, modules);
}

bool _same(String a, String b) {
  if (a.length != b.length) {
    return false;
  }
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return diff == 0;
}

bool _isPrivate(String host) {
  final parts = _ipv4(host);
  if (parts == null) {
    return false;
  }
  final a = parts[0];
  final b = parts[1];
  if (a == 10) {
    return true;
  }
  if (a == 192 && b == 168) {
    return true;
  }
  return a == 172 && b >= 16 && b <= 31;
}

List<int>? _ipv4(String host) {
  final parts = host.split('.');
  if (parts.length != 4) {
    return null;
  }
  final out = <int>[];
  for (final part in parts) {
    final value = int.tryParse(part);
    if (value == null || value < 0 || value > 255 || '$value' != part) {
      return null;
    }
    out.add(value);
  }
  return out;
}

String _phoneForm({required String fingerprint, required String pairingId}) {
  final id = _html(pairingId);
  final fp = _html(fingerprint);
  return '''
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>灯川连接</title>
<style>
body{font-family:sans-serif;margin:24px;background:#111;color:#eee}
input,button{display:block;width:100%;box-sizing:border-box;margin:8px 0 16px;padding:12px;font-size:16px}
code{word-break:break-all}
</style>
</head>
<body>
<h1>灯川 Rillight</h1>
<p>证书指纹</p>
<code>$fp</code>
<form method="post" action="/submit?id=$id&amp;fp=$fp">
<label>服务器地址<input name="address" autocomplete="url" required></label>
<label>用户名<input name="username" autocomplete="username" required></label>
<label>密码<input name="password" type="password" autocomplete="current-password"></label>
<button type="submit">提交到电视</button>
</form>
</body>
</html>
''';
}

String _phoneMessage(String text) {
  return '<!DOCTYPE html><html lang="zh-CN"><meta charset="utf-8"><title>灯川连接</title><p>${_html(text)}</p></html>';
}

String _phoneStateFor(TvLanPhase phase, String refresh) {
  switch (phase) {
    case TvLanPhase.pending:
      return _phoneState('待确认', '请在电视上确认这次连接。', refresh: refresh);
    case TvLanPhase.connecting:
      return _phoneState('连接中', '正在连接服务器。', refresh: refresh);
    case TvLanPhase.confirmed:
      return _phoneState('成功', '电视已连接。');
    case TvLanPhase.rejected:
    case TvLanPhase.expired:
    case TvLanPhase.cancelled:
    case TvLanPhase.failed:
      return _phoneState('失败', '连接未完成。');
    case TvLanPhase.idle:
    case TvLanPhase.waiting:
      return _phoneMessage('无法使用此连接。');
  }
}

String _phoneState(String heading, String detail, {String? refresh}) {
  final next = refresh == null
      ? ''
      : '<meta http-equiv="refresh" content="0;url=${_html(refresh)}">';
  return '''
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
$next
<title>灯川连接</title>
<style>
body{font-family:sans-serif;margin:24px;background:#111;color:#eee}
</style>
</head>
<body>
<h1>${_html(heading)}</h1>
<p>${_html(detail)}</p>
</body>
</html>
''';
}

String _html(String value) {
  return value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');
}

String _pem(String label, List<int> der) {
  final encoded = base64.encode(der);
  final lines = <String>[];
  for (var i = 0; i < encoded.length; i += 64) {
    final end = i + 64 < encoded.length ? i + 64 : encoded.length;
    lines.add(encoded.substring(i, end));
  }
  return '-----BEGIN $label-----\n${lines.join('\n')}\n-----END $label-----\n';
}

String _hex(List<int> bytes) {
  final buffer = StringBuffer();
  for (final byte in bytes) {
    buffer.write(byte.toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

List<int> _buildCertificate({
  required _P256Key key,
  required String host,
  required List<int> serial,
  required DateTime notBefore,
  required DateTime notAfter,
}) {
  final name = _dn(_printableCn(host));
  final ip = _ipv4(host);
  final sanBody = ip == null
      ? _tlv(0x30, [0x82, host.length, ...ascii.encode(host)])
      : _tlv(0x30, [0x87, ip.length, ...ip]);
  final extensions = _tlv(0x30, [
    ..._extension([0x55, 0x1d, 0x11], sanBody),
    ..._extension([0x55, 0x1d, 0x0f], _bitString([0x80])),
    ..._extension(
      [0x55, 0x1d, 0x25],
      _tlv(0x30, [
        ..._tlv(0x06, [0x2b, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x01]),
      ]),
    ),
  ]);
  final signatureAlgorithm = _tlv(0x30, [
    ..._tlv(0x06, [0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02]),
  ]);
  final tbs = _tlv(0x30, [
    ..._tlv(0xa0, _tlv(0x02, [0x02])),
    ..._tlv(0x02, serial),
    ...signatureAlgorithm,
    ...name,
    ..._tlv(0x30, [..._utc(notBefore), ..._utc(notAfter)]),
    ...name,
    ...key.spki,
    ..._tlv(0xa3, extensions),
  ]);
  final signature = _P256.sign(key, _sha256(tbs), Random.secure());
  return _tlv(0x30, [...tbs, ...signatureAlgorithm, ..._bitString(signature)]);
}

String _printableCn(String host) {
  final printable = RegExp(r"^[A-Za-z0-9 '()+,\-./:=?]+$");
  if (host.isNotEmpty && printable.hasMatch(host)) {
    return host;
  }
  return 'Rillight';
}

List<int> _dn(String cn) {
  final value = ascii.encode(cn);
  return _tlv(0x30, [
    ..._tlv(0x31, [
      ..._tlv(0x30, [
        ..._tlv(0x06, [0x55, 0x04, 0x03]),
        ..._tlv(0x13, value),
      ]),
    ]),
  ]);
}

List<int> _extension(List<int> oid, List<int> value) {
  return _tlv(0x30, [..._tlv(0x06, oid), ..._tlv(0x04, value)]);
}

List<int> _utc(DateTime time) {
  final utc = time.toUtc();
  String two(int value) => value.toString().padLeft(2, '0');
  final text =
      '${two(utc.year % 100)}${two(utc.month)}${two(utc.day)}${two(utc.hour)}${two(utc.minute)}${two(utc.second)}Z';
  return _tlv(0x17, ascii.encode(text));
}

List<int> _bitString(List<int> bytes) => _tlv(0x03, [0x00, ...bytes]);

List<int> _tlv(int tag, List<int> body) => [
  tag,
  ..._derLength(body.length),
  ...body,
];

List<int> _derLength(int length) {
  if (length < 0x80) {
    return [length];
  }
  if (length <= 0xff) {
    return [0x81, length];
  }
  if (length <= 0xffff) {
    return [0x82, length >> 8, length & 0xff];
  }
  throw StateError('DER value is too long');
}

class _P256Key {
  _P256Key(this.d, this.x, this.y);

  final BigInt d;
  final BigInt x;
  final BigInt y;

  Uint8List get pkcs8 {
    final dx = _be(d);
    final xx = _be(x);
    final yy = _be(y);
    final der = Uint8List.fromList([
      0x30, 0x81, 0x87, 0x02, 0x01, 0x00, 0x30, 0x13, //
      0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, //
      0x01, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, //
      0x03, 0x01, 0x07, 0x04, 0x6d, 0x30, 0x6b, 0x02, //
      0x01, 0x01, 0x04, 0x20, ...dx, //
      0xa1, 0x44, 0x03, 0x42, 0x00, 0x04, ...xx, ...yy,
    ]);
    if (der.length != 138) {
      throw StateError('Unexpected P-256 key length');
    }
    return der;
  }

  List<int> get spki {
    return _tlv(0x30, [
      ..._tlv(0x30, [
        ..._tlv(0x06, [0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01]),
        ..._tlv(0x06, [0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07]),
      ]),
      ..._bitString([0x04, ..._be(x), ..._be(y)]),
    ]);
  }
}

Uint8List _be(BigInt value) {
  final out = Uint8List(32);
  var rest = value;
  for (var i = 31; i >= 0; i--) {
    out[i] = (rest & BigInt.from(0xff)).toInt();
    rest >>= 8;
  }
  return out;
}

/// P-256 与自签证书。只用于这一次辅助连接。
class _P256 {
  static final BigInt _p = BigInt.parse(
    'ffffffff00000001000000000000000000000000ffffffffffffffffffffffff',
    radix: 16,
  );
  static final BigInt _n = BigInt.parse(
    'ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551',
    radix: 16,
  );
  static final BigInt _b = BigInt.parse(
    '5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b',
    radix: 16,
  );
  static final _Pt _g = _Pt(
    BigInt.parse(
      '6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296',
      radix: 16,
    ),
    BigInt.parse(
      '4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5',
      radix: 16,
    ),
  );

  static _P256Key generate(Random random) {
    for (var attempt = 0; attempt < 8; attempt++) {
      final d = _scalar(random);
      final point = _mul(d, _g);
      if (!point.infinite && _onCurve(point)) {
        return _P256Key(d, point.x, point.y);
      }
    }
    throw StateError('Could not generate a pairing key');
  }

  static List<int> sign(_P256Key key, List<int> hash, Random random) {
    final e = _mod(_fromBe(hash), _n);
    for (var attempt = 0; attempt < 8; attempt++) {
      final k = _scalar(random);
      final point = _mul(k, _g);
      if (point.infinite) {
        continue;
      }
      final r = _mod(point.x, _n);
      if (r == BigInt.zero) {
        continue;
      }
      final s = _mod(k.modInverse(_n) * _mod(e + _mod(r * key.d, _n), _n), _n);
      if (s == BigInt.zero) {
        continue;
      }
      final low = s <= (_n >> 1) ? s : _n - s;
      final body = _tlv(0x30, [..._derInt(r), ..._derInt(low)]);
      if (!_verify(hash, r, low, _Pt(key.x, key.y))) {
        continue;
      }
      return body;
    }
    throw StateError('Could not sign the pairing certificate');
  }

  static bool _verify(List<int> hash, BigInt r, BigInt s, _Pt pub) {
    if (r <= BigInt.zero || s <= BigInt.zero || r >= _n || s >= _n) {
      return false;
    }
    final e = _mod(_fromBe(hash), _n);
    final w = s.modInverse(_n);
    final u1 = _mod(e * w, _n);
    final u2 = _mod(r * w, _n);
    final point = _add(_mul(u1, _g), _mul(u2, pub));
    return !point.infinite && _mod(point.x, _n) == r;
  }

  static BigInt _scalar(Random random) {
    while (true) {
      final bytes = List<int>.generate(32, (_) => random.nextInt(256));
      final value = _fromBe(bytes);
      if (value > BigInt.zero && value < _n) {
        return value;
      }
    }
  }

  static bool _onCurve(_Pt point) {
    final y2 = _mod(point.y * point.y, _p);
    final x3 = _mod(
      point.x * point.x * point.x - BigInt.from(3) * point.x + _b,
      _p,
    );
    return y2 == x3;
  }

  static _Pt _add(_Pt a, _Pt b) {
    if (a.infinite) {
      return b;
    }
    if (b.infinite) {
      return a;
    }
    if (a.x == b.x) {
      if (_mod(a.y + b.y, _p) == BigInt.zero) {
        return _Pt.infinity;
      }
      return _double(a);
    }
    final slope = _mod((b.y - a.y) * _mod(b.x - a.x, _p).modInverse(_p), _p);
    final x = _mod(slope * slope - a.x - b.x, _p);
    final y = _mod(slope * (a.x - x) - a.y, _p);
    return _Pt(x, y);
  }

  static _Pt _double(_Pt a) {
    if (a.infinite || a.y == BigInt.zero) {
      return _Pt.infinity;
    }
    final slope = _mod(
      (BigInt.from(3) * a.x * a.x - BigInt.from(3)) *
          _mod(BigInt.two * a.y, _p).modInverse(_p),
      _p,
    );
    final x = _mod(slope * slope - BigInt.two * a.x, _p);
    final y = _mod(slope * (a.x - x) - a.y, _p);
    return _Pt(x, y);
  }

  static _Pt _mul(BigInt scalar, _Pt point) {
    var result = _Pt.infinity;
    var addend = point;
    var bits = scalar;
    while (bits > BigInt.zero) {
      if (bits.isOdd) {
        result = _add(result, addend);
      }
      addend = _double(addend);
      bits >>= 1;
    }
    return result;
  }

  static BigInt _mod(BigInt value, BigInt modulus) {
    final remainder = value % modulus;
    return remainder.sign < 0 ? remainder + modulus : remainder;
  }

  static BigInt _fromBe(List<int> bytes) {
    var value = BigInt.zero;
    for (final byte in bytes) {
      value = (value << 8) | BigInt.from(byte);
    }
    return value;
  }

  static List<int> _derInt(BigInt value) {
    var hex = value.toRadixString(16);
    if (hex.length.isOdd) {
      hex = '0$hex';
    }
    final bytes = <int>[];
    for (var i = 0; i < hex.length; i += 2) {
      bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    if (bytes.isEmpty) {
      bytes.add(0);
    }
    if (bytes[0] & 0x80 != 0) {
      bytes.insert(0, 0);
    }
    return _tlv(0x02, bytes);
  }
}

class _Pt {
  _Pt(this.x, this.y) : infinite = false;

  _Pt.inf() : x = BigInt.zero, y = BigInt.zero, infinite = true;

  static final infinity = _Pt.inf();

  final BigInt x;
  final BigInt y;
  final bool infinite;
}

List<int> _sha256(List<int> message) {
  assert(() {
    const expected =
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';
    return _hex(_sha256Unchecked(ascii.encode('abc'))) == expected;
  }());
  return _sha256Unchecked(message);
}

List<int> _sha256Unchecked(List<int> message) {
  const k = <int>[
    0x428a2f98,
    0x71374491,
    0xb5c0fbcf,
    0xe9b5dba5,
    0x3956c25b,
    0x59f111f1,
    0x923f82a4,
    0xab1c5ed5,
    0xd807aa98,
    0x12835b01,
    0x243185be,
    0x550c7dc3,
    0x72be5d74,
    0x80deb1fe,
    0x9bdc06a7,
    0xc19bf174,
    0xe49b69c1,
    0xefbe4786,
    0x0fc19dc6,
    0x240ca1cc,
    0x2de92c6f,
    0x4a7484aa,
    0x5cb0a9dc,
    0x76f988da,
    0x983e5152,
    0xa831c66d,
    0xb00327c8,
    0xbf597fc7,
    0xc6e00bf3,
    0xd5a79147,
    0x06ca6351,
    0x14292967,
    0x27b70a85,
    0x2e1b2138,
    0x4d2c6dfc,
    0x53380d13,
    0x650a7354,
    0x766a0abb,
    0x81c2c92e,
    0x92722c85,
    0xa2bfe8a1,
    0xa81a664b,
    0xc24b8b70,
    0xc76c51a3,
    0xd192e819,
    0xd6990624,
    0xf40e3585,
    0x106aa070,
    0x19a4c116,
    0x1e376c08,
    0x2748774c,
    0x34b0bcb5,
    0x391c0cb3,
    0x4ed8aa4a,
    0x5b9cca4f,
    0x682e6ff3,
    0x748f82ee,
    0x78a5636f,
    0x84c87814,
    0x8cc70208,
    0x90befffa,
    0xa4506ceb,
    0xbef9a3f7,
    0xc67178f2,
  ];
  final hash = <int>[
    0x6a09e667,
    0xbb67ae85,
    0x3c6ef372,
    0xa54ff53a,
    0x510e527f,
    0x9b05688c,
    0x1f83d9ab,
    0x5be0cd19,
  ];
  final length = message.length;
  final zeroPad = (56 - ((length + 1) % 64)) % 64;
  final padded = Uint8List(length + 1 + zeroPad + 8);
  padded.setRange(0, length, message);
  padded[length] = 0x80;
  final bitLength = length * 8;
  for (var i = 0; i < 8; i++) {
    padded[padded.length - 1 - i] = (bitLength >> (8 * i)) & 0xff;
  }
  final w = List<int>.filled(64, 0);
  for (var offset = 0; offset < padded.length; offset += 64) {
    for (var i = 0; i < 16; i++) {
      final j = offset + i * 4;
      w[i] =
          (padded[j] << 24) |
          (padded[j + 1] << 16) |
          (padded[j + 2] << 8) |
          padded[j + 3];
    }
    for (var i = 16; i < 64; i++) {
      final s0 = _rotr(w[i - 15], 7) ^ _rotr(w[i - 15], 18) ^ (w[i - 15] >>> 3);
      final s1 = _rotr(w[i - 2], 17) ^ _rotr(w[i - 2], 19) ^ (w[i - 2] >>> 10);
      w[i] = _add(_add(w[i - 16], s0), _add(w[i - 7], s1));
    }
    var a = hash[0];
    var b = hash[1];
    var c = hash[2];
    var d = hash[3];
    var e = hash[4];
    var f = hash[5];
    var g = hash[6];
    var h = hash[7];
    for (var i = 0; i < 64; i++) {
      final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final ch = ((e & f) ^ ((~e) & g)) & 0xffffffff;
      final temp1 = _add(_add(_add(_add(h, s1), ch), k[i]), w[i]);
      final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final maj = ((a & b) ^ (a & c) ^ (b & c)) & 0xffffffff;
      final temp2 = _add(s0, maj);
      h = g;
      g = f;
      f = e;
      e = _add(d, temp1);
      d = c;
      c = b;
      b = a;
      a = _add(temp1, temp2);
    }
    hash[0] = _add(hash[0], a);
    hash[1] = _add(hash[1], b);
    hash[2] = _add(hash[2], c);
    hash[3] = _add(hash[3], d);
    hash[4] = _add(hash[4], e);
    hash[5] = _add(hash[5], f);
    hash[6] = _add(hash[6], g);
    hash[7] = _add(hash[7], h);
  }
  final out = Uint8List(32);
  for (var i = 0; i < 8; i++) {
    out[i * 4] = hash[i] >>> 24;
    out[i * 4 + 1] = (hash[i] >>> 16) & 0xff;
    out[i * 4 + 2] = (hash[i] >>> 8) & 0xff;
    out[i * 4 + 3] = hash[i] & 0xff;
  }
  return out;
}

int _add(int a, int b) => (a + b) & 0xffffffff;

int _rotr(int value, int bits) {
  final masked = value & 0xffffffff;
  return ((masked >>> bits) | (masked << (32 - bits))) & 0xffffffff;
}

/// ISO/IEC 18004 Model 2, byte mode, error correction M, versions 1–10.
class TvLanQr {
  static List<List<bool>> encode(String text) {
    final data = utf8.encode(text);
    final version = _versionFor(data.length);
    final size = version * 4 + 17;
    final modules = List.generate(size, (_) => List<bool>.filled(size, false));
    final function = List.generate(size, (_) => List<bool>.filled(size, false));
    _drawFunction(modules, function, version, size);
    final codewords = _codewords(data, version);
    _drawCodewords(modules, function, codewords, size);
    _mask(modules, function, size);
    _drawFormat(modules, function, size, _formatBits(0));
    return modules;
  }

  static int _versionFor(int length) {
    for (var version = 1; version <= 10; version++) {
      final bits = 4 + (version <= 9 ? 8 : 16) + length * 8;
      if (bits <= _dataCodewords(version) * 8) {
        return version;
      }
    }
    throw StateError('Pairing URL does not fit in a QR symbol');
  }

  static void _drawFunction(
    List<List<bool>> modules,
    List<List<bool>> function,
    int version,
    int size,
  ) {
    for (var i = 0; i < size; i++) {
      _set(modules, function, 6, i, i.isEven);
      _set(modules, function, i, 6, i.isEven);
    }
    _finder(modules, function, 3, 3, size);
    _finder(modules, function, size - 4, 3, size);
    _finder(modules, function, 3, size - 4, size);
    final positions = _alignment(version, size);
    for (var i = 0; i < positions.length; i++) {
      for (var j = 0; j < positions.length; j++) {
        if (i == 0 && j == 0 ||
            i == 0 && j == positions.length - 1 ||
            i == positions.length - 1 && j == 0) {
          continue;
        }
        _alignmentPattern(modules, function, positions[i], positions[j]);
      }
    }
    _drawFormat(modules, function, size, _formatBits(0));
    _drawVersion(modules, function, version, size);
  }

  static void _finder(
    List<List<bool>> modules,
    List<List<bool>> function,
    int x,
    int y,
    int size,
  ) {
    for (var dy = -4; dy <= 4; dy++) {
      for (var dx = -4; dx <= 4; dx++) {
        final xx = x + dx;
        final yy = y + dy;
        if (xx < 0 || yy < 0 || xx >= size || yy >= size) {
          continue;
        }
        final dist = max(dx.abs(), dy.abs());
        _set(modules, function, xx, yy, dist != 2 && dist != 4);
      }
    }
  }

  static void _alignmentPattern(
    List<List<bool>> modules,
    List<List<bool>> function,
    int x,
    int y,
  ) {
    for (var dy = -2; dy <= 2; dy++) {
      for (var dx = -2; dx <= 2; dx++) {
        _set(modules, function, x + dx, y + dy, max(dx.abs(), dy.abs()) != 1);
      }
    }
  }

  static List<int> _alignment(int version, int size) {
    if (version == 1) {
      return const [];
    }
    final count = version ~/ 7 + 2;
    final step = (version * 8 + count * 3 + 5) ~/ (count * 4 - 4) * 2;
    final positions = List<int>.filled(count, 6);
    var pos = size - 7;
    for (var i = count - 1; i >= 1; i--) {
      positions[i] = pos;
      pos -= step;
    }
    return positions;
  }

  static void _drawFormat(
    List<List<bool>> modules,
    List<List<bool>> function,
    int size,
    int bits,
  ) {
    for (var i = 0; i <= 5; i++) {
      _set(modules, function, 8, i, _bit(bits, i));
    }
    _set(modules, function, 8, 7, _bit(bits, 6));
    _set(modules, function, 8, 8, _bit(bits, 7));
    _set(modules, function, 7, 8, _bit(bits, 8));
    for (var i = 9; i < 15; i++) {
      _set(modules, function, 14 - i, 8, _bit(bits, i));
    }
    for (var i = 0; i < 8; i++) {
      _set(modules, function, size - 1 - i, 8, _bit(bits, i));
    }
    for (var i = 8; i < 15; i++) {
      _set(modules, function, 8, size - 15 + i, _bit(bits, i));
    }
    _set(modules, function, 8, size - 8, true);
  }

  static int _formatBits(int mask) {
    final data = mask & 7;
    var rem = data;
    for (var i = 0; i < 10; i++) {
      rem = ((rem << 1) ^ ((rem >>> 9) * 0x537)) & 0xffffffff;
    }
    return (((data << 10) | rem) ^ 0x5412) & 0x7fff;
  }

  static void _drawVersion(
    List<List<bool>> modules,
    List<List<bool>> function,
    int version,
    int size,
  ) {
    if (version < 7) {
      return;
    }
    var rem = version;
    for (var i = 0; i < 12; i++) {
      rem = ((rem << 1) ^ ((rem >>> 11) * 0x1f25)) & 0xffffffff;
    }
    final bits = ((version << 12) | rem) & 0x3ffff;
    for (var i = 0; i < 18; i++) {
      final bit = _bit(bits, i);
      final a = size - 11 + i % 3;
      final b = i ~/ 3;
      _set(modules, function, a, b, bit);
      _set(modules, function, b, a, bit);
    }
  }

  static void _set(
    List<List<bool>> modules,
    List<List<bool>> function,
    int x,
    int y,
    bool dark,
  ) {
    modules[y][x] = dark;
    function[y][x] = true;
  }

  static bool _bit(int value, int index) => ((value >>> index) & 1) != 0;

  static List<int> _codewords(List<int> data, int version) {
    final capacity = _dataCodewords(version) * 8;
    final bits = <int>[];
    void add(int value, int length) {
      for (var i = length - 1; i >= 0; i--) {
        bits.add((value >>> i) & 1);
      }
    }

    add(0x4, 4);
    add(data.length, version <= 9 ? 8 : 16);
    for (final byte in data) {
      add(byte, 8);
    }
    final terminator = capacity - bits.length;
    add(0, terminator < 4 ? terminator : 4);
    while (bits.length % 8 != 0) {
      bits.add(0);
    }
    for (var pad = 0xec; bits.length < capacity; pad ^= 0xec ^ 0x11) {
      add(pad, 8);
    }
    final bytes = List<int>.filled(bits.length ~/ 8, 0);
    for (var i = 0; i < bits.length; i++) {
      bytes[i >> 3] |= bits[i] << (7 - (i & 7));
    }
    return _interleave(bytes, version);
  }

  static List<int> _interleave(List<int> data, int version) {
    final blockEcc = _eccPerBlock[version];
    final blocks = _blockCount[version];
    final raw = _rawCodewords(version);
    final shortBlocks = blocks - raw % blocks;
    final shortLen = raw ~/ blocks;
    final divisor = _rsDivisor(blockEcc);
    final parts = <List<int>>[];
    var offset = 0;
    for (var i = 0; i < blocks; i++) {
      final dataLen = shortLen - blockEcc + (i < shortBlocks ? 0 : 1);
      final chunk = data.sublist(offset, offset + dataLen);
      offset += dataLen;
      final block = List<int>.filled(shortLen + 1, 0);
      block.setRange(0, chunk.length, chunk);
      final ecc = _rsRemainder(chunk, divisor);
      block.setRange(block.length - ecc.length, block.length, ecc);
      parts.add(block);
    }
    if (offset != data.length) {
      throw StateError('QR data was not fully blocked');
    }
    final result = List<int>.filled(raw, 0);
    var k = 0;
    for (var i = 0; i < parts[0].length; i++) {
      for (var j = 0; j < parts.length; j++) {
        if (i != shortLen - blockEcc || j >= shortBlocks) {
          result[k++] = parts[j][i];
        }
      }
    }
    if (k != raw) {
      throw StateError('QR interleave length mismatch');
    }
    return result;
  }

  static void _drawCodewords(
    List<List<bool>> modules,
    List<List<bool>> function,
    List<int> data,
    int size,
  ) {
    var i = 0;
    for (var right = size - 1; right >= 1; right -= 2) {
      if (right == 6) {
        right = 5;
      }
      for (var vert = 0; vert < size; vert++) {
        for (var j = 0; j < 2; j++) {
          final x = right - j;
          final upward = ((right + 1) & 2) == 0;
          final y = upward ? size - 1 - vert : vert;
          if (!function[y][x] && i < data.length * 8) {
            modules[y][x] = _bit(data[i >> 3], 7 - (i & 7));
            i++;
          }
        }
      }
    }
  }

  static void _mask(
    List<List<bool>> modules,
    List<List<bool>> function,
    int size,
  ) {
    for (var y = 0; y < size; y++) {
      for (var x = 0; x < size; x++) {
        if (!function[y][x] && (x + y).isEven) {
          modules[y][x] = !modules[y][x];
        }
      }
    }
  }

  static int _dataCodewords(int version) =>
      _rawCodewords(version) - _eccPerBlock[version] * _blockCount[version];

  static int _rawCodewords(int version) {
    final size = version * 4 + 17;
    var result = size * size;
    result -= 8 * 8 * 3;
    result -= 15 * 2 + 1;
    result -= (size - 16) * 2;
    if (version >= 2) {
      final count = version ~/ 7 + 2;
      result -= (count - 1) * (count - 1) * 25;
      result -= (count - 2) * 2 * 20;
      if (version >= 7) {
        result -= 36;
      }
    }
    return result ~/ 8;
  }

  static List<int> _rsDivisor(int degree) {
    final result = List<int>.filled(degree, 0);
    result[degree - 1] = 1;
    var root = 1;
    for (var i = 0; i < degree; i++) {
      for (var j = 0; j < result.length; j++) {
        result[j] = _rsMul(result[j], root);
        if (j + 1 < result.length) {
          result[j] ^= result[j + 1];
        }
      }
      root = _rsMul(root, 0x02);
    }
    return result;
  }

  static List<int> _rsRemainder(List<int> data, List<int> divisor) {
    final result = List<int>.filled(divisor.length, 0);
    for (final byte in data) {
      final factor = (byte ^ result[0]) & 0xff;
      for (var i = 0; i < result.length - 1; i++) {
        result[i] = result[i + 1];
      }
      result[result.length - 1] = 0;
      for (var i = 0; i < result.length; i++) {
        result[i] ^= _rsMul(divisor[i], factor);
      }
    }
    return result;
  }

  static int _rsMul(int x, int y) {
    var z = 0;
    for (var i = 7; i >= 0; i--) {
      z = ((z << 1) ^ ((z >>> 7) * 0x11d)) & 0xff;
      z ^= ((y >>> i) & 1) * x;
    }
    return z & 0xff;
  }

  // Medium ECC, index by version. Version 0 is unused.
  static const _eccPerBlock = <int>[
    -1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, //
  ];
  static const _blockCount = <int>[-1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5];
}
