#include "portable_color_pipeline.h"
#include "dovi_color_metadata.h"

#include <algorithm>
#include <array>
#include <condition_variable>
#include <functional>
#include <limits>
#include <mutex>
#include <thread>

extern "C" {
#include <libavutil/mastering_display_metadata.h>
#include <libavutil/pixdesc.h>
#include <libswscale/swscale.h>
}

namespace {
using rillight_color::Constants;
using rillight_color::Vec4;
using Pixel = std::array<float, 3>;
using Table = std::array<float, 4096>;

struct TransferTables {
  Table pq{}, hlg{}, srgb{};
  TransferTables() {
    for (size_t i = 0; i < pq.size(); ++i) {
      const double x = i / 4095.0;
      const double p = std::pow(x, 1.0 / 78.84375);
      pq[i] = static_cast<float>(10000 * std::pow(std::max(p - .8359375, 0.0) /
          (18.8515625 - 18.6875 * p), 1.0 / .1593017578125));
      hlg[i] = static_cast<float>(1000 * (x <= .5 ? x * x / 3 :
          (std::exp((x - .55991073) / .17883277) + .28466892) / 12));
      srgb[i] = static_cast<float>(x <= .0031308 ? 12.92 * x :
          1.055 * std::pow(x, 1.0 / 2.4) - .055);
    }
  }
};

float Lookup(const Table& table, float x) {
  x = std::clamp(x, 0.0f, 1.0f) * 4095;
  const auto lo = static_cast<size_t>(x);
  const auto hi = std::min(lo + 1, table.size() - 1);
  return table[lo] + (table[hi] - table[lo]) * (x - lo);
}

Pixel Multiply(const Vec4* matrix, const Pixel& value) {
  return {matrix[0].x * value[0] + matrix[0].y * value[1] + matrix[0].z * value[2],
          matrix[1].x * value[0] + matrix[1].y * value[1] + matrix[1].z * value[2],
          matrix[2].x * value[0] + matrix[2].y * value[1] + matrix[2].z * value[2]};
}

float Reshape(const Constants& parameters, int c, const Pixel& signal) {
  const auto& curve = parameters.curves[c];
  const int count = static_cast<int>(curve.bounds.x);
  if (!count) return signal[c];
  int index = 0;
  for (int i = 1; i < count - 1; ++i) {
    const auto* pivots = reinterpret_cast<const float*>(&curve.pivots[i / 4]);
    if (signal[c] >= pivots[i % 4]) index = i;
  }
  const auto& piece = curve.pieces[index];
  float value = piece.polynomial.x;
  if (piece.polynomial.w == 0) {
    value += signal[c] * (piece.polynomial.y + signal[c] * piece.polynomial.z);
  } else {
    Pixel powers = signal;
    std::array<float, 4> cross{signal[0] * signal[1], signal[0] * signal[2],
        signal[1] * signal[2], signal[0] * signal[1] * signal[2]};
    auto cross_power = cross;
    for (int order = 0; order < static_cast<int>(piece.polynomial.w); ++order) {
      const auto& a = piece.mmr[2 * order];
      const auto& b = piece.mmr[2 * order + 1];
      value += a.x * powers[0] + a.y * powers[1] + a.z * powers[2] +
          b.x * cross_power[0] + b.y * cross_power[1] + b.z * cross_power[2] + b.w * cross_power[3];
      for (int i = 0; i < 3; ++i) powers[i] *= signal[i];
      for (int i = 0; i < 4; ++i) cross_power[i] *= cross[i];
    }
  }
  return std::clamp(value, curve.bounds.y, curve.bounds.z);
}

// Persistent workers avoid creating several OS threads for each video frame.
class RowWorkers {
 public:
  RowWorkers() {
    try {
      for (int i = 1; i < 4; ++i) workers_[i - 1] = std::thread([this, i] { Run(i); });
    } catch (...) { Stop(); throw; }
  }
  ~RowWorkers() { Stop(); }
  void Execute(std::function<void(int)> work) {
    {
      std::lock_guard lock(mutex_);
      work_ = std::move(work);
      completed_ = 0;
      ++generation_;
    }
    ready_.notify_all();
    work_(0);
    std::unique_lock lock(mutex_);
    done_.wait(lock, [this] { return completed_ == 3; });
  }
 private:
  void Run(int index) {
    uint64_t observed = 0;
    std::unique_lock lock(mutex_);
    for (;;) {
      ready_.wait(lock, [&] { return stopped_ || observed != generation_; });
      if (stopped_) return;
      observed = generation_;
      lock.unlock();
      work_(index);
      lock.lock();
      ++completed_;
      done_.notify_one();
    }
  }
  void Stop() {
    { std::lock_guard lock(mutex_); stopped_ = true; }
    ready_.notify_all();
    for (auto& thread : workers_) if (thread.joinable()) thread.join();
  }
  std::array<std::thread, 3> workers_;
  std::mutex mutex_;
  std::condition_variable ready_, done_;
  std::function<void(int)> work_;
  uint64_t generation_ = 0;
  int completed_ = 0;
  bool stopped_ = false;
};
}  // namespace

struct PortableColorPipeline::Impl {
  SwsContext* scaler = nullptr;
  AVFrame* sampled = nullptr;
  std::unique_ptr<RowWorkers> workers;
  ~Impl() { sws_free_context(&scaler); av_frame_free(&sampled); }

  bool Render(const AVFrame* frame, int width, int height, bool dovi, uint8_t* rgba, int stride) {
    const auto format = static_cast<AVPixelFormat>(frame->format);
    const auto* description = av_pix_fmt_desc_get(format);
    if (!description || description->flags & (AV_PIX_FMT_FLAG_HWACCEL | AV_PIX_FMT_FLAG_RGB) ||
        description->nb_components != 3 || description->comp[0].depth < 8 ||
        description->comp[0].depth > 16 || frame->width <= 0 || frame->height <= 0) return false;
    Constants parameters{};
    parameters.visible = {1, 1, frame->color_primaries == AVCOL_PRI_BT2020 ? 1.0f : 0.0f, 1000};
    if (const auto* side = av_frame_get_side_data(frame, AV_FRAME_DATA_MASTERING_DISPLAY_METADATA);
        side && side->size >= sizeof(AVMasteringDisplayMetadata)) {
      const auto* mastering = reinterpret_cast<const AVMasteringDisplayMetadata*>(side->data);
      if (mastering->has_luminance && mastering->max_luminance.den > 0) {
        const double peak = av_q2d(mastering->max_luminance);
        if (std::isfinite(peak) && peak >= 203 && peak <= 10000) parameters.visible.w = static_cast<float>(peak);
      }
    }
    if (const auto* side = av_frame_get_side_data(frame, AV_FRAME_DATA_CONTENT_LIGHT_LEVEL);
        side && side->size >= sizeof(AVContentLightMetadata)) {
      const auto* light = reinterpret_cast<const AVContentLightMetadata*>(side->data);
      if (light->MaxCLL >= 203 && light->MaxCLL <= 10000) parameters.visible.w = static_cast<float>(light->MaxCLL);
    }
    if (dovi) {
      if (!rillight_color::DoviConstants(frame, &parameters)) return false;
    } else {
      if (frame->color_trc != AVCOL_TRC_SMPTE2084 && frame->color_trc != AVCOL_TRC_ARIB_STD_B67) return false;
      const bool bt2020 = frame->colorspace == AVCOL_SPC_BT2020_NCL;
      parameters.nonlinear[0] = {1, 0, bt2020 ? 1.4746f : 1.5748f, 0};
      parameters.nonlinear[1] = {1, bt2020 ? -.164553f : -.187324f, bt2020 ? -.571353f : -.468124f, 0};
      parameters.nonlinear[2] = {1, bt2020 ? 1.8814f : 1.8556f, 0, 0};
    }
    if (!sampled || sampled->width != width || sampled->height != height) {
      av_frame_free(&sampled);
      sampled = av_frame_alloc();
      if (!sampled) return false;
      sampled->width = width; sampled->height = height;
      sampled->format = AV_PIX_FMT_YUV444P16LE;
      if (av_frame_get_buffer(sampled, 32) < 0) return false;
    }
    if (!sampled->data[0] || !sampled->data[1] || !sampled->data[2]) return false;
    // Upsample/resize the YUV planes without reducing them to 8 bit or
    // interpreting Dolby Vision IPT as an ordinary YCbCr color matrix.
    if (!scaler) {
      scaler = sws_alloc_context();
      if (!scaler) return false;
      scaler->threads = 4;
      scaler->flags = SWS_BILINEAR;
      scaler->backends = SWS_BACKEND_LEGACY;
    }
    sampled->color_range = frame->color_range;
    sampled->colorspace = frame->colorspace;
    sampled->color_primaries = frame->color_primaries;
    sampled->color_trc = frame->color_trc;
    sampled->flags = frame->flags;
    if (sws_scale_frame(scaler, sampled, frame) < 0) return false;
    static const TransferTables tables;
    const int depth = description->comp[0].depth;
    const float source_maximum = static_cast<float>(((1u << depth) - 1) << (16 - depth));
    const bool full = frame->color_range == AVCOL_RANGE_JPEG;
    if (!workers) workers = std::make_unique<RowWorkers>();
    workers->Execute([&](int partition) {
      for (int y = height * partition / 4; y < height * (partition + 1) / 4; ++y) {
        const auto* luma = reinterpret_cast<const uint16_t*>(sampled->data[0] + y * sampled->linesize[0]);
        const auto* u = reinterpret_cast<const uint16_t*>(sampled->data[1] + y * sampled->linesize[1]);
        const auto* v = reinterpret_cast<const uint16_t*>(sampled->data[2] + y * sampled->linesize[2]);
        auto* row = rgba + static_cast<ptrdiff_t>(y) * stride;
        for (int x = 0; x < width; ++x) {
          Pixel signal{luma[x] / source_maximum, u[x] / source_maximum, v[x] / source_maximum};
          Pixel rgb;
          if (dovi) {
            for (auto& value : signal) value = std::clamp(value, 0.0f, 1.0f);
            const Pixel shaped{Reshape(parameters, 0, signal) - parameters.offset.x,
                Reshape(parameters, 1, signal) - parameters.offset.y,
                Reshape(parameters, 2, signal) - parameters.offset.z};
            rgb = Multiply(parameters.nonlinear, shaped);
            for (auto& value : rgb) value = Lookup(tables.pq, value);
            rgb = Multiply(parameters.linear, rgb);
          } else {
            const float scale = static_cast<float>(1u << (depth - 8));
            const float maximum = static_cast<float>((1u << depth) - 1);
            if (!full) signal[0] = (signal[0] - 16 * scale / maximum) * maximum / (219 * scale);
            for (int c = 1; c < 3; ++c) {
              signal[c] -= 128 * scale / maximum;
              if (!full) signal[c] *= maximum / (224 * scale);
            }
            rgb = Multiply(parameters.nonlinear, signal);
            for (auto& value : rgb) value = Lookup(frame->color_trc == AVCOL_TRC_SMPTE2084 ? tables.pq : tables.hlg, value);
          }
          if (parameters.visible.z > 0) {
            const Pixel wide = rgb;
            rgb = {1.660491f * wide[0] - .587641f * wide[1] - .072850f * wide[2],
                   -.124550f * wide[0] + 1.132900f * wide[1] - .008349f * wide[2],
                   -.018151f * wide[0] - .100579f * wide[1] + 1.118730f * wide[2]};
          }
          const float luminance = std::max(.2126f * rgb[0] + .7152f * rgb[1] + .0722f * rgb[2], 0.0f);
          const float peak = std::max(parameters.visible.w, 203.0f);
          const float mapped = luminance * (1 + 203 / peak) / (203 + luminance);
          for (auto& value : rgb) value *= luminance > 1e-6f ? mapped / luminance : 0;
          const float low = std::min({rgb[0], rgb[1], rgb[2]});
          const float high = std::max({rgb[0], rgb[1], rgb[2]});
          const float neutral = std::clamp(mapped, 0.0f, 1.0f);
          float amount = 1;
          if (low < 0) amount = std::min(amount, mapped / std::max(mapped - low, 1e-6f));
          if (high > 1) amount = std::min(amount, (1 - neutral) / std::max(high - mapped, 1e-6f));
          amount = std::clamp(amount, 0.0f, 1.0f);
          for (int c = 0; c < 3; ++c) row[4 * x + c] = static_cast<uint8_t>(std::lround(
              255 * Lookup(tables.srgb, neutral + (rgb[c] - neutral) * amount)));
          row[4 * x + 3] = 255;
        }
      }
    });
    return true;
  }
};

PortableColorPipeline::PortableColorPipeline() : impl_(std::make_unique<Impl>()) {}
PortableColorPipeline::~PortableColorPipeline() = default;
bool PortableColorPipeline::Render(const AVFrame* frame, int width, int height, bool dovi,
                                    uint8_t* rgba, int stride) {
  if (!frame || !rgba || width <= 0 || width > std::numeric_limits<int>::max() / 4 ||
      height <= 0 || stride < width * 4) return false;
  try { return impl_->Render(frame, width, height, dovi, rgba, stride); }
  catch (const std::exception&) { return false; }
}
