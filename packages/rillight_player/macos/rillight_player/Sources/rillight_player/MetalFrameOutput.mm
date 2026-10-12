#import "MetalFrameOutput.h"
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
namespace rillight_macos {
namespace {
NSString* const shader = @R"(
#include <metal_stdlib>
using namespace metal;
struct Params { float4 fit; float4 overlay; float4 source; };
float3 linearize(float3 x) {
  return select(x/12.92f, pow((max(x,0.0f)+.055f)/1.055f,float3(2.4f)),x>.04045f);
}
kernel void fit_frame(texture2d<float,access::sample> image [[texture(0)]],
                      texture2d<float,access::write> output [[texture(1)]],
                      texture2d<float,access::sample> subtitle [[texture(2)]],
                      constant Params& p [[buffer(0)]],
                      uint2 at [[thread_position_in_grid]]) {
  if (at.x>=output.get_width() || at.y>=output.get_height()) return;
  float2 xy=float2(at)+.5f;
  if (any(xy<p.fit.xy) || any(xy>=p.fit.xy+p.fit.zw)) {
    output.write(float4(0,0,0,1),at); return;
  }
  float2 uv=(xy-p.fit.xy)/p.fit.zw;
  int rotation=int(p.source.z);
  if (rotation==1) uv=float2(uv.y,1-uv.x);
  else if(rotation==2) uv=1-uv;
  else if(rotation==3) uv=float2(1-uv.y,uv.x);
  constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear);
  float3 rgb=image.sample(s,uv).rgb;
  float2 source=uv*p.source.xy;
  if (p.overlay.z>0 && all(source>=p.overlay.xy) && all(source<p.overlay.xy+p.overlay.zw)) {
    float4 sub=subtitle.sample(s,(source-p.overlay.xy)/p.overlay.zw);
    if (p.source.w>0) {
      // The subtitle plane is premultiplied in sRGB. Unpremultiply before
      // decoding the transfer curve, then blend in linear light.
      float3 color=linearize(sub.rgb/max(sub.a,1e-6f))*sub.a;
      rgb=color+rgb*(1-sub.a);
    } else rgb=sub.rgb+rgb*(1-sub.a);
  }
  output.write(float4(rgb,1),at);
}
)";
struct Params {
  float fit[4], overlay[4], source[4];
};
struct TextureRef {
  CVMetalTextureRef ref = nullptr;
  ~TextureRef() {
    if (ref) CFRelease(ref);
  }
};
}  // namespace
struct MetalFrameOutput::Impl {
  id<MTLDevice> device = nil;
  id<MTLCommandQueue> queue = nil;
  id<MTLComputePipelineState> pipeline = nil;
  CVMetalTextureCacheRef cache = nullptr;
  CVPixelBufferPoolRef pool = nullptr;
  int width = 0, height = 0;
  OSType format = 0;
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
    NSError* error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:shader options:nil error:&error];
    if (!library) return false;
    pipeline =
        [device newComputePipelineStateWithFunction:[library newFunctionWithName:@"fit_frame"]
                                              error:&error];
    return pipeline && queue;
  }
  id<MTLTexture> Import(CVPixelBufferRef buffer, MTLPixelFormat f, TextureRef& ref) {
    if (CVMetalTextureCacheCreateTextureFromImage(nullptr, cache, buffer, nullptr, f,
                                                  CVPixelBufferGetWidth(buffer),
                                                  CVPixelBufferGetHeight(buffer), 0, &ref.ref))
      return nil;
    return CVMetalTextureGetTexture(ref.ref);
  }
  CVPixelBufferRef Render(CVPixelBufferRef input, const RillightCoreFrame& frame, int w, int h,
                          const RillightCoreSubtitleOverlay* overlay) {
    @autoreleasepool {
      if (!input || frame.width <= 0 || frame.height <= 0 || !Open()) return nullptr;
      w = std::clamp(w, 1, 4096);
      h = std::clamp(h, 1, 2304);
      OSType f = CVPixelBufferGetPixelFormatType(input);
      bool linear = f == kCVPixelFormatType_64RGBAHalf;
      if (!linear && f != kCVPixelFormatType_32BGRA) return nullptr;
      if (CVPixelBufferGetWidth(input) != static_cast<size_t>(frame.width) ||
          CVPixelBufferGetHeight(input) != static_cast<size_t>(frame.height))
        return nullptr;
      if (!pool || width != w || height != h || format != f) {
        if (pool) CFRelease(pool);
        pool = nullptr;
        NSDictionary* attrs = @{
          (id)kCVPixelBufferWidthKey : @(w),
          (id)kCVPixelBufferHeightKey : @(h),
          (id)kCVPixelBufferPixelFormatTypeKey : @(f),
          (id)kCVPixelBufferMetalCompatibilityKey : @YES,
          (id)kCVPixelBufferIOSurfacePropertiesKey : @{}
        };
        if (CVPixelBufferPoolCreate(nullptr, nullptr, (__bridge CFDictionaryRef)attrs, &pool))
          return nullptr;
        width = w;
        height = h;
        format = f;
      }
      CVPixelBufferRef output = nullptr;
      NSDictionary* limit = @{(id)kCVPixelBufferPoolAllocationThresholdKey : @8};
      if (CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
              nullptr, pool, (__bridge CFDictionaryRef)limit, &output))
        return nullptr;
      auto owned = std::shared_ptr<void>(
          output, [](void* p) { CVPixelBufferRelease(static_cast<CVPixelBufferRef>(p)); });
      TextureRef inRef, outRef;
      auto pixel = linear ? MTLPixelFormatRGBA16Float : MTLPixelFormatBGRA8Unorm;
      id<MTLTexture> in = Import(input, pixel, inRef), out = Import(output, pixel, outRef);
      if (!in || !out) return nullptr;
      const double sar = frame.sar_num > 0 && frame.sar_den > 0
                             ? std::clamp(double(frame.sar_num) / frame.sar_den, .1, 10.0)
                             : 1;
      int rotation = 0;
      if (frame.has_display_matrix) {
        rotation = static_cast<int>(std::lround(
            std::atan2(double(frame.display_matrix[1]), double(frame.display_matrix[0])) /
            (3.14159265358979323846 / 2)));
        rotation = (rotation % 4 + 4) % 4;
      }
      double dw = rotation % 2 ? frame.height : frame.width * sar;
      double dh = rotation % 2 ? frame.width * sar : frame.height;
      double scale = std::min(w / dw, h / dh);
      int cw = std::clamp(int(std::lround(dw * scale)), 1, w),
          ch = std::clamp(int(std::lround(dh * scale)), 1, h);
      Params p{{float((w - cw) / 2), float((h - ch) / 2), float(cw), float(ch)},
               {},
               {float(frame.width), float(frame.height), float(rotation), linear ? 1.0f : 0.0f}};
      id<MTLTexture> sub = nil;
      if (overlay && overlay->data && overlay->width > 0 && overlay->height > 0) {
        if (overlay->width > 8192 || overlay->height > 8192 || overlay->stride < overlay->width * 4)
          return nullptr;
        auto desc =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                               width:overlay->width
                                                              height:overlay->height
                                                           mipmapped:NO];
        sub = [device newTextureWithDescriptor:desc];
        if (!sub) return nullptr;
        [sub replaceRegion:MTLRegionMake2D(0, 0, overlay->width, overlay->height)
               mipmapLevel:0
                 withBytes:overlay->data
               bytesPerRow:overlay->stride];
        p.overlay[0] = overlay->x;
        p.overlay[1] = overlay->y;
        p.overlay[2] = overlay->width;
        p.overlay[3] = overlay->height;
      }
      id<MTLCommandBuffer> command = [queue commandBuffer];
      id<MTLComputeCommandEncoder> enc = [command computeCommandEncoder];
      if (!enc) return nullptr;
      [enc setComputePipelineState:pipeline];
      [enc setTexture:in atIndex:0];
      [enc setTexture:out atIndex:1];
      [enc setTexture:sub ?: in atIndex:2];
      [enc setBytes:&p length:sizeof(p) atIndex:0];
      [enc dispatchThreads:MTLSizeMake(w, h, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
      [enc endEncoding];
      [command commit];
      [command waitUntilCompleted];
      if (command.status != MTLCommandBufferStatusCompleted) return nullptr;
      return CVPixelBufferRetain(output);
    }
  }
};
MetalFrameOutput::MetalFrameOutput() : impl_(std::make_unique<Impl>()) {}
MetalFrameOutput::~MetalFrameOutput() = default;
bool MetalFrameOutput::Ready() { return impl_->Open(); }
CVPixelBufferRef MetalFrameOutput::Render(CVPixelBufferRef input, const RillightCoreFrame& frame,
                                          int width, int height,
                                          const RillightCoreSubtitleOverlay* overlay) {
  return impl_->Render(input, frame, width, height, overlay);
}
}  // namespace rillight_macos

namespace rillight_macos {
CVPixelBufferRef CpuFallbackBuffer(CVPixelBufferRef input, const RillightCoreFrame& source,
                                   int width, int height,
                                   const RillightCoreSubtitleOverlay* overlay) {
  if (!input || source.width <= 0 || source.height <= 0 || source.width > 8192 ||
      source.height > 8192)
    return nullptr;
  const bool linear = CVPixelBufferGetPixelFormatType(input) == kCVPixelFormatType_64RGBAHalf;
  if (!linear && CVPixelBufferGetPixelFormatType(input) != kCVPixelFormatType_32BGRA)
    return nullptr;
  if (CVPixelBufferLockBaseAddress(input, kCVPixelBufferLock_ReadOnly)) return nullptr;
  struct Unlock {
    CVPixelBufferRef buffer;
    ~Unlock() { CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly); }
  } unlock{input};
  RillightCoreFrame frame = source;
  frame.type = linear ? RILLIGHT_CORE_VIDEO_RGBA16F : RILLIGHT_CORE_VIDEO_RGBA;
  frame.stride = static_cast<int>(CVPixelBufferGetBytesPerRow(input));
  frame.data_size = frame.stride * source.height;
  frame.data = static_cast<uint8_t*>(CVPixelBufferGetBaseAddress(input));
  if (!frame.data) return nullptr;
  std::vector<uint8_t> rgba;
  if (!linear) {
    rgba.resize(static_cast<size_t>(frame.width) * frame.height * 4);
    for (int y = 0; y < frame.height; ++y)
      for (int x = 0; x < frame.width; ++x) {
        auto* to = rgba.data() + (static_cast<size_t>(y) * frame.width + x) * 4;
        const auto* from = frame.data + static_cast<size_t>(y) * frame.stride + x * 4;
        to[0] = from[2];
        to[1] = from[1];
        to[2] = from[0];
        to[3] = 255;
        if (overlay && overlay->data && overlay->stride >= overlay->width * 4 && x >= overlay->x &&
            x < overlay->x + overlay->width && y >= overlay->y &&
            y < overlay->y + overlay->height) {
          auto* sub = overlay->data + (y - overlay->y) * overlay->stride + (x - overlay->x) * 4;
          for (int c = 0; c < 3; ++c)
            to[c] =
                static_cast<uint8_t>(std::min(255, sub[c] + (to[c] * (255 - sub[3]) + 127) / 255));
        }
      }
    frame.data = rgba.data();
    frame.stride = frame.width * 4;
    frame.data_size = frame.stride * frame.height;
  }
  // WriteLinearHalf consumes straight-alpha subtitle RGB. The core's overlay
  // is premultiplied, so unpremultiply only the small fallback subtitle plane.
  std::vector<uint8_t> straight;
  RillightCoreSubtitleOverlay straight_overlay{};
  if (linear && overlay && overlay->data && overlay->width > 0 && overlay->height > 0 &&
      overlay->width <= 8192 && overlay->height <= 8192 && overlay->stride >= overlay->width * 4) {
    straight.resize(static_cast<size_t>(overlay->width) * overlay->height * 4);
    for (int y = 0; y < overlay->height; ++y)
      for (int x = 0; x < overlay->width; ++x) {
        const auto* from = overlay->data + y * overlay->stride + x * 4;
        auto* to = straight.data() + (static_cast<size_t>(y) * overlay->width + x) * 4;
        for (int c = 0; c < 3; ++c)
          to[c] = from[3]
                      ? static_cast<uint8_t>(std::min(255, (from[c] * 255 + from[3] / 2) / from[3]))
                      : 0;
        to[3] = from[3];
      }
    straight_overlay = *overlay;
    straight_overlay.data = straight.data();
    straight_overlay.stride = overlay->width * 4;
    overlay = &straight_overlay;
  }
  width = std::clamp(width, 1, 4096);
  height = std::clamp(height, 1, 2304);
  NSDictionary* attrs = @{
    (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
    (id)kCVPixelBufferMetalCompatibilityKey : @YES
  };
  CVPixelBufferRef output = nullptr;
  if (CVPixelBufferCreate(nullptr, width, height,
                          linear ? kCVPixelFormatType_64RGBAHalf : kCVPixelFormatType_32BGRA,
                          (__bridge CFDictionaryRef)attrs, &output))
    return nullptr;
  if (CVPixelBufferLockBaseAddress(output, 0)) {
    CVPixelBufferRelease(output);
    return nullptr;
  }
  auto* pixels = static_cast<uint8_t*>(CVPixelBufferGetBaseAddress(output));
  const size_t stride = CVPixelBufferGetBytesPerRow(output);
  bool ok = linear ? WriteLinearHalf(frame, width, height, reinterpret_cast<uint16_t*>(pixels),
                                     stride, stride * height, overlay)
                   : WriteBgra(frame, width, height, pixels, stride, stride * height);
  CVPixelBufferUnlockBaseAddress(output, 0);
  if (!ok) {
    CVPixelBufferRelease(output);
    return nullptr;
  }
  return output;
}
}  // namespace rillight_macos
