#include "macos_color_pipeline.h"

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <algorithm>
#include <cstring>
#include <future>

namespace {
NSString* const kShader = @R"(
#include <metal_stdlib>
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
kernel void linear_color(device const ushort* y [[buffer(0)]],
                         device const ushort* u [[buffer(1)]],
                         device const ushort* v [[buffer(2)]],
                         device half4* output [[buffer(3)]],
                         constant Params& p [[buffer(4)]],
                         device const float* pq [[buffer(5)]],
                         device const float* hlg [[buffer(6)]],
                         uint index [[thread_position_in_grid]]) {
  if (index >= uint(p.output.x) * uint(p.output.y)) return;
  float3 signal = float3(y[index], u[index], v[index]) * p.output.z;
  float3 rgb;
  if (p.output.w == 3) {
    signal = clamp(signal, 0.0f, 1.0f);
    float3 shaped = float3(reshape(p.curves[0], 0, signal),
                          reshape(p.curves[1], 1, signal),
                          reshape(p.curves[2], 2, signal)) - p.offset.xyz;
    rgb = float3(dot(p.nonlinear[0].xyz, shaped),
                 dot(p.nonlinear[1].xyz, shaped),
                 dot(p.nonlinear[2].xyz, shaped));
    rgb = float3(lookup(pq, rgb.x), lookup(pq, rgb.y), lookup(pq, rgb.z));
    rgb = float3(dot(p.linear[0].xyz, rgb), dot(p.linear[1].xyz, rgb),
                 dot(p.linear[2].xyz, rgb));
  } else {
    signal.x = (signal.x - p.range.x) * p.range.y;
    signal.yz = (signal.yz - p.range.z) * p.range.w;
    rgb = float3(dot(p.nonlinear[0].xyz, signal),
                 dot(p.nonlinear[1].xyz, signal),
                 dot(p.nonlinear[2].xyz, signal));
    device const float* table = p.output.w == 1 ? pq : hlg;
    rgb = float3(lookup(table, rgb.x), lookup(table, rgb.y), lookup(table, rgb.z));
  }
  if (p.visible.z > 0) {
    rgb = float3(dot(float3(1.660491, -.587641, -.072850), rgb),
                 dot(float3(-.124550, 1.132900, -.008349), rgb),
                 dot(float3(-.018151, -.100579, 1.118730), rgb));
  }
  output[index] = half4(half3(rgb / 203.0f), half(1.0f));
}
)";

struct SharedGpu {
  id<MTLDevice> device = nil;
  id<MTLCommandQueue> queue = nil;
  id<MTLComputePipelineState> pipeline = nil;
  bool Open() {
    @autoreleasepool {
      device = MTLCreateSystemDefaultDevice();
      if (!device) return false;
      queue = [device newCommandQueue];
      MTLCompileOptions* options = [[MTLCompileOptions alloc] init];
      if (@available(macOS 15.0, *)) {
        options.mathMode = MTLMathModeSafe;
      } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        options.fastMathEnabled = NO;
#pragma clang diagnostic pop
      }
      NSError* error = nil;
      id<MTLLibrary> library = [device newLibraryWithSource:kShader options:options
                                                     error:&error];
      if (!library) return false;
      pipeline = [device newComputePipelineStateWithFunction:
          [library newFunctionWithName:@"linear_color"] error:&error];
      return queue && pipeline;
    }
  }
};

std::shared_future<std::shared_ptr<SharedGpu>> SharedPipeline() {
  // Compile once while the core probes the container and waits for network
  // bytes. Reopening a source in the player process reuses the pipeline.
  static const auto initialized = std::async(std::launch::async, [] {
    auto gpu = std::make_shared<SharedGpu>();
    return gpu->Open() ? gpu : std::shared_ptr<SharedGpu>{};
  }).share();
  return initialized;
}
}  // namespace

struct MacosColorPipeline::Impl {
  std::shared_future<std::shared_ptr<SharedGpu>> initialized = SharedPipeline();
  id<MTLBuffer> planes[3] = {nil, nil, nil};
  id<MTLBuffer> result = nil;
  id<MTLBuffer> pq = nil;
  id<MTLBuffer> hlg = nil;
  size_t capacity = 0;
  bool failed = false;

  bool Render(const AVFrame* sampled, rillight_color::Constants parameters,
              int depth, bool full, bool dovi, int transfer,
              const float* pq_table, const float* hlg_table,
              uint16_t* output, int stride) {
    @autoreleasepool {
      if (failed) return false;
      auto gpu = initialized.get();
      if (!gpu) { failed = true; return false; }
      const int width = sampled->width, height = sampled->height;
      const size_t count = static_cast<size_t>(width) * height;
      if (capacity < count) {
        for (auto& plane : planes)
          plane = [gpu->device newBufferWithLength:count * 2
                                          options:MTLResourceStorageModeShared];
        result = [gpu->device newBufferWithLength:count * 8
                                         options:MTLResourceStorageModeShared];
        capacity = count;
      }
      if (!pq) {
        pq = [gpu->device newBufferWithBytes:pq_table length:4096 * sizeof(float)
                                    options:MTLResourceStorageModeShared];
        hlg = [gpu->device newBufferWithBytes:hlg_table length:4096 * sizeof(float)
                                     options:MTLResourceStorageModeShared];
      }
      if (!planes[0] || !planes[1] || !planes[2] || !result || !pq || !hlg) {
        failed = true;
        return false;
      }
      for (int plane = 0; plane < 3; ++plane) {
        auto* destination = static_cast<uint8_t*>(planes[plane].contents);
        for (int row = 0; row < height; ++row)
          std::memcpy(destination + static_cast<size_t>(row) * width * 2,
                      sampled->data[plane] +
                          static_cast<ptrdiff_t>(row) * sampled->linesize[plane],
                      static_cast<size_t>(width) * 2);
      }
      const float maximum = static_cast<float>((1u << depth) - 1);
      const float scale = static_cast<float>(1u << (depth - 8));
      parameters.output = {static_cast<float>(width), static_cast<float>(height),
          1.0f / static_cast<float>(((1u << depth) - 1) << (16 - depth)),
          dovi ? 3.0f : transfer == AVCOL_TRC_SMPTE2084 ? 1.0f : 2.0f};
      parameters.range = {full ? 0.0f : 16 * scale / maximum,
          full ? 1.0f : maximum / (219 * scale), 128 * scale / maximum,
          full ? 1.0f : maximum / (224 * scale)};
      id<MTLCommandBuffer> commands = [gpu->queue commandBuffer];
      id<MTLComputeCommandEncoder> encoder = [commands computeCommandEncoder];
      if (!encoder) { failed = true; return false; }
      [encoder setComputePipelineState:gpu->pipeline];
      for (int plane = 0; plane < 3; ++plane)
        [encoder setBuffer:planes[plane] offset:0 atIndex:plane];
      [encoder setBuffer:result offset:0 atIndex:3];
      [encoder setBytes:&parameters length:sizeof(parameters) atIndex:4];
      [encoder setBuffer:pq offset:0 atIndex:5];
      [encoder setBuffer:hlg offset:0 atIndex:6];
      const NSUInteger group = std::min<NSUInteger>(
          gpu->pipeline.maxTotalThreadsPerThreadgroup, 256);
      [encoder dispatchThreads:MTLSizeMake(count, 1, 1)
          threadsPerThreadgroup:MTLSizeMake(group, 1, 1)];
      [encoder endEncoding];
      [commands commit];
      // The public frame owns CPU bytes. Complete this command before copying
      // them; persistent input/output buffers can then be reused safely.
      [commands waitUntilCompleted];
      if (commands.status != MTLCommandBufferStatusCompleted) {
        failed = true;
        return false;
      }
      for (int row = 0; row < height; ++row)
        std::memcpy(reinterpret_cast<uint8_t*>(output) +
                        static_cast<ptrdiff_t>(row) * stride,
                    static_cast<const uint8_t*>(result.contents) +
                        static_cast<size_t>(row) * width * 8,
                    static_cast<size_t>(width) * 8);
      return true;
    }
  }
};

MacosColorPipeline::MacosColorPipeline() : impl_(std::make_unique<Impl>()) {}
MacosColorPipeline::~MacosColorPipeline() = default;
bool MacosColorPipeline::RenderLinearHalf(
    const AVFrame* sampled, const rillight_color::Constants& parameters,
    int depth, bool full, bool dovi, int transfer, const float* pq,
    const float* hlg, uint16_t* output, int stride) {
  if (!sampled || sampled->format != AV_PIX_FMT_YUV444P16LE || !output ||
      !pq || !hlg || sampled->width <= 0 || sampled->height <= 0 ||
      sampled->width > 8192 || sampled->height > 8192 ||
      depth < 8 || depth > 16 || stride < sampled->width * 8) return false;
  for (int plane = 0; plane < 3; ++plane)
    if (!sampled->data[plane] || sampled->linesize[plane] < sampled->width * 2)
      return false;
  try {
    return impl_->Render(sampled, parameters, depth, full, dovi, transfer,
                          pq, hlg, output, stride);
  } catch (...) { return false; }
}
