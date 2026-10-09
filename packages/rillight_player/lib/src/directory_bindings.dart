import 'dart:ffi';

final class NativeDirectoryEntry extends Struct {
  @Int64()
  external int size;
  @Int64()
  external int modifiedMicros;
  @Int64()
  external int changedMicros;
  @Int32()
  external int kind;
  @Array(256)
  external Array<Uint8> name;
}

@Native<Int32 Function(Pointer<Char>, Pointer<NativeDirectoryEntry>, Int32)>(
  symbol: 'rillight_read_directory',
  assetId: 'package:rillight_player/src/crc32_bindings.dart',
)
external int nativeReadDirectory(
  Pointer<Char> path,
  Pointer<NativeDirectoryEntry> entries,
  int capacity,
);
