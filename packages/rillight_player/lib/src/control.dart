import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import 'bindings.dart';

void controlMain((SendPort, Map<String, String>, String?) arguments) {
  final (output, options, libraryPath) = arguments;
  MpvBindings? api;
  Pointer<MpvHandle> handle = nullptr;
  NativeCallable<Wakeup>? callback;
  final input = ReceivePort();
  // Publish cancellation transport before entering native initialization.
  output.send({'bootstrap': input.sendPort});
  var disposed = false;
  var drainScheduled = false;

  void drain() {
    drainScheduled = false;
    if (disposed) return;
    // Bounded batch: close requests cannot be starved by property storms.
    for (var i = 0; i < 128; i++) {
      final event = api!.waitEvent(handle, 0).ref;
      if (event.id == 0) return;
      Object? value;
      String? property;
      if ((event.id == 3 || event.id == 22) && event.data != nullptr) {
        final data = event.data.cast<NativeProperty>().ref;
        property = data.name.toDartString();
        if (data.format == 6 && data.data != nullptr) {
          value = copyNode(data.data.cast<NativeNode>().ref);
        }
      } else if (event.id == 7 && event.data != nullptr) {
        final end = event.data.cast<NativeEnd>().ref;
        value = {'reason': end.reason, 'error': end.error};
      }
      output.send({
        'event': event.id,
        'reply': event.reply,
        'error': event.error < 0
            ? api.errorString(event.error).toDartString()
            : null,
        'property': property,
        'value': value,
      });
    }
    drainScheduled = true;
    Timer.run(drain);
  }

  void onWakeup(Pointer<Void> _) {
    if (!disposed && !drainScheduled) {
      drainScheduled = true;
      Timer.run(drain);
    }
  }

  try {
    api = MpvBindings(libraryPath);
    handle = api.create();
    if (handle == nullptr) throw StateError('mpv_create failed');
    using((arena) {
      final effective = <String, String>{
        'vo': 'libmpv',
        'idle': 'yes',
        'keep-open': 'yes',
        'terminal': 'no',
        'input-default-bindings': 'no',
        'input-vo-keyboard': 'no',
        'hwdec': 'auto-copy',
        ...options,
        // Surfaces use BLOCK_FOR_TARGET_TIME=0 so close never waits inside
        // libmpv's presentation sleep. Disable the corresponding early lead
        // rather than publishing audio-timed video up to 50 ms too soon.
        'video-timing-offset': '0',
      };
      for (final entry in effective.entries) {
        api!.check(
          api.option(
            handle,
            entry.key.toNativeUtf8(allocator: arena),
            entry.value.toNativeUtf8(allocator: arena),
          ),
        );
      }
      api!.check(api.initialize(handle));
      for (final property in [
        'time-pos',
        'duration',
        'demuxer-cache-time',
        'pause',
        'paused-for-cache',
        'core-idle',
        'eof-reached',
        'track-list',
        'width',
        'height',
        'volume',
        'speed',
      ]) {
        api.check(
          api.observe(handle, 0, property.toNativeUtf8(allocator: arena), 6),
        );
      }
    });
    callback = NativeCallable<Wakeup>.listener(onWakeup);
    api.wakeup(handle, callback.nativeFunction, nullptr);
    output.send({
      'ready': input.sendPort,
      'handle': handle.address,
      'api': api.version(),
    });
    input.listen((dynamic raw) {
      final message = raw as Map;
      final id = message['id'] as int;
      if (message['op'] == 'dispose') {
        disposed = true;
        api!.wakeup(handle, nullptr, nullptr);
        api.destroy(handle);
        handle = nullptr;
        // Queued listener invocations may still arrive: disposed guards them.
        Timer.run(() {
          callback!.close();
          input.close();
          output.send({'reply': id, 'disposed': true});
        });
        return;
      }
      if (disposed) return;
      try {
        using((arena) {
          switch (message['op']) {
            case 'command':
              final args = (message['args'] as List).cast<String>();
              final pointers = arena<Pointer<Utf8>>(args.length + 1);
              for (var i = 0; i < args.length; i++) {
                pointers[i] = args[i].toNativeUtf8(allocator: arena);
              }
              api!.check(api.command(handle, id, pointers));
            case 'set':
              final value = arena<Pointer<Utf8>>();
              value.value = (message['value'] as String).toNativeUtf8(
                allocator: arena,
              );
              api!.check(
                api.setProperty(
                  handle,
                  id,
                  (message['name'] as String).toNativeUtf8(allocator: arena),
                  1,
                  value.cast(),
                ),
              );
            case 'get':
              api!.check(
                api.getProperty(
                  handle,
                  id,
                  (message['name'] as String).toNativeUtf8(allocator: arena),
                  6,
                ),
              );
          }
        });
      } catch (error) {
        output.send({'reply': id, 'error': error.toString()});
      }
    });
  } catch (error) {
    disposed = true;
    if (handle != nullptr) api?.destroy(handle);
    callback?.close();
    input.close();
    output.send({'fatal': error.toString()});
  }
}
