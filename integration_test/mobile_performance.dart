// Validation entry point. Launch with `flutter run -t` on a real phone or TV,
// then `adb forward tcp:8798 tcp:8798`. POST /begin with label, cache=cold or
// warm, device, build, and exact visible contentKey/actionKey before navigation.
// Poll GET /state and append POST /end JSON to a baseline or candidate JSONL.
// Repeat each scenario in the same build mode; keep cold/warm samples separate.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:rillight/app/tv_widgets.dart';
import 'package:rillight/main.dart' as production;

final _probe = _PageProbe();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _probe.start();
  await production.main([]);
}

class _PageProbe {
  final Stopwatch _clock = Stopwatch();
  String? _label, _cacheMode, _contentKey, _actionKey, _device, _buildId;
  double? _contentMs, _operableMs;
  bool _active = false;

  Future<void> start() async {
    WidgetsBinding.instance.addPersistentFrameCallback((_) {
      if (!_active || (_contentMs != null && _operableMs != null)) return;
      WidgetsBinding.instance.addPostFrameCallback((_) => _sample());
    });
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 8798);
    server.listen((request) async {
      try {
        if (request.method == 'POST' && request.uri.path == '/begin') {
          final q = request.uri.queryParameters;
          if (!{'cold', 'warm'}.contains(q['cache']) ||
              (q['label'] ?? '').isEmpty ||
              (q['device'] ?? '').isEmpty ||
              (q['build'] ?? '').isEmpty ||
              (q['contentKey'] ?? '').isEmpty ||
              (q['actionKey'] ?? '').isEmpty) {
            request.response.statusCode = HttpStatus.badRequest;
            request.response.write(
              'label, cache, device, build, contentKey and actionKey required',
            );
          } else {
            _label = q['label'];
            _cacheMode = q['cache'];
            _device = q['device'];
            _buildId = q['build'];
            _contentKey = q['contentKey'];
            _actionKey = q['actionKey'];
            _contentMs = _operableMs = null;
            _clock
              ..reset()
              ..start();
            _active = true;
            request.response.write(jsonEncode(_record()));
          }
        } else if (request.method == 'GET' && request.uri.path == '/state') {
          request.response.write(jsonEncode(_record()));
        } else if (request.method == 'POST' && request.uri.path == '/end') {
          _active = false;
          _clock.stop();
          request.response.write(jsonEncode(_record()));
        } else {
          request.response.statusCode = HttpStatus.notFound;
        }
      } catch (error) {
        request.response.statusCode = HttpStatus.internalServerError;
        request.response.write(error.toString());
      }
      await request.response.close();
    });
  }

  Map<String, Object?> _record() {
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    return {
      'label': _label,
      'cache': _cacheMode,
      'device': _device,
      'build': _buildId,
      'platform': Platform.operatingSystem,
      'buildMode': kReleaseMode
          ? 'release'
          : kProfileMode
          ? 'profile'
          : 'debug',
      'physicalSize': [view.physicalSize.width, view.physicalSize.height],
      'pixelRatio': view.devicePixelRatio,
      'contentKey': _contentKey,
      'actionKey': _actionKey,
      'firstContentMs': _contentMs,
      'firstOperableMs': _operableMs,
      'elapsedMs': _clock.elapsedMicroseconds / 1000,
      'complete': _contentMs != null && _operableMs != null,
    };
  }

  void _sample() {
    if (!_active) return;
    if (_clock.elapsed > const Duration(seconds: 20)) {
      _active = false;
      return;
    }
    final root = WidgetsBinding.instance.rootElement;
    if (root == null) return;
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    final viewport = Offset.zero & (view.physicalSize / view.devicePixelRatio);
    void visit(Element element) {
      final widget = element.widget;
      if (widget is Offstage && widget.offstage) return;
      final key = widget.key;
      if (key is ValueKey<String>) {
        final render = element.findRenderObject();
        if (render is RenderBox && render.attached && render.hasSize) {
          final rect = render.localToGlobal(Offset.zero) & render.size;
          if (rect.overlaps(viewport)) {
            final ms = _clock.elapsedMicroseconds / 1000;
            if (_contentMs == null && key.value == _contentKey) {
              _contentMs = ms;
            }
            if (_operableMs == null &&
                key.value == _actionKey &&
                _enabled(widget)) {
              _operableMs = ms;
            }
          }
        }
      }
      if (element is RenderObjectElement &&
          element.renderObject is RenderIndexedStack) {
        final stack = element.renderObject as RenderIndexedStack;
        var index = 0;
        element.visitChildren((child) {
          if (index++ == stack.index) visit(child);
        });
      } else {
        element.visitChildren(visit);
      }
    }

    visit(root);
  }

  bool _enabled(Widget widget) => switch (widget) {
    ButtonStyleButton(:final onPressed) => onPressed != null,
    IconButton(:final onPressed) => onPressed != null,
    TvAction(:final onPressed) => onPressed != null,
    InkWell(:final onTap) => onTap != null,
    GestureDetector(:final onTap) => onTap != null,
    _ => true,
  };
}
