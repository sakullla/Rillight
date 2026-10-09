import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

// Independent of the FFmpeg SDK: cache isolates and host tests use the same
// CPU dispatch as the shipped application.
void main(List<String> args) async {
  await build(args, (input, output) async {
    await CBuilder.library(
      name: 'rillight_crc32',
      assetName: 'src/crc32_bindings.dart',
      sources: ['native/checksum/crc32.c', 'native/cache/directory.c'],
      std: 'c11',
    ).run(input: input, output: output);
    output.dependencies.add(
      input.packageRoot.resolve('native/checksum/crc32_pclmul.h'),
    );
  });
}
