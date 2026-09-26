// Validation-only observer. Inputs still enter through Android adb/IME; this
// entrypoint does not replace authentication, routes, controllers or the core.
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:rillight/main.dart' as production;
import 'package:rillight/app/app.dart';
import 'package:rillight/player/mobile_player_page.dart';
import 'package:rillight/player/tv_player_page.dart';
import 'package:rillight/player/player_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 8799);
  server.listen((request) async {
    if (request.method != 'GET' || request.uri.path != '/state') {
      request.response.statusCode = HttpStatus.notFound;
    } else {
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(snapshot()));
    }
    await request.response.close();
  });
  await production.main([]);
}

Map<String, Object?> snapshot() {
  final rows = <Map<String, Object?>>[];
  final pages = <String>{};
  Map<String, Object?>? player;
  bool? tv, authenticated;
  final view = WidgetsBinding.instance.platformDispatcher.views.first;
  void visit(Element element) {
    final widget = element.widget;
    if (widget is Offstage && widget.offstage) return;
    if (widget is RillightApp) {
      tv = widget.environment.isTv;
      authenticated = widget.auth.isLoggedIn;
    }
    // Observe without registering inherited dependencies on arbitrary elements.
    // Offstage/IndexedStack filtering excludes inactive panes. Navigator may
    // retain covered routes, so the host awaits an exiting page's removal
    // before injecting the next navigation sequence.
    {
      final type = widget.runtimeType.toString();
      if (type.endsWith('Page') || type.endsWith('Shell')) pages.add(type);
      if (element is StatefulElement) {
        final state = element.state;
        final PlayerController? controller = switch (state) {
          MobilePlayerPageState() => state.controller,
          TvPlayerPageState() => state.controller,
          _ => null,
        };
        if (controller != null) {
          player = {
            'loading': controller.loading,
            'error': controller.error?.name,
            'playing': controller.isPlaying,
            'controls': controller.controlsVisible,
            'positionMs': controller.position.inMilliseconds,
            'released': controller.backgroundReleased,
            'audio': controller.audioStreamIndex,
            'subtitle': controller.subtitleStreamIndex,
          };
        }
      }
      final label = switch (widget) {
        Text() => widget.data,
        IconButton() => widget.tooltip,
        _ => null,
      };
      final key = widget.key is ValueKey<String>
          ? (widget.key! as ValueKey<String>).value
          : null;
      final focused = widget is Semantics && widget.properties.focused == true;
      if (key != null || label != null || focused) {
        final render = element.findRenderObject();
        if (render is RenderBox && render.attached && render.hasSize) {
          final rect = render.localToGlobal(Offset.zero) & render.size;
          if (rect.overlaps(
            Offset.zero & (view.physicalSize / view.devicePixelRatio),
          )) {
            rows.add({
              'key': key,
              'label': label,
              'focused': focused,
              'rect': [rect.left, rect.top, rect.right, rect.bottom],
            });
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

  final root = WidgetsBinding.instance.rootElement;
  if (root != null) visit(root);
  return {
    'tv': tv,
    'authenticated': authenticated,
    'pages': pages.toList(),
    'player': player,
    'rows': rows,
    'scale': view.devicePixelRatio,
    'size': [view.physicalSize.width, view.physicalSize.height],
    'lifecycle': WidgetsBinding.instance.lifecycleState?.name,
  };
}
