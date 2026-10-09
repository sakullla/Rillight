// Synthetic differential probe: length-prefixed access units in, IEC bursts out.
#include "../../core/iec61937_pack.h"
#include <cstdio>
#include <fstream>
#include <string>

int main(int argc, char** argv) {
  if (argc != 4) return 2;
  std::ifstream input(argv[2], std::ios::binary);
  std::ofstream output(argv[3], std::ios::binary);
  RillightIec61937Mux mux;
  const std::string kind = argv[1];
  while (input.peek() != EOF) {
    uint32_t size = 0;
    if (!input.read(reinterpret_cast<char*>(&size), sizeof(size)) || size > 1024 * 1024) return 3;
    std::vector<uint8_t> packet(size), burst;
    if (!input.read(reinterpret_cast<char*>(packet.data()), size)) return 4;
    const int result = kind == "ac3" ? mux.push_ac3(packet.data(), size, &burst)
        : kind == "eac3" ? mux.push_eac3(packet.data(), size, &burst)
        : kind == "truehd" ? mux.push_truehd(packet.data(), size, &burst)
        : mux.push_dts(packet.data(), size, kind == "dtshd", &burst);
    if (result < 0) return 5;
    if (result > 0) output.write(reinterpret_cast<const char*>(burst.data()), burst.size());
  }
  return output ? 0 : 6;
}
