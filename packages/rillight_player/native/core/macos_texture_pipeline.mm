#include "macos_texture_pipeline.h"
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <array>
#include <cmath>
#include "dovi_color_metadata.h"
extern "C" {
#include <libavutil/mastering_display_metadata.h>
}
namespace {
NSString* const shader = @R"(#include <metal_stdlib>
using namespace metal;
struct Piece { float4 polynomial; float4 mmr[6]; };
struct Curve { float4 bounds; float4 pivots[3]; Piece pieces[8]; };
struct Params {
  float4 output; float4 visible; float4 range; float4 offset;
  float4 nonlinear[3]; float4 linear[3]; Curve curves[3];
};
float lookup(device const float* table, float value) {
  float x = clamp(value, 0.0f, 1.0f) * 4095.0f;
  uint lo = uint(x), hi = min(lo + 1, 4095u);
  return table[lo] + (table[hi] - table[lo]) * (x - float(lo));
}
float reshape(constant Curve& curve, int channel, float3 signal) {
  int count = int(curve.bounds.x);
  if (!count) return signal[channel];
  int index = 0;
  for (int i = 1; i < count - 1; ++i)
    if (signal[channel] >= curve.pivots[i / 4][i % 4]) index = i;
  constant Piece& piece = curve.pieces[index];
  float value = piece.polynomial.x;
  if (piece.polynomial.w == 0) {
    value += signal[channel] * (piece.polynomial.y +
                               signal[channel] * piece.polynomial.z);
  } else {
    float3 powers = signal;
    float4 cross = float4(signal.x * signal.y, signal.x * signal.z,
                         signal.y * signal.z, signal.x * signal.y * signal.z);
    float4 crossPower = cross;
    for (int order = 0; order < int(piece.polynomial.w); ++order) {
      float4 a = piece.mmr[2 * order], b = piece.mmr[2 * order + 1];
      value += a.x * powers.x + a.y * powers.y + a.z * powers.z +
               b.x * crossPower.x + b.y * crossPower.y +
               b.z * crossPower.z + b.w * crossPower.w;
      powers *= signal;
      crossPower *= cross;
    }
  }
  return clamp(value, curve.bounds.y, curve.bounds.z);
}

float3 linearize(float3 x) {
  return select(x / 12.92f, pow((max(x, 0.0f) + .055f) / 1.055f, float3(2.4f)), x > .04045f);
}
float3 encode(float3 x) {
  return select(12.92f * x, 1.055f * pow(max(x, 0.0f), float3(1.0f / 2.4f)) - .055f, x > .0031308f);
}
kernel void texture_color(texture2d<float, access::sample> y [[texture(0)]],
                          texture2d<float, access::sample> uv [[texture(1)]],
                          texture2d<float, access::write> out [[texture(2)]],
                          constant Params& p [[buffer(0)]],
                          device const float* pq [[buffer(1)]],
                          device const float* hlg [[buffer(2)]],
                          uint2 pos [[thread_position_in_grid]]) {
  if (pos.x >= out.get_width() || pos.y >= out.get_height()) return;
  constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
  float2 at = (float2(pos) + .5f) / float2(out.get_width(), out.get_height());
  float3 signal = float3(y.sample(s, at).r, uv.sample(s, at + p.output.xy).rg) * p.output.z;
  float3 rgb;
  if (p.output.w == 3) {
    signal = clamp(signal, 0.0f, 1.0f);
    float3 shaped = float3(reshape(p.curves[0], 0, signal),
                          reshape(p.curves[1], 1, signal),
                          reshape(p.curves[2], 2, signal)) - p.offset.xyz;
    rgb = float3(dot(p.nonlinear[0].xyz, shaped), dot(p.nonlinear[1].xyz, shaped),
                 dot(p.nonlinear[2].xyz, shaped));
    rgb = float3(lookup(pq, rgb.x), lookup(pq, rgb.y), lookup(pq, rgb.z));
    rgb = float3(dot(p.linear[0].xyz, rgb), dot(p.linear[1].xyz, rgb),
                 dot(p.linear[2].xyz, rgb));
  } else {
    signal.x = (signal.x - p.range.x) * p.range.y;
    signal.yz = (signal.yz - p.range.z) * p.range.w;
    rgb = float3(dot(p.nonlinear[0].xyz, signal), dot(p.nonlinear[1].xyz, signal),
                 dot(p.nonlinear[2].xyz, signal));
    if (p.output.w == 0) rgb = linearize(rgb) * 203.0f;
    else {
      device const float* table = p.output.w == 1 ? pq : hlg;
      rgb = float3(lookup(table, rgb.x), lookup(table, rgb.y), lookup(table, rgb.z));
    }
  }
  if (p.visible.z > 0) rgb = float3(
    dot(float3(1.660491f, -.587641f, -.072850f), rgb),
    dot(float3(-.124550f, 1.132900f, -.008349f), rgb),
    dot(float3(-.018151f, -.100579f, 1.118730f), rgb));
  if (p.visible.x > 0) rgb /= 203.0f;
  else if (p.output.w == 0) rgb = encode(rgb / 203.0f);
  else {
    float lum = max(dot(float3(.2126f, .7152f, .0722f), rgb), 0.0f);
    float mapped = lum * (1 + 203 / max(p.visible.w, 203.0f)) / (203 + lum);
    rgb *= lum > 1e-6f ? mapped / lum : 0;
    float low = min(rgb.x, min(rgb.y, rgb.z)), high = max(rgb.x, max(rgb.y, rgb.z));
    float neutral = clamp(mapped, 0.0f, 1.0f), amount = 1;
    if (low < 0) amount = min(amount, mapped / max(mapped - low, 1e-6f));
    if (high > 1) amount = min(amount, (1 - neutral) / max(high - mapped, 1e-6f));
    rgb = encode(neutral + (rgb - neutral) * clamp(amount, 0.0f, 1.0f));
  }
  out.write(float4(rgb, 1), pos);
}
)";
struct CvTexture {
  CVMetalTextureRef value = nullptr;
  ~CvTexture() {
    if (value) CFRelease(value);
  }
};
}  // namespace
struct MacosTexturePipeline::Impl {
  id<MTLDevice> device = nil;
  id<MTLCommandQueue> queue = nil;
  id<MTLComputePipelineState> pipeline = nil;
  id<MTLBuffer> pq = nil, hlg = nil;
  CVMetalTextureCacheRef cache = nullptr;
  CVPixelBufferPoolRef pool = nullptr;
  int width = 0, height = 0;
  bool linear = false;
  ~Impl() {
    if (pool) CFRelease(pool);
    if (cache) CFRelease(cache);
  }
  bool Open() {
    if (pipeline) return true;
    device = MTLCreateSystemDefaultDevice();
    if (!device || CVMetalTextureCacheCreate(nullptr, nullptr, device, nullptr, &cache))
      return false;
    queue = [device newCommandQueue];
    MTLCompileOptions* options = [[MTLCompileOptions alloc] init];
    if (@available(macOS 15.0, *)) options.mathMode = MTLMathModeSafe;
    NSError* error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:shader options:options error:&error];
    if (!library) return false;
    pipeline =
        [device newComputePipelineStateWithFunction:[library newFunctionWithName:@"texture_color"]
                                              error:&error];
    std::array<float, 4096> a{}, b{};
    for (size_t i = 0; i < a.size(); ++i) {
      const double x = i / 4095.0, p = std::pow(x, 1 / 78.84375);
      a[i] = 10000 *
             std::pow(std::max(p - .8359375, 0.0) / (18.8515625 - 18.6875 * p), 1 / .1593017578125);
      b[i] =
          1000 * (x <= .5 ? x * x / 3 : (std::exp((x - .55991073) / .17883277) + .28466892) / 12);
    }
    pq = [device newBufferWithBytes:a.data() length:sizeof(a) options:MTLResourceStorageModeShared];
    hlg = [device newBufferWithBytes:b.data()
                              length:sizeof(b)
                             options:MTLResourceStorageModeShared];
    return queue && pipeline && pq && hlg;
  }
  id<MTLTexture> Import(CVPixelBufferRef buffer, MTLPixelFormat format, size_t w, size_t h,
                        size_t plane, CvTexture& ref) {
    if (CVMetalTextureCacheCreateTextureFromImage(nullptr, cache, buffer, nullptr, format, w, h,
                                                  plane, &ref.value) != kCVReturnSuccess)
      return nil;
    return CVMetalTextureGetTexture(ref.value);
  }
  std::shared_ptr<void> Render(const AVFrame* f, int w, int h, bool dovi, bool hdr) {
    @autoreleasepool {
      if (!f || f->format != AV_PIX_FMT_VIDEOTOOLBOX || !f->data[3] || w <= 0 || h <= 0 ||
          w > 8192 || h > 8192 || !Open())
        return {};
      auto input = reinterpret_cast<CVPixelBufferRef>(f->data[3]);
      const OSType format = CVPixelBufferGetPixelFormatType(input);
      const bool ten = format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
                       format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange;
      if (!ten && format != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange &&
          format != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        return {};
      if (CVPixelBufferGetPlaneCount(input) != 2) return {};
      CvTexture luma, chroma, destination;
      id<MTLTexture> y = Import(input, ten ? MTLPixelFormatR16Unorm : MTLPixelFormatR8Unorm,
                                CVPixelBufferGetWidthOfPlane(input, 0),
                                CVPixelBufferGetHeightOfPlane(input, 0), 0, luma);
      id<MTLTexture> uv = Import(input, ten ? MTLPixelFormatRG16Unorm : MTLPixelFormatRG8Unorm,
                                 CVPixelBufferGetWidthOfPlane(input, 1),
                                 CVPixelBufferGetHeightOfPlane(input, 1), 1, chroma);
      if (!y || !uv) return {};
      if (!pool || width != w || height != h || linear != hdr) {
        if (pool) CFRelease(pool);
        pool = nullptr;
        NSDictionary* attrs = @{
          (id)kCVPixelBufferWidthKey : @(w),
          (id)kCVPixelBufferHeightKey : @(h),
          (id)kCVPixelBufferPixelFormatTypeKey :
              @(hdr ? kCVPixelFormatType_64RGBAHalf : kCVPixelFormatType_32BGRA),
          (id)kCVPixelBufferMetalCompatibilityKey : @YES,
          (id)kCVPixelBufferIOSurfacePropertiesKey : @{}
        };
        if (CVPixelBufferPoolCreate(nullptr, nullptr, (__bridge CFDictionaryRef)attrs, &pool))
          return {};
        width = w;
        height = h;
        linear = hdr;
      }
      CVPixelBufferRef buffer = nullptr;
      NSDictionary* limit = @{(id)kCVPixelBufferPoolAllocationThresholdKey : @12};
      if (CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
              nullptr, pool, (__bridge CFDictionaryRef)limit, &buffer))
        return {};
      std::shared_ptr<void> owned(
          buffer, [](void* value) { CVPixelBufferRelease(static_cast<CVPixelBufferRef>(value)); });
      id<MTLTexture> out = Import(
          buffer, hdr ? MTLPixelFormatRGBA16Float : MTLPixelFormatBGRA8Unorm, w, h, 0, destination);
      if (!out) return {};
      rillight_color::Constants p{};
      p.visible = {hdr ? 1.0f : 0.0f, 0, f->color_primaries == AVCOL_PRI_BT2020 ? 1.0f : 0.0f,
                   1000};
      if (const auto* side = av_frame_get_side_data(f, AV_FRAME_DATA_MASTERING_DISPLAY_METADATA);
          side && side->size >= sizeof(AVMasteringDisplayMetadata)) {
        const auto* m = reinterpret_cast<const AVMasteringDisplayMetadata*>(side->data);
        if (m->has_luminance && m->max_luminance.den > 0) {
          double peak = av_q2d(m->max_luminance);
          if (std::isfinite(peak) && peak >= 203 && peak <= 10000) p.visible.w = peak;
        }
      }
      if (const auto* side = av_frame_get_side_data(f, AV_FRAME_DATA_CONTENT_LIGHT_LEVEL);
          side && side->size >= sizeof(AVContentLightMetadata)) {
        auto peak = reinterpret_cast<const AVContentLightMetadata*>(side->data)->MaxCLL;
        if (peak >= 203 && peak <= 10000) p.visible.w = peak;
      }
      if (dovi) {
        if (!rillight_color::DoviConstants(f, &p)) return {};
      } else {
        const bool bt2020 = f->colorspace == AVCOL_SPC_BT2020_NCL;
        const bool bt601 =
            f->colorspace == AVCOL_SPC_SMPTE170M || f->colorspace == AVCOL_SPC_BT470BG;
        p.nonlinear[0] = {1, 0, bt2020 ? 1.4746f : bt601 ? 1.402f : 1.5748f, 0};
        p.nonlinear[1] = {1,
                          bt2020  ? -.164553f
                          : bt601 ? -.344136f
                                  : -.187324f,
                          bt2020  ? -.571353f
                          : bt601 ? -.714136f
                                  : -.468124f,
                          0};
        p.nonlinear[2] = {1, bt2020 ? 1.8814f : bt601 ? 1.772f : 1.8556f, 0, 0};
      }
      const bool full = f->color_range == AVCOL_RANGE_JPEG;
      const float maximum = ten ? 1023 : 255, scale = ten ? 4 : 1;
      p.range = {full ? 0 : 16 * scale / maximum, full ? 1 : maximum / (219 * scale),
                 128 * scale / maximum, full ? 1 : maximum / (224 * scale)};
      // Normalized texture sampling assumes centered chroma. Honor the source
      // siting before interpolation; row stride remains owned by CoreVideo.
      const auto location = f->chroma_location;
      const float chroma_x =
          (location == AVCHROMA_LOC_UNSPECIFIED || location == AVCHROMA_LOC_LEFT ||
           location == AVCHROMA_LOC_TOPLEFT || location == AVCHROMA_LOC_BOTTOMLEFT)
              ? .5f / f->width
              : 0.0f;
      const float chroma_y =
          (location == AVCHROMA_LOC_TOP || location == AVCHROMA_LOC_TOPLEFT) ? .5f / f->height
          : (location == AVCHROMA_LOC_BOTTOM || location == AVCHROMA_LOC_BOTTOMLEFT)
              ? -.5f / f->height
              : 0.0f;
      p.output = {chroma_x, chroma_y, ten ? 65535.0f / (1023 * 64) : 1.0f,
                  dovi                                     ? 3.0f
                  : f->color_trc == AVCOL_TRC_SMPTE2084    ? 1.0f
                  : f->color_trc == AVCOL_TRC_ARIB_STD_B67 ? 2.0f
                                                           : 0.0f};
      id<MTLCommandBuffer> command = [queue commandBuffer];
      id<MTLComputeCommandEncoder> enc = [command computeCommandEncoder];
      if (!enc) return {};
      [enc setComputePipelineState:pipeline];
      [enc setTexture:y atIndex:0];
      [enc setTexture:uv atIndex:1];
      [enc setTexture:out atIndex:2];
      [enc setBytes:&p length:sizeof(p) atIndex:0];
      [enc setBuffer:pq offset:0 atIndex:1];
      [enc setBuffer:hlg offset:0 atIndex:2];
      [enc dispatchThreads:MTLSizeMake(w, h, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
      [enc endEncoding];
      [command commit];
      [command waitUntilCompleted];
      // Completion fences IOSurface use by the Flutter or EDR device. No readback.
      if (command.status != MTLCommandBufferStatusCompleted) return {};
      return owned;
    }
  }
};
MacosTexturePipeline::MacosTexturePipeline() : impl_(std::make_unique<Impl>()) {}
MacosTexturePipeline::~MacosTexturePipeline() = default;
std::shared_ptr<void> MacosTexturePipeline::Render(const AVFrame* f, int w, int h, bool dovi,
                                                   bool linear) {
  return impl_->Render(f, w, h, dovi, linear);
}
