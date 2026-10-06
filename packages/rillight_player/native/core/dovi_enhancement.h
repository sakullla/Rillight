#pragma once

#include <cstddef>
#include <cstdint>
#include <vector>

// Profile 7 FEL stores the enhancement HEVC access unit in the base packet as
// NAL type 63, or as a second HEVC track. This only unwraps the interleaved
// form into Annex B. A dual-track packet is already a decodable HEVC packet.
namespace rillight_dovi {
inline int HevcNalLengthSize(const uint8_t* extradata, int size) {
  // HEVCDecoderConfigurationRecord: lengthSizeMinusOne is the low two bits
  // of byte 21. Anything that is not an hvcC is treated as Annex B.
  if (!extradata || size < 22 || extradata[0] != 1) return 0;
  return (extradata[21] & 3) + 1;
}

inline bool HevcNalHeader(const uint8_t* data, size_t size) {
  if (!data || size < 2 || (data[0] & 0x80)) return false;
  const int type = (data[0] >> 1) & 0x3f;
  const int temporal = data[1] & 7;
  return temporal != 0 && type < 63;
}

template <typename Fn>
inline bool ForEachHevcNal(const uint8_t* data, size_t size, int nal_length_size, Fn visit) {
  if (!data || !size || nal_length_size < 0 || nal_length_size > 4) return false;
  if (nal_length_size) {
    size_t offset = 0;
    while (offset < size) {
      if (size - offset < static_cast<size_t>(nal_length_size)) return false;
      uint32_t length = 0;
      for (int i = 0; i < nal_length_size; ++i)
        length = (length << 8) | data[offset++];
      if (!length || length > size - offset) return false;
      if (length >= 2) visit(data + offset, static_cast<size_t>(length));
      offset += length;
    }
    return true;
  }
  auto start_at = [&](size_t offset, size_t* code) -> size_t {
    for (size_t i = offset; i + 3 <= size; ++i) {
      if (data[i] || data[i + 1]) continue;
      if (data[i + 2] == 1) {
        *code = 3;
        return i;
      }
      if (i + 4 <= size && !data[i + 2] && data[i + 3] == 1) {
        *code = 4;
        return i;
      }
    }
    return size;
  };
  size_t code = 0;
  size_t start = start_at(0, &code);
  if (start == size) return false;
  while (start < size) {
    const size_t nal = start + code;
    size_t next_code = 0;
    const size_t next = start_at(nal, &next_code);
    if (next > nal) visit(data + nal, next - nal);
    start = next;
    code = next_code;
  }
  return true;
}

inline void AppendAnnexB(std::vector<uint8_t>* out, const uint8_t* nal, size_t size) {
  if (!out || !HevcNalHeader(nal, size) || out->size() > 32u * 1024u * 1024u) return;
  static const uint8_t kStart[4] = {0, 0, 0, 1};
  out->insert(out->end(), kStart, kStart + 4);
  out->insert(out->end(), nal, nal + size);
}

// True when the packet is well framed. *annexb is empty when the packet has
// no wrapped enhancement NAL. False means the framing is unusable.
inline bool ExtractInterleavedEnhancement(const uint8_t* data, size_t size,
                                          int nal_length_size,
                                          std::vector<uint8_t>* annexb) {
  if (!annexb) return false;
  annexb->clear();
  if (!data || !size) return true;
  bool framed = ForEachHevcNal(data, size, nal_length_size, [&](const uint8_t* nal, size_t nal_size) {
    const int type = (nal[0] >> 1) & 0x3f;
    if (type != 63 || nal_size <= 2) return;
    const uint8_t* payload = nal + 2;
    const size_t payload_size = nal_size - 2;
    const bool inner_annexb = payload_size >= 4 && !payload[0] && !payload[1] &&
                              (payload[2] == 1 || (!payload[2] && payload[3] == 1));
    if (inner_annexb) {
      ForEachHevcNal(payload, payload_size, 0, [&](const uint8_t* inner, size_t inner_size) {
        AppendAnnexB(annexb, inner, inner_size);
      });
      return;
    }
    AppendAnnexB(annexb, payload, payload_size);
  });
  if (!framed) annexb->clear();
  return framed;
}
}  // namespace rillight_dovi
