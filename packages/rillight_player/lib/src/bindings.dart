import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

final class MpvHandle extends Opaque {}

final class NativeEvent extends Struct {
  @Int32()
  external int id;
  @Int32()
  external int error;
  @Uint64()
  external int reply;
  external Pointer<Void> data;
}

final class NativeProperty extends Struct {
  external Pointer<Utf8> name;
  @Int32()
  external int format;
  external Pointer<Void> data;
}

final class NativeEnd extends Struct {
  @Int32()
  external int reason;
  @Int32()
  external int error;
}

final class NativeNodeValue extends Union {
  external Pointer<Utf8> string;
  @Int32()
  external int flag;
  @Int64()
  external int integer;
  @Double()
  external double number;
  external Pointer<NativeNodeList> list;
}

final class NativeNode extends Struct {
  external NativeNodeValue value;
  @Int32()
  external int format;
}

final class NativeNodeList extends Struct {
  @Int32()
  external int count;
  external Pointer<NativeNode> values;
  external Pointer<Pointer<Utf8>> keys;
}

typedef Wakeup = Void Function(Pointer<Void>);

/// Only constructed and called by the dedicated control isolate.
class MpvBindings {
  MpvBindings(String? path) : library = _open(path) {
    final major = version() >> 16;
    if (major != 2) throw StateError('Unsupported libmpv client API: $major');
    // Resolve the complete required ABI before allocating a core.
    create;
    initialize;
    option;
    command;
    setProperty;
    getProperty;
    observe;
    waitEvent;
    wakeup;
    destroy;
    errorString;
  }

  final DynamicLibrary library;
  static DynamicLibrary _open(String? path) {
    if (path != null) return DynamicLibrary.open(path);
    if (Platform.isWindows) {
      return DynamicLibrary.open(
        '${File(Platform.resolvedExecutable).parent.path}/libmpv-2.dll',
      );
    }
    if (Platform.isMacOS) {
      final contents = File(Platform.resolvedExecutable).parent.parent;
      return DynamicLibrary.open('${contents.path}/Frameworks/libmpv.2.dylib');
    }
    final bundled = File(
      '${File(Platform.resolvedExecutable).parent.path}/lib/libmpv.so.2',
    );
    return DynamicLibrary.open(
      bundled.existsSync() ? bundled.path : 'libmpv.so.2',
    );
  }

  late final version = library
      .lookupFunction<UnsignedLong Function(), int Function()>(
        'mpv_client_api_version',
      );
  late final create = library
      .lookupFunction<
        Pointer<MpvHandle> Function(),
        Pointer<MpvHandle> Function()
      >('mpv_create');
  late final initialize = library
      .lookupFunction<
        Int32 Function(Pointer<MpvHandle>),
        int Function(Pointer<MpvHandle>)
      >('mpv_initialize');
  late final option = library
      .lookupFunction<
        Int32 Function(Pointer<MpvHandle>, Pointer<Utf8>, Pointer<Utf8>),
        int Function(Pointer<MpvHandle>, Pointer<Utf8>, Pointer<Utf8>)
      >('mpv_set_option_string');
  late final command = library
      .lookupFunction<
        Int32 Function(Pointer<MpvHandle>, Uint64, Pointer<Pointer<Utf8>>),
        int Function(Pointer<MpvHandle>, int, Pointer<Pointer<Utf8>>)
      >('mpv_command_async');
  late final setProperty = library
      .lookupFunction<
        Int32 Function(
          Pointer<MpvHandle>,
          Uint64,
          Pointer<Utf8>,
          Int32,
          Pointer<Void>,
        ),
        int Function(Pointer<MpvHandle>, int, Pointer<Utf8>, int, Pointer<Void>)
      >('mpv_set_property_async');
  late final getProperty = library
      .lookupFunction<
        Int32 Function(Pointer<MpvHandle>, Uint64, Pointer<Utf8>, Int32),
        int Function(Pointer<MpvHandle>, int, Pointer<Utf8>, int)
      >('mpv_get_property_async');
  late final observe = library
      .lookupFunction<
        Int32 Function(Pointer<MpvHandle>, Uint64, Pointer<Utf8>, Int32),
        int Function(Pointer<MpvHandle>, int, Pointer<Utf8>, int)
      >('mpv_observe_property');
  late final waitEvent = library
      .lookupFunction<
        Pointer<NativeEvent> Function(Pointer<MpvHandle>, Double),
        Pointer<NativeEvent> Function(Pointer<MpvHandle>, double)
      >('mpv_wait_event');
  late final wakeup = library
      .lookupFunction<
        Void Function(
          Pointer<MpvHandle>,
          Pointer<NativeFunction<Wakeup>>,
          Pointer<Void>,
        ),
        void Function(
          Pointer<MpvHandle>,
          Pointer<NativeFunction<Wakeup>>,
          Pointer<Void>,
        )
      >('mpv_set_wakeup_callback');
  late final destroy = library
      .lookupFunction<
        Void Function(Pointer<MpvHandle>),
        void Function(Pointer<MpvHandle>)
      >('mpv_terminate_destroy');
  late final errorString = library
      .lookupFunction<
        Pointer<Utf8> Function(Int32),
        Pointer<Utf8> Function(int)
      >('mpv_error_string');

  void check(int code) {
    if (code < 0) throw StateError(errorString(code).toDartString());
  }
}

/// Deep-copy borrowed event memory before calling mpv_wait_event again.
Object? copyNode(NativeNode node) {
  switch (node.format) {
    case 1:
      return node.value.string.toDartString();
    case 3:
      return node.value.flag != 0;
    case 4:
      return node.value.integer;
    case 5:
      return node.value.number;
    case 7:
      final list = node.value.list.ref;
      return List<Object?>.generate(
        list.count,
        (i) => copyNode(list.values[i]),
      );
    case 8:
      final list = node.value.list.ref;
      return <String, Object?>{
        for (var i = 0; i < list.count; i++)
          list.keys[i].toDartString(): copyNode(list.values[i]),
      };
    default:
      return null;
  }
}
