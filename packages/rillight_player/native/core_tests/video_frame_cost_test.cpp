#include "../core/video_frame_cost.h"
#include "../core/dovi_profile.h"
#include <cassert>
#include <cstring>

int main() {
  assert(!android_dovi_profile_supported(5, 0));
  assert(android_dovi_profile_supported(5, 0x20));
  assert(!android_dovi_profile_supported(5, 0x100));
  assert(!android_dovi_profile_supported(32, 0xffffffff));
  assert(!android_dovi_profile_supported(0, 0xffffffff));
  AVFrame frame{};
  frame.width = 3840; frame.height = 2160;
  frame.format = AV_PIX_FMT_MEDIACODEC;
  unsigned char buffer = 0;
  frame.data[3] = &buffer;
  assert(video_frame_cost(&frame) == 1);
  frame.data[3] = nullptr;
  assert(video_frame_cost(&frame) < 0);
  frame.format = AV_PIX_FMT_YUV420P10LE;
  assert(video_frame_cost(&frame) == 3840 * 2160 * 3);
  frame.format = AV_PIX_FMT_P010LE;
  assert(video_frame_cost(&frame) == 3840 * 2160 * 3);
  frame.width = 0;
  assert(video_frame_cost(&frame) < 0);
  assert(video_frame_cost(nullptr) < 0);
  assert(dovi_profile_from_frame(nullptr) == 0);
  AVFrame* tagged = av_frame_alloc();
  size_t size = 0;
  auto* metadata = av_dovi_metadata_alloc(&size);
  auto* side = av_frame_new_side_data(tagged, AV_FRAME_DATA_DOVI_METADATA, size);
  assert(side);
  std::memcpy(side->data, metadata, size);
  av_free(metadata);
  auto* header = av_dovi_get_header(reinterpret_cast<AVDOVIMetadata*>(side->data));
  header->vdr_rpu_profile = 0; header->bl_video_full_range_flag = 1;
  assert(dovi_profile_from_frame(tagged) == 5);
  header->vdr_rpu_profile = 1; header->el_spatial_resampling_filter_flag = 0;
  assert(dovi_profile_from_frame(tagged) == 8);
  header->el_spatial_resampling_filter_flag = 1; header->disable_residual_flag = 0;
  header->vdr_bit_depth = 12;
  assert(dovi_profile_from_frame(tagged) == 7);
  header->vdr_bit_depth = 10;
  assert(dovi_profile_from_frame(tagged) == 4);
  av_frame_free(&tagged);
}
