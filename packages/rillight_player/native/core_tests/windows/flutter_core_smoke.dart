import 'dart:ffi';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

typedef _CreateNative = Pointer<Void> Function(Pointer<Utf8>);
typedef _CoreNative = Pointer<Void> Function(Pointer<Void>);
typedef _PlayNative = Int32 Function(Pointer<Void>);
typedef _MetricNative = Int64 Function(Pointer<Void>);
typedef _AudioNative = Int32 Function(Pointer<Void>);
typedef _DestroyNative = Void Function(Pointer<Void>);
typedef _IntDart = int Function(Pointer<Void>);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final library = DynamicLibrary.open('t4_smoke_helper.dll');
  final create = library.lookupFunction<_CreateNative, _CreateNative>(
    't4_smoke_create',
  );
  final core = library.lookupFunction<_CoreNative, _CoreNative>(
    't4_smoke_core',
  );
  final play = library.lookupFunction<_PlayNative, _IntDart>(
    't4_smoke_try_play',
  );
  final position = library.lookupFunction<_MetricNative, _IntDart>(
    't4_smoke_position',
  );
  final audio = library.lookupFunction<_AudioNative, _IntDart>(
    't4_smoke_audio_ready',
  );
  final destroy = library
      .lookupFunction<_DestroyNative, void Function(Pointer<Void>)>(
        't4_smoke_destroy',
      );
  const media = String.fromEnvironment(
    'RILLIGHT_SMOKE_MEDIA',
    defaultValue: 'build/player-validation/media/tracks.mkv',
  );
  final path = File(media).absolute.path;
  final pointer = path.toNativeUtf8();
  final session = create(pointer);
  malloc.free(pointer);
  if (session.address == 0) {
    stderr.writeln('T4_SMOKE_FAIL: native core open');
    exit(1);
  }
  runApp(_SmokeApp(session, core(session), play, position, audio, destroy));
}

class _SmokeApp extends StatefulWidget {
  const _SmokeApp(
    this.session,
    this.core,
    this.play,
    this.position,
    this.audio,
    this.destroy,
  );
  final Pointer<Void> session;
  final Pointer<Void> core;
  final int Function(Pointer<Void>) play;
  final int Function(Pointer<Void>) position;
  final int Function(Pointer<Void>) audio;
  final void Function(Pointer<Void>) destroy;

  @override
  State<_SmokeApp> createState() => _SmokeAppState();
}

class _SmokeAppState extends State<_SmokeApp> {
  static const _channel = MethodChannel('rillight_player');
  final _textureKey = GlobalKey();
  int? _textureId;
  int _frames = 0;
  int _hardware = 0;
  String _error = '';
  bool _capturing = false;
  bool? _textureChanged;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<Uint8List?> _capture(String name) async {
    await WidgetsBinding.instance.endOfFrame;
    final boundary = _textureKey.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary) return null;
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (bytes == null) return null;
    final result = bytes.buffer.asUint8List();
    await File('build/$name.png').writeAsBytes(result);
    return result;
  }

  Future<void> _run() async {
    try {
      _textureId = await _channel.invokeMethod<int>('create', {
        'handle': widget.core.address,
      });
      if (_textureId == null) throw StateError('no texture id');
      setState(() {});
      final deadline = DateTime.now().add(const Duration(seconds: 9));
      while (DateTime.now().isBefore(deadline)) {
        widget.play(widget.session);
        final status = await _channel.invokeMapMethod<String, dynamic>(
          'status',
          {'handle': widget.core.address},
        );
        _frames = (status?['frames'] as num?)?.toInt() ?? 0;
        _hardware = (status?['actualHardware'] as num?)?.toInt() ?? 0;
        _error = status?['error'] as String? ?? '';
        if (mounted) setState(() {});
        if (_frames >= 5 && !_capturing) {
          _capturing = true;
          try {
            final first = await _capture('windows_core_frame_a');
            await Future<void>.delayed(const Duration(milliseconds: 700));
            final second = await _capture('windows_core_frame_b');
            if (first != null && second != null) {
              _textureChanged = !listEquals(first, second);
            }
          } catch (error) {
            stdout.writeln('T4_CAPTURE_UNAVAILABLE: $error');
          }
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      final position = widget.position(widget.session);
      final audioReady = widget.audio(widget.session);
      final pass =
          _frames >= 5 &&
          position > 0 &&
          audioReady == 1 &&
          _error.isEmpty &&
          _textureChanged == true;
      stdout.writeln(
        'T4_SMOKE frames=$_frames position=$position '
        'audioReady=$audioReady hardware=$_hardware '
        'textureChanged=$_textureChanged error=$_error pass=$pass',
      );
      await _channel.invokeMethod<void>('dispose', {
        'handle': widget.core.address,
      });
      widget.destroy(widget.session);
      exit(pass ? 0 : 1);
    } catch (error, stack) {
      stderr.writeln('T4_SMOKE_FAIL: $error\n$stack');
      exit(1);
    }
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RepaintBoundary(
              key: _textureKey,
              child: SizedBox(
                width: 640,
                height: 360,
                child: _textureId == null
                    ? const ColoredBox(color: Colors.black)
                    : Texture(textureId: _textureId!),
              ),
            ),
            Text(
              'frames=$_frames hardware=$_hardware error=$_error',
              style: const TextStyle(color: Colors.white),
            ),
          ],
        ),
      ),
    ),
  );
}
