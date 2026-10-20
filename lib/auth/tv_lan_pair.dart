import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:rillight/app/ui/ui.dart';
import 'package:rillight/auth/auth_controller.dart';

/// 电视主动开启的一次性局域网辅助连接。
///
/// 只在用户打开时于本进程启动临时 HTTP,不发现设备、不访问公网。
/// 二维码和地址只含源、端口和配对号。手机提交后须遥控器确认
/// 才会调用 [AuthController.connect];拒绝、过期、取消、返回和未配对请求不建立会话。
/// 返回时正在等待的手机收到失败页；连接中已经确定的成败仍写给手机。
class TvLanAssist extends ChangeNotifier {
  TvLanAssist({
    this.lifetime = const Duration(minutes: 20),
    this.phoneGrace = const Duration(seconds: 2),
    this._bindAddress,
    this.advertiseHost,
    Random? random,
  }) : _random = random ?? Random.secure();

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
    return TvLanSubmission(
      server: held.server,
      account: held.account,
      userAgent: held.userAgent,
    );
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
      final pairingId = _pairingId();
      final server = await HttpServer.bind(
        _bindAddress ?? InternetAddress.anyIPv4,
        0,
      );
      if (_disposed) {
        await server.close(force: true);
        return;
      }
      _server = server;
      final manual = Uri(
        scheme: 'http',
        host: host,
        port: server.port,
        path: '/',
        queryParameters: {'id': pairingId},
      );
      final qrText = manual.toString();
      _offer = TvLanOffer(
        manualUrl: qrText,
        qrText: qrText,
        pairingId: pairingId,
        port: server.port,
        host: host,
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
        userAgent: held.userAgent,
        preserveSessionOnFailure: true,
      );
    } finally {
      // 页面已经返回时也要把这次确定的结果页写给手机，再关闭。
      _phase = accepted ? TvLanPhase.confirmed : TvLanPhase.failed;
      _pending = null;
      _notify();
      await _deliverFinalThenClose();
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

  /// 用户结束辅助,不登录。
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
    // 连接中不关闭：confirm 会把已经确定的页面交给手机，再关套接字。
    if (_phase != TvLanPhase.connecting) {
      if (_phase == TvLanPhase.pending) {
        _wipe();
        _phase = TvLanPhase.cancelled;
        unawaited(_deliverFinalThenClose());
      } else {
        if (_phase == TvLanPhase.waiting) {
          _wipe();
          _phase = TvLanPhase.cancelled;
        }
        unawaited(_shutdown());
      }
    }
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

  String _pairingId() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
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
    final offer = _offer;
    if (offer == null || id == null || !_same(id, offer.pairingId)) {
      await _reply(request, HttpStatus.notFound, _phoneMessage('无法使用此连接。'));
      return;
    }
    final path = request.uri.path.isEmpty ? '/' : request.uri.path;
    if (request.method == 'GET' && (path == '/' || path == '/status')) {
      if (_phase == TvLanPhase.waiting && path == '/') {
        await _reply(
          request,
          HttpStatus.ok,
          _phoneForm(pairingId: offer.pairingId),
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
    final userAgent = (form['userAgent'] ?? '').trim();
    if (address.isEmpty ||
        username.isEmpty ||
        address.length > 512 ||
        username.length > 256 ||
        password.length > 256 ||
        userAgent.length > 1024 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(userAgent)) {
      _reserved = false;
      await _reply(request, HttpStatus.badRequest, _phoneMessage('请填写服务器和账号。'));
      return;
    }
    _pending = _HeldSubmission(
      server: address,
      account: username,
      userAgent: userAgent.isEmpty ? null : userAgent,
    );
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
    return '/status?id=${offer.pairingId}';
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
    required this.pairingId,
    required this.port,
    required this.host,
    required this.qrModules,
  });

  final String manualUrl;
  final String qrText;
  final String pairingId;
  final int port;
  final String host;
  final List<List<bool>> qrModules;
}

class TvLanSubmission {
  const TvLanSubmission({
    required this.server,
    required this.account,
    this.userAgent,
  });

  final String server;
  final String account;
  final String? userAgent;
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
  const _HeldSubmission({
    required this.server,
    required this.account,
    this.userAgent,
  });

  final String server;
  final String account;
  final String? userAgent;
}

class _QrPainter extends CustomPainter {
  const _QrPainter(this.modules);

  final List<List<bool>> modules;

  @override
  void paint(Canvas canvas, Size size) {
    final count = modules.length;
    const quiet = 4;
    final scale = size.shortestSide / (count + quiet * 2);
    canvas.drawRect(Offset.zero & size, Paint()..color = AppInk.white);
    final paint = Paint()..color = AppInk.black;
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

/// 手机页共用样式:纯内联 CSS,无脚本、无外部资源,弱网与旧浏览器可用。
const String _phoneCss = '''
:root{color-scheme:dark}
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:-apple-system,"PingFang SC","Hiragino Sans GB","Microsoft YaHei",sans-serif;
background:linear-gradient(160deg,#0d1420 0%,#101726 55%,#0b0f16 100%);
color:#e8ecf4;min-height:100vh;display:flex;justify-content:center;align-items:flex-start;
padding:32px 16px}
.card{width:100%;max-width:420px;background:rgba(255,255,255,.05);
border:1px solid rgba(255,255,255,.09);border-radius:20px;padding:28px 24px 24px}
.brand{display:flex;align-items:center;gap:10px;margin-bottom:6px}
.logo{width:34px;height:34px;border-radius:10px;flex:none;
background:linear-gradient(135deg,#6d8dff,#9a6dff);color:#fff;
display:flex;align-items:center;justify-content:center;font-size:17px;font-weight:800}
h1{font-size:23px;font-weight:800}
.sub{color:#9aa4b8;font-size:14px;line-height:1.5;margin-bottom:20px}
label{display:block;font-size:14px;color:#c6cddc;margin-bottom:6px}
input{display:block;width:100%;box-sizing:border-box;background:rgba(0,0,0,.32);
border:1px solid rgba(255,255,255,.12);border-radius:12px;padding:13px 14px;
font-size:16px;color:#eef1f7;margin-bottom:16px;outline:none}
input:focus{border-color:#6d8dff;box-shadow:0 0 0 3px rgba(109,141,255,.22)}
button{display:block;width:100%;border:0;border-radius:12px;padding:14px;margin-top:4px;
font-size:16px;font-weight:700;color:#0b1020;cursor:pointer;
background:linear-gradient(135deg,#8ba4ff,#b18cff)}
button:active{transform:scale(.985)}
.note{margin-top:14px;font-size:12px;color:#7d8698;text-align:center;line-height:1.6}
.status{text-align:center;padding:12px 0 4px}
.icon{width:64px;height:64px;margin:0 auto 18px;border-radius:50%;
display:flex;align-items:center;justify-content:center}
.ok{background:rgba(84,211,145,.16)}
.err{background:rgba(255,107,107,.16)}
.wait{background:rgba(109,141,255,.16)}
.tick{width:13px;height:24px;border-right:5px solid #54d391;border-bottom:5px solid #54d391;
border-radius:2px;transform:rotate(45deg) translate(-2px,-2px)}
.cross{position:relative;width:26px;height:26px}
.cross::before,.cross::after{content:'';position:absolute;left:10.5px;top:0;width:5px;height:26px;
background:#ff6b6b;border-radius:2px}
.cross::before{transform:rotate(45deg)}
.cross::after{transform:rotate(-45deg)}
.dots{display:flex;gap:8px}
.dots i{width:9px;height:9px;border-radius:50%;background:#8ba4ff;animation:p 1.2s infinite}
.dots i:nth-child(2){animation-delay:.15s}
.dots i:nth-child(3){animation-delay:.3s}
@keyframes p{0%,60%,100%{opacity:.35}30%{opacity:1}}
.spin{width:44px;height:44px;margin:0 auto 18px;border-radius:50%;
border:3px solid rgba(139,164,255,.25);border-top-color:#8ba4ff;
animation:r 1s linear infinite}
@keyframes r{to{transform:rotate(360deg)}}
.detail{color:#9aa4b8;font-size:15px;line-height:1.6;margin-top:10px}
''';

const String _phoneHead = '''
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>灯川连接</title>
''';

String _phoneForm({required String pairingId}) {
  final id = _html(pairingId);
  return '''
<!DOCTYPE html>
<html lang="zh-CN">
<head>
$_phoneHead
<style>$_phoneCss</style>
</head>
<body>
<div class="card">
<div class="brand"><div class="logo">灯</div><h1>灯川 Rillight</h1></div>
<div class="sub">在手机上为电视登录 Emby 服务器,提交后回到电视确认。</div>
<form method="post" action="/submit?id=$id">
<label>服务器地址<input name="address" autocomplete="url" inputmode="url" placeholder="http://192.168.1.10:8096" required></label>
<label>用户名<input name="username" autocomplete="username" required></label>
<label>密码<input name="password" type="password" autocomplete="current-password"></label>
<label>User-Agent<input name="userAgent" autocomplete="off" autocapitalize="none" spellcheck="false" maxlength="1024" placeholder="可选，留空则使用默认"></label>
<button type="submit">提交到电视</button>
</form>
<div class="note">一次性配对,过期自动失效<br>本页不含脚本与外部资源</div>
</div>
</body>
</html>
''';
}

String _phoneMessage(String text) {
  return '''
<!DOCTYPE html>
<html lang="zh-CN">
<head>
$_phoneHead
<style>$_phoneCss</style>
</head>
<body>
<div class="card">
<div class="brand"><div class="logo">灯</div><h1>灯川 Rillight</h1></div>
<div class="status">
<div class="icon err"><div class="cross"></div></div>
<p class="detail">${_html(text)}</p>
</div>
</div>
</body>
</html>
''';
}

String _phoneStateFor(TvLanPhase phase, String refresh) {
  switch (phase) {
    case TvLanPhase.pending:
      return _phoneState(
        '待确认',
        '请在电视上确认这次连接。',
        '<div class="icon wait"><div class="dots"><i></i><i></i><i></i></div></div>',
        refresh: refresh,
      );
    case TvLanPhase.connecting:
      return _phoneState(
        '连接中',
        '正在连接服务器。',
        '<div class="spin"></div>',
        refresh: refresh,
      );
    case TvLanPhase.confirmed:
      return _phoneState(
        '成功',
        '电视已连接。',
        '<div class="icon ok"><div class="tick"></div></div>',
      );
    case TvLanPhase.rejected:
    case TvLanPhase.expired:
    case TvLanPhase.cancelled:
    case TvLanPhase.failed:
      return _phoneState(
        '失败',
        '连接未完成。',
        '<div class="icon err"><div class="cross"></div></div>',
      );
    case TvLanPhase.idle:
    case TvLanPhase.waiting:
      return _phoneMessage('无法使用此连接。');
  }
}

String _phoneState(
  String heading,
  String detail,
  String visual, {
  String? refresh,
}) {
  final next = refresh == null
      ? ''
      : '<meta http-equiv="refresh" content="0;url=${_html(refresh)}">';
  return '''
<!DOCTYPE html>
<html lang="zh-CN">
<head>
$_phoneHead
$next
<style>$_phoneCss</style>
</head>
<body>
<div class="card">
<div class="brand"><div class="logo">灯</div><h1>灯川 Rillight</h1></div>
<div class="status">
$visual
<h1>${_html(heading)}</h1>
<p class="detail">${_html(detail)}</p>
</div>
</div>
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
