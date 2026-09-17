import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rillight_player/src/bindings.dart';

void main() {
  test('event node values survive borrowed native memory being freed', () {
    final node = calloc<NativeNode>();
    final list = calloc<NativeNodeList>();
    final values = calloc<NativeNode>(2);
    final keys = calloc<Pointer<Utf8>>(2);
    final title = '中文字幕'.toNativeUtf8();
    keys[0] = 'title'.toNativeUtf8();
    keys[1] = 'id'.toNativeUtf8();
    values[0].format = 1;
    values[0].value.string = title;
    values[1].format = 4;
    values[1].value.integer = 42;
    list.ref.count = 2;
    list.ref.values = values;
    list.ref.keys = keys;
    node.ref.format = 8;
    node.ref.value.list = list;
    final copied = copyNode(node.ref);
    calloc.free(title);
    calloc.free(keys[0]);
    calloc.free(keys[1]);
    calloc.free(keys);
    calloc.free(values);
    calloc.free(list);
    calloc.free(node);
    expect(copied, {'title': '中文字幕', 'id': 42});
  });
}
