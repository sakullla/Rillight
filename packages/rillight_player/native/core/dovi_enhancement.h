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

struct HevcBits {
  const uint8_t* data = nullptr;
  size_t size = 0;
  size_t bit = 0;
  bool ok = true;
  int u(int count) {
    if (!ok || count < 0 || bit + static_cast<size_t>(count) > size * 8) {
      ok = false;
      return 0;
    }
    int value = 0;
    for (int i = 0; i < count; ++i) {
      const size_t pos = bit++;
      value = (value << 1) | ((data[pos / 8] >> (7 - (pos % 8))) & 1);
    }
    return value;
  }
  uint32_t ubits(int count) {
    uint32_t value = 0;
    for (int i = 0; i < count; ++i) {
      const int bit_value = u(1);
      if (!ok) return 0;
      value = (value << 1) | static_cast<uint32_t>(bit_value);
    }
    return value;
  }
  void skip(int count) {
    while (ok && count > 0) {
      const int step = count > 16 ? 16 : count;
      u(step);
      count -= step;
    }
  }
  int ue() {
    int zeros = 0;
    while (ok) {
      const int bit_value = u(1);
      if (!ok) return 0;
      if (bit_value) break;
      if (++zeros > 16) {
        ok = false;
        return 0;
      }
    }
    if (!ok) return 0;
    const uint32_t extra = zeros ? ubits(zeros) : 0;
    return static_cast<int>(((1u << zeros) - 1u) + extra);
  }
  int se() {
    const int code = ue();
    if (!ok) return 0;
    return (code & 1) ? (code + 1) / 2 : -(code / 2);
  }
};

inline std::vector<uint8_t> RbspPayload(const uint8_t* data, size_t size) {
  std::vector<uint8_t> out;
  if (!data || !size) return out;
  out.reserve(size);
  for (size_t i = 0; i < size; ++i) {
    if (i + 2 < size && !data[i] && !data[i + 1] && data[i + 2] == 3) {
      out.push_back(0);
      out.push_back(0);
      i += 2;
      continue;
    }
    out.push_back(data[i]);
  }
  return out;
}

inline bool LooksLikeVps(const uint8_t* rbsp, size_t size) {
  if (!rbsp || size < 4) return false;
  HevcBits bits{rbsp, size};
  bits.u(4);
  bits.u(2);
  const int layers = bits.u(6);
  const int sublayers = bits.u(3);
  bits.u(1);
  const int reserved = bits.u(16);
  return bits.ok && layers <= 62 && sublayers <= 6 && reserved == 0xFFFF;
}

// The historical short check: Main or Main10 profile_tier_level, including the
// 16-byte fixture that is only that prefix.
inline bool LooksLikeSpsShort(const uint8_t* rbsp, size_t size) {
  if (!rbsp || size < 16) return false;
  HevcBits bits{rbsp, size};
  const int vps = bits.u(4);
  const int sublayers = bits.u(3);
  bits.u(1);
  const int space = bits.u(2);
  bits.u(1);
  const int profile = bits.u(5);
  const uint32_t flags = bits.ubits(32);
  const bool known = profile == 1 || profile == 2;
  const bool compatible =
      known && profile <= 31 && ((flags >> (31 - profile)) & 1u);
  return bits.ok && vps <= 15 && sublayers <= 6 && space == 0 && compatible;
}

inline bool Compatibility(uint32_t flags, int profile) {
  return profile >= 0 && profile <= 31 && ((flags >> (31 - profile)) & 1u);
}

inline bool SkipProfileTier(HevcBits* bits) {
  const int space = bits->u(2);
  bits->u(1);
  const int profile = bits->u(5);
  const uint32_t flags = bits->ubits(32);
  if (!bits->ok || space != 0 || profile < 1 || profile > 11) return false;
  bits->u(4);
  bool rext = false;
  bool high = false;
  for (int id = 4; id <= 11; ++id) {
    if (profile == id || Compatibility(flags, id)) rext = true;
  }
  for (int id : {5, 9, 10, 11}) {
    if (profile == id || Compatibility(flags, id)) high = true;
  }
  if (rext) {
    bits->skip(9);
    bits->skip(high ? 33 : 34);
  } else {
    bits->skip(44);
  }
  bits->u(1);
  bits->u(8);
  return bits->ok;
}

// A complete SPS, not only the profile prefix. max_sub_layers_minus1 must be
// 0; that is what single-layer enhancement streams use.
inline bool LooksLikeSps(const uint8_t* rbsp, size_t size) {
  if (!rbsp || size < 16) return false;
  HevcBits bits{rbsp, size};
  const int vps = bits.u(4);
  const int sublayers = bits.u(3);
  bits.u(1);
  if (!bits.ok || vps > 15 || sublayers != 0) return false;
  if (!SkipProfileTier(&bits)) return false;
  const int sps_id = bits.ue();
  const int chroma = bits.ue();
  if (chroma == 3) bits.u(1);
  const int width = bits.ue();
  const int height = bits.ue();
  return bits.ok && sps_id <= 15 && chroma >= 0 && chroma <= 3 && width >= 8 &&
         width <= 8192 && height >= 8 && height <= 8192 && (width % 2) == 0 &&
         (height % 2) == 0;
}

// PPS with tiles, wavefront or scaling lists is left unrecognized. A match
// must consume the RBSP exactly, including the stop bit, so slice data cannot
// pass.
inline bool LooksLikePps(const uint8_t* rbsp, size_t size) {
  if (!rbsp || size < 3 || size > 128) return false;
  HevcBits bits{rbsp, size};
  const int pps = bits.ue();
  const int sps = bits.ue();
  if (!bits.ok || pps > 63 || sps > 15) return false;
  bits.u(1);
  bits.u(1);
  const int extra = bits.u(3);
  if (extra > 2) return false;
  bits.u(1);
  bits.u(1);
  const int l0 = bits.ue();
  const int l1 = bits.ue();
  const int qp = bits.se();
  if (!bits.ok || l0 > 15 || l1 > 15 || qp < -26 || qp > 25) return false;
  bits.u(1);
  bits.u(1);
  if (bits.u(1)) {
    const int depth = bits.ue();
    if (depth > 6) return false;
  }
  bits.se();
  bits.se();
  bits.u(4);
  const int tiles = bits.u(1);
  const int wavefront = bits.u(1);
  if (!bits.ok || tiles || wavefront) return false;
  bits.u(1);
  if (bits.u(1)) {
    bits.u(1);
    if (!bits.u(1)) {
      bits.se();
      bits.se();
    }
  }
  if (bits.u(1)) return false;
  bits.u(1);
  const int merge = bits.ue();
  if (!bits.ok || merge > 7) return false;
  bits.u(1);
  if (bits.u(1)) return false;
  if (!bits.ok || bits.u(1) != 1) return false;
  while (bits.ok && (bits.bit % 8) != 0) {
    if (bits.u(1) != 0) return false;
  }
  return bits.ok && bits.bit == size * 8;
}

inline bool SliceHeader(const uint8_t* rbsp, size_t size, bool irap, int* pps,
                        int* slice_type) {
  if (!rbsp || !size || !pps || !slice_type) return false;
  HevcBits bits{rbsp, size};
  const int first = bits.u(1);
  if (!bits.ok || !first) return false;
  if (irap) bits.u(1);
  const int pps_id = bits.ue();
  const int type = bits.ue();
  if (!bits.ok || pps_id > 63 || type > 2) return false;
  *pps = pps_id;
  *slice_type = type;
  return true;
}

// Type 63 may be the original enhancement NAL with only nal_unit_type rewritten.
// VPS is the reserved 0xFFFF word. SPS is a Main/Main10 prefix or a parsed
// sequence set. PPS must end on its stop bit. An IRAP slice parses as an I
// slice only when the extra no_output bit is present; otherwise the slice is
// TRAIL_R. A nested NAL whose RBSP does not match those shapes is unchanged.
inline int RestoredElNalType(const uint8_t* rbsp, size_t size) {
  const std::vector<uint8_t> payload = RbspPayload(rbsp, size);
  const uint8_t* data = payload.data();
  const size_t bytes = payload.size();
  if (LooksLikeVps(data, bytes)) return 32;
  if (LooksLikeSpsShort(data, bytes) || LooksLikeSps(data, bytes)) return 33;
  if (LooksLikePps(data, bytes)) return 34;
  int irap_pps = -1;
  int irap_type = -1;
  int trail_pps = -1;
  int trail_type = -1;
  const bool irap = SliceHeader(data, bytes, true, &irap_pps, &irap_type);
  const bool trail = SliceHeader(data, bytes, false, &trail_pps, &trail_type);
  if (irap && irap_type == 2 && irap_pps <= 3 &&
      (!trail || trail_type != 2 || trail_pps != irap_pps))
    return 20;
  return 1;
}

inline void AppendRestoredElNal(std::vector<uint8_t>* out, const uint8_t* nal, size_t size) {
  if (!out || !nal || size < 3 || out->size() > 32u * 1024u * 1024u) return;
  const int type = RestoredElNalType(nal + 2, size - 2);
  std::vector<uint8_t> restored(nal, nal + size);
  restored[0] = static_cast<uint8_t>((restored[0] & 0x81) | (type << 1));
  AppendAnnexB(out, restored.data(), restored.size());
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
    // A parameter set or IRAP identified from the RBSP wins. An RBSP can share
    // the high bit of a NAL header (a VPS starts with 0x0c) and must not be
    // forwarded unchanged. A nested NAL that is not one of those shapes keeps
    // the header already inside the payload.
    const int restored = RestoredElNalType(payload, payload_size);
    if (restored != 1 || !HevcNalHeader(payload, payload_size))
      AppendRestoredElNal(annexb, nal, nal_size);
    else
      AppendAnnexB(annexb, payload, payload_size);
  });
  if (!framed) annexb->clear();
  return framed;
}
}  // namespace rillight_dovi
