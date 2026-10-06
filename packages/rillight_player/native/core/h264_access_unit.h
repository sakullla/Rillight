#pragma once

#include <cstddef>
#include <cstdint>

// Some Matroska muxers emit SEI/AUD/parameter-only AVC access units. FFmpeg
// can consume their metadata yet return INVALIDDATA because there is no picture.
// Only recognize well-framed non-picture NALs; malformed framing and every VCL
// type retain the ordinary decoder error path.
inline bool rillight_h264_non_picture(const uint8_t* data, size_t size,
                                      int nal_length_size) {
  if (!data || !size || nal_length_size < 0 || nal_length_size > 4) return false;
  auto metadata = [](uint8_t header) {
    const int type = header & 31;
    return !(header & 0x80) && type >= 6 && type <= 12;
  };
  if (nal_length_size) {
    size_t offset = 0;
    while (offset < size) {
      if (size - offset < static_cast<size_t>(nal_length_size)) return false;
      uint32_t length = 0;
      for (int i = 0; i < nal_length_size; ++i) length = (length << 8) | data[offset++];
      if (!length || length > size - offset || !metadata(data[offset])) return false;
      offset += length;
    }
    return true;
  }
  auto prefix = [&](size_t offset) -> size_t {
    if (size - offset >= 3 && !data[offset] && !data[offset + 1]) {
      if (data[offset + 2] == 1) return 3;
      if (size - offset >= 4 && !data[offset + 2] && data[offset + 3] == 1) return 4;
    }
    return 0;
  };
  size_t offset = 0;
  while (offset < size) {
    const size_t start = prefix(offset);
    if (!start || offset + start >= size || !metadata(data[offset + start])) return false;
    offset += start + 1;
    while (offset < size && !prefix(offset)) ++offset;
  }
  return true;
}
