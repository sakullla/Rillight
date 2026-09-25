import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

typedef _CreateNative = Pointer<Void> Function(Pointer<Utf8>);
typedef _CoreNative = Pointer<Void> Function(Pointer<Void>);
typedef _FindNative = IntPtr Function(Pointer<Utf16>, Pointer<Utf16>);
typedef _FindDart = int Function(Pointer<Utf16>, Pointer<Utf16>);
typedef _WindowPidNative = Uint32 Function(IntPtr, Pointer<Uint32>);
typedef _WindowPidDart = int Function(int, Pointer<Uint32>);
typedef _PostNative = Int32 Function(IntPtr, Uint32, IntPtr, IntPtr);
typedef _PostDart = int Function(int, int, int, int);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final library = DynamicLibrary.open('t4_smoke_helper.dll');
  final create = library.lookupFunction<_CreateNative, _CreateNative>(
    't4_smoke_create',
  );
  final core = library.lookupFunction<_CoreNative, _CoreNative>(
    't4_smoke_core',
  );
  const media = String.fromEnvironment(
    'RILLIGHT_SMOKE_MEDIA',
    defaultValue: 'build/player-validation/media/tracks.mkv',
  );
  final path = File(media).absolute.path.toNativeUtf8();
  final session = create(path);
  malloc.free(path);
  if (session.address == 0) exit(2);
  runApp(
    const MaterialApp(
      home: Scaffold(body: Center(child: Text('Closing'))),
    ),
  );
  await WidgetsBinding.instance.endOfFrame;
  unawaited(
    const MethodChannel('rillight_player')
        .invokeMethod<int>('create', {'handle': core(session).address})
        .then<void>((_) {}, onError: (Object _) {}),
  );
  await Future<void>.delayed(const Duration(milliseconds: 20));
  final user32 = DynamicLibrary.open('user32.dll');
  final findWindow = user32.lookupFunction<_FindNative, _FindDart>(
    'FindWindowW',
  );
  final windowPid = user32.lookupFunction<_WindowPidNative, _WindowPidDart>(
    'GetWindowThreadProcessId',
  );
  final postMessage = user32.lookupFunction<_PostNative, _PostDart>(
    'PostMessageW',
  );
  final title = '灯川 Rillight'.toNativeUtf16();
  final window = findWindow(nullptr, title);
  malloc.free(title);
  final owner = calloc<Uint32>();
  if (window == 0 || windowPid(window, owner) == 0 || owner.value != pid) {
    stderr.writeln('T4_LIFECYCLE_FAIL: test window unavailable');
    calloc.free(owner);
    exit(3);
  }
  calloc.free(owner);
  stdout.writeln('T4_LIFECYCLE closing during native surface initialization');
  if (postMessage(window, 0x0010, 0, 0) == 0) exit(4);
  await Future<void>.delayed(const Duration(seconds: 3));
  stderr.writeln('T4_LIFECYCLE_FAIL: window did not close');
  exit(1);
}
