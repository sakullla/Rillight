import 'dart:ffi';

@Native<Uint32 Function(Uint32, Pointer<Uint8>, Size)>(symbol: 'rillight_crc32')
external int nativeCrc32(int previous, Pointer<Uint8> bytes, int length);

@Native<Uint32 Function(Uint32, Pointer<Uint8>, Size)>(
  symbol: 'rillight_crc32_software',
)
external int nativeCrc32Software(
  int previous,
  Pointer<Uint8> bytes,
  int length,
);

@Native<Int32 Function()>(symbol: 'rillight_crc32_backend')
external int nativeCrc32Backend();
