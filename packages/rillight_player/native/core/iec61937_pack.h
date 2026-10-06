#ifndef RILLIGHT_IEC61937_PACK_H_
#define RILLIGHT_IEC61937_PACK_H_

#include <cstdint>
#include <cstring>
#include <vector>

// Little-endian IEC 61937 bursts, matching FFmpeg's default SPDIF muxer.
// WASAPI exclusive and Pulse IEC encodings consume this layout. A negative
// result means the access unit does not fit a repetition period; callers
// clear passthrough and decode PCM instead of writing a short burst.

inline void rillight_iec_put_le16(std::vector<uint8_t> &out, unsigned value) {
  out.push_back(static_cast<uint8_t>(value));
  out.push_back(static_cast<uint8_t>(value >> 8));
}

inline bool rillight_iec_finish(std::vector<uint8_t> *out, uint16_t data_type,
                                const uint8_t *payload, int payload_bytes,
                                int period_bytes) {
  if (!out || !payload || payload_bytes < 1 || period_bytes < 8) return false;
  const int padding = (period_bytes - 8 - payload_bytes) & ~1;
  if (padding < 0) return false;
  out->clear();
  out->reserve(static_cast<size_t>(period_bytes));
  rillight_iec_put_le16(*out, 0xF872);
  rillight_iec_put_le16(*out, 0x4E1F);
  rillight_iec_put_le16(*out, data_type);
  rillight_iec_put_le16(*out, static_cast<unsigned>(payload_bytes));
  int index = 0;
  for (; index + 1 < payload_bytes; index += 2) {
    out->push_back(payload[index + 1]);
    out->push_back(payload[index]);
  }
  if (index < payload_bytes)
    rillight_iec_put_le16(*out, static_cast<unsigned>(payload[index]) << 8);
  out->insert(out->end(), static_cast<size_t>(padding), 0);
  return static_cast<int>(out->size()) == period_bytes;
}

struct RillightIec61937Mux {
  static constexpr int kEac3Period = 24576;
  static constexpr int kTrueHdPeriod = 61440;
  static constexpr int kMatFrame = 61424;

  std::vector<uint8_t> eac3;
  int eac3_count = 0;
  std::vector<uint8_t> mat[2];
  int mat_index = 0;
  int mat_filled = 0;
  int truehd_samples = 0;
  int truehd_prev_size = 0;
  int truehd_presync = 0;
  uint16_t truehd_prev_time = 0;
  bool truehd_have_time = false;

  bool pending_input() const { return eac3_count > 0 || mat_filled > 0; }

  void reset() {
    eac3.clear();
    eac3_count = 0;
    mat[0].clear();
    mat[1].clear();
    mat_index = mat_filled = 0;
    truehd_samples = truehd_prev_size = truehd_presync = 0;
    truehd_prev_time = 0;
    truehd_have_time = false;
  }

  // 1 when *burst holds one period, 0 when more access units are required.
  int push_eac3(const uint8_t *data, int size, std::vector<uint8_t> *burst) {
    if (!data || size < 6 || !burst) return -1;
    static const uint8_t repeat_for_blocks[4] = {6, 3, 2, 1};
    int repeat = 1;
    const int bsid = data[5] >> 3;
    if (bsid > 10 && (data[4] & 0xc0) != 0xc0)
      repeat = repeat_for_blocks[(data[4] & 0x30) >> 4];
    if (static_cast<int>(eac3.size()) + size > kEac3Period - 8) return -1;
    eac3.insert(eac3.end(), data, data + size);
    if (++eac3_count < repeat) return 0;
    const bool packed = rillight_iec_finish(burst, 0x15, eac3.data(),
                                            static_cast<int>(eac3.size()),
                                            kEac3Period);
    eac3.clear();
    eac3_count = 0;
    return packed ? 1 : -1;
  }

  // 0 waits for another access unit. The first frames after a seek often
  // are not a major sync; that is not a rejected receiver. -1 is only an
  // access unit that cannot fit, or 128 frames with no major sync at all.
  int push_truehd(const uint8_t *data, int size, std::vector<uint8_t> *burst) {
    if (!data || size < 10 || !burst) return -1;
    for (auto &buffer : mat) {
      if (buffer.size() != static_cast<size_t>(kMatFrame))
        buffer.assign(static_cast<size_t>(kMatFrame), 0);
    }
    if ((static_cast<unsigned>(data[4]) << 16 |
         static_cast<unsigned>(data[5]) << 8 |
         static_cast<unsigned>(data[6])) == 0xf8726fu) {
      int rate_bits = -1;
      if (data[7] == 0xba) rate_bits = data[8] >> 4;
      else if (data[7] == 0xbb) rate_bits = data[9] >> 4;
      if (rate_bits >= 0) truehd_samples = 40 << (rate_bits & 3);
    }
    if (truehd_samples <= 0) {
      // TrueHD repeats a major sync at least every 128 access units.
      if (++truehd_presync > 128) return -1;
      return 0;
    }
    truehd_presync = 0;

    static const uint8_t mat_start[20] = {
        0x07, 0x9E, 0x00, 0x03, 0x84, 0x01, 0x01, 0x01, 0x80, 0x00,
        0x56, 0xA5, 0x3B, 0xF4, 0x81, 0x83, 0x49, 0x80, 0x77, 0xE0};
    static const uint8_t mat_middle[12] = {
        0xC3, 0xC1, 0x42, 0x49, 0x3B, 0xFA,
        0x82, 0x83, 0x49, 0x80, 0x77, 0xE0};
    static const uint8_t mat_end[16] = {
        0xC3, 0xC2, 0xC0, 0xC4, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x97, 0x11};
    struct Code {
      int pos;
      int len;
      const uint8_t *bytes;
    };
    const Code codes[3] = {
        {0, 20, mat_start},
        {30708, 12, mat_middle},
        {kMatFrame - 16, 16, mat_end},
    };
    const uint16_t input_timing =
        static_cast<uint16_t>((static_cast<unsigned>(data[2]) << 8) | data[3]);
    int padding_remaining = 0;
    if (truehd_have_time) {
      const uint16_t delta =
          static_cast<uint16_t>(input_timing - truehd_prev_time);
      const int delta_bytes = static_cast<int>(delta) * 2560 / truehd_samples;
      padding_remaining = delta_bytes - truehd_prev_size;
      if (padding_remaining < 0 || padding_remaining >= kMatFrame / 2)
        padding_remaining = 0;
    }
    int total_frame_size = size;
    const uint8_t *cursor = data;
    int data_remaining = size;
    int next_code = 0;
    while (next_code < 3 && mat_filled > codes[next_code].pos) ++next_code;
    if (next_code >= 3) return -1;
    uint8_t *hd_buf = mat[mat_index].data();
    bool have_packet = false;
    std::vector<uint8_t> completed;
    while (padding_remaining || data_remaining ||
           (next_code < 3 && codes[next_code].pos == mat_filled)) {
      if (next_code >= 3) return -1;
      if (codes[next_code].pos == mat_filled) {
        const int code_len = codes[next_code].len;
        int code_len_remaining = code_len;
        std::memcpy(hd_buf + codes[next_code].pos, codes[next_code].bytes,
                    static_cast<size_t>(code_len));
        mat_filled += code_len;
        ++next_code;
        if (next_code == 3) {
          have_packet = true;
          completed.assign(hd_buf, hd_buf + kMatFrame);
          mat_index ^= 1;
          hd_buf = mat[mat_index].data();
          mat_filled = 0;
          next_code = 0;
          code_len_remaining += kTrueHdPeriod - kMatFrame;
        }
        if (padding_remaining) {
          const int counted =
              padding_remaining < code_len_remaining ? padding_remaining
                                                    : code_len_remaining;
          padding_remaining -= counted;
          code_len_remaining -= counted;
        }
        if (code_len_remaining) total_frame_size += code_len_remaining;
      }
      if (next_code >= 3) return -1;
      if (padding_remaining) {
        const int room = codes[next_code].pos - mat_filled;
        if (room < 0) return -1;
        const int insert = padding_remaining < room ? padding_remaining : room;
        std::memset(hd_buf + mat_filled, 0, static_cast<size_t>(insert));
        mat_filled += insert;
        padding_remaining -= insert;
        if (padding_remaining) continue;
      }
      if (data_remaining) {
        if (next_code >= 3) return -1;
        const int room = codes[next_code].pos - mat_filled;
        if (room < 0) return -1;
        const int insert = data_remaining < room ? data_remaining : room;
        std::memcpy(hd_buf + mat_filled, cursor, static_cast<size_t>(insert));
        mat_filled += insert;
        cursor += insert;
        data_remaining -= insert;
      }
    }
    truehd_prev_size = total_frame_size;
    truehd_prev_time = input_timing;
    truehd_have_time = true;
    if (!have_packet) return 0;
    return rillight_iec_finish(burst, 0x16, completed.data(), kMatFrame,
                              kTrueHdPeriod)
               ? 1
               : -1;
  }
};

#endif
