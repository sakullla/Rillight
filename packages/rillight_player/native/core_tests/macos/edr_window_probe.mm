#include "../../core/rillight_core.h"

#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

namespace {
struct FileSession { std::string path; };

void* Open(void* opaque, const char* url, int) {
  auto* session = static_cast<FileSession*>(opaque);
  if (!url || session->path != url) return nullptr;
  return std::fopen(url, "rb");
}
int Read(void*, void* handle, uint8_t* bytes, int size) {
  auto* file = static_cast<FILE*>(handle);
  if (!file || !bytes || size <= 0) return -1;
  const size_t count = std::fread(bytes, 1, static_cast<size_t>(size), file);
  if (count > 0) return static_cast<int>(count);
  return std::ferror(file) ? -5 : 0;
}
int64_t Seek(void*, void* handle, int64_t offset, int whence) {
  auto* file = static_cast<FILE*>(handle);
  if (!file) return -1;
  if (whence == 0x10000) {
    const long previous = std::ftell(file);
    if (std::fseek(file, 0, SEEK_END) != 0) return -1;
    const long size = std::ftell(file);
    std::fseek(file, previous, SEEK_SET);
    return size;
  }
  if (std::fseek(file, offset, whence & 0xffff) != 0) return -1;
  return std::ftell(file);
}
void Close(void*, void* handle) { if (handle) std::fclose(static_cast<FILE*>(handle)); }
void Cancel(void*) {}

RillightCoreFrame* FirstHalfFrame(const char* path) {
  static FileSession session;
  session.path = path;
  RillightCoreIo io{&session, Open, Read, Seek, Close, Cancel, Cancel};
  RillightCore* core = rillight_core_create(&io);
  if (!core || rillight_core_configure_macos_edr(core, 1) != 0 ||
      rillight_core_configure_hardware(core, RILLIGHT_CORE_HW_VIDEOTOOLBOX, 1) != 0 ||
      rillight_core_open(core, path, 1) != 0) return nullptr;
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(15);
  while (std::chrono::steady_clock::now() < deadline) {
    RillightCoreFrame* frame = rillight_core_take_frame(core, RILLIGHT_CORE_VIDEO_RGBA);
    if (frame && frame->type == RILLIGHT_CORE_VIDEO_RGBA16F) return frame;
    if (frame) rillight_core_release_frame(frame);
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  }
  return nullptr;
}
}

@interface Probe : NSObject
@property NSWindow* window;
@property CAMetalLayer* layer;
@property id<MTLDevice> device;
@property id<MTLCommandQueue> queue;
@property id<MTLRenderPipelineState> pipeline;
@end
@implementation Probe
@end

int main(int argc, char** argv) {
  @autoreleasepool {
    if (argc != 2) return 1;
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    RillightCoreFrame* frame = FirstHalfFrame(argv[1]);
    if (!frame) {
      std::fprintf(stderr, "no half frame\n");
      return 2;
    }
    NSScreen* screen = NSScreen.mainScreen;
    const double before = screen.maximumExtendedDynamicRangeColorComponentValue;
    const double potential = screen.maximumPotentialExtendedDynamicRangeColorComponentValue;
    Probe* probe = [Probe new];
    probe.device = MTLCreateSystemDefaultDevice();
    probe.queue = [probe.device newCommandQueue];
    NSString* shader = @R"(
#include <metal_stdlib>
using namespace metal;
struct VertexOut { float4 position [[position]]; float2 uv; };
vertex VertexOut edr_vertex(uint id [[vertex_id]]) {
  const float2 corners[3] = {float2(-1,-1), float2(3,-1), float2(-1,3)};
  const float2 coords[3] = {float2(0,1), float2(2,1), float2(0,-1)};
  VertexOut output;
  output.position = float4(corners[id], 0, 1);
  output.uv = coords[id];
  return output;
}
fragment float4 edr_fragment(VertexOut input [[stage_in]], texture2d<float> image [[texture(0)]]) {
  constexpr sampler color(filter::nearest, address::clamp_to_edge);
  return image.sample(color, input.uv);
}
)";
    NSError* error = nil;
    id<MTLLibrary> library = [probe.device newLibraryWithSource:shader options:nil error:&error];
    if (!library) {
      std::fprintf(stderr, "library failed: %s\n",
                   error.localizedDescription.UTF8String);
      return 3;
    }
    id<MTLFunction> vertex = [library newFunctionWithName:@"edr_vertex"];
    id<MTLFunction> fragment = [library newFunctionWithName:@"edr_fragment"];
    if (!vertex || !fragment) {
      std::fprintf(stderr, "functions missing vertex=%d fragment=%d\n",
                   vertex != nil, fragment != nil);
      return 3;
    }
    MTLRenderPipelineDescriptor* descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.vertexFunction = vertex;
    descriptor.fragmentFunction = fragment;
    descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;
    probe.pipeline = [probe.device newRenderPipelineStateWithDescriptor:descriptor error:&error];
    if (!probe.pipeline) {
      std::fprintf(stderr, "pipeline failed\n");
      return 3;
    }
    probe.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(80, 80, 640, 360)
                                                styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                  backing:NSBackingStoreBuffered defer:NO];
    probe.window.title = @"Rillight EDR probe";
    probe.window.opaque = YES;
    NSView* view = probe.window.contentView;
    view.wantsLayer = YES;
    probe.layer = [CAMetalLayer layer];
    probe.layer.device = probe.device;
    probe.layer.pixelFormat = MTLPixelFormatRGBA16Float;
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearDisplayP3);
    probe.layer.colorspace = space;
    CGColorSpaceRelease(space);
    probe.layer.wantsExtendedDynamicRangeContent = YES;
    probe.layer.framebufferOnly = NO;
    probe.layer.contentsScale = screen.backingScaleFactor > 0 ? screen.backingScaleFactor : 2;
    probe.layer.drawableSize = CGSizeMake(640 * probe.layer.contentsScale,
                                          360 * probe.layer.contentsScale);
    view.wantsLayer = YES;
    view.layer = probe.layer;
    [probe.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    MTLTextureDescriptor* description = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                      width:frame->width height:frame->height mipmapped:NO];
    description.usage = MTLTextureUsageShaderRead;
    description.storageMode = MTLStorageModeShared;
    id<MTLTexture> image = [probe.device newTextureWithDescriptor:description];
    [image replaceRegion:MTLRegionMake2D(0, 0, frame->width, frame->height)
             mipmapLevel:0 withBytes:frame->data bytesPerRow:frame->stride];
    double peak_headroom = before;
    for (int repeat = 0; repeat < 80; ++repeat) {
      id<CAMetalDrawable> drawable = [probe.layer nextDrawable];
      if (!drawable) break;
      id<MTLCommandBuffer> commands = [probe.queue commandBuffer];
      MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
      pass.colorAttachments[0].texture = drawable.texture;
      pass.colorAttachments[0].loadAction = MTLLoadActionClear;
      pass.colorAttachments[0].storeAction = MTLStoreActionStore;
      pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
      id<MTLRenderCommandEncoder> encoder = [commands renderCommandEncoderWithDescriptor:pass];
      [encoder setRenderPipelineState:probe.pipeline];
      [encoder setFragmentTexture:image atIndex:0];
      [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
      [encoder endEncoding];
      id<MTLBuffer> readback = nil;
      NSUInteger read_width = 0;
      NSUInteger read_height = 0;
      if (repeat == 10) {
        read_width = drawable.texture.width;
        read_height = drawable.texture.height;
        const NSUInteger row_bytes = read_width * 8;
        readback = [probe.device newBufferWithLength:row_bytes * read_height
                                             options:MTLResourceStorageModeShared];
        id<MTLBlitCommandEncoder> blit = [commands blitCommandEncoder];
        [blit copyFromTexture:drawable.texture sourceSlice:0 sourceLevel:0
                 sourceOrigin:MTLOriginMake(0, 0, 0)
                   sourceSize:MTLSizeMake(read_width, read_height, 1)
                     toBuffer:readback destinationOffset:0
                destinationBytesPerRow:row_bytes
           destinationBytesPerImage:row_bytes * read_height];
        [blit endEncoding];
      }
      [commands presentDrawable:drawable];
      [commands commit];
      [commands waitUntilCompleted];
      if (readback) {
        const auto* sample = static_cast<const uint16_t*>(readback.contents);
        auto half = [](uint16_t bits) {
          const uint32_t sign = static_cast<uint32_t>(bits & 0x8000u) << 16;
          const uint32_t exponent = (bits >> 10) & 0x1fu;
          const uint32_t mantissa = bits & 0x3ffu;
          uint32_t value = exponent == 0 ? sign :
              exponent == 31 ? sign | 0x7f800000u | (mantissa << 13) :
              sign | ((exponent + 112) << 23) | (mantissa << 13);
          float decoded = 0;
          std::memcpy(&decoded, &value, sizeof(decoded));
          return decoded;
        };
        float max_value = 0;
        int above = 0;
        const NSUInteger count = read_width * read_height;
        for (NSUInteger pixel = 0; pixel < count; ++pixel) {
          for (int channel = 0; channel < 3; ++channel) {
            const float value = half(sample[pixel * 4 + channel]);
            if (value > max_value) max_value = value;
            if (value > 1.0f) ++above;
          }
        }
        std::printf("drawable %lux%lu max=%.3f above_one=%d\n",
                    static_cast<unsigned long>(read_width),
                    static_cast<unsigned long>(read_height), max_value, above);
      }
      [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
      const double now = probe.window.screen.maximumExtendedDynamicRangeColorComponentValue;
      if (now > peak_headroom) peak_headroom = now;
    }
    const double after = probe.window.screen.maximumExtendedDynamicRangeColorComponentValue;
    const int pid = [[NSProcessInfo processInfo] processIdentifier];
    int window_id = 0;
    CGRect window_rect = CGRectZero;
    CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID);
    if (list) {
      const CFIndex count = CFArrayGetCount(list);
      for (CFIndex i = 0; i < count; ++i) {
        CFDictionaryRef info = static_cast<CFDictionaryRef>(CFArrayGetValueAtIndex(list, i));
        int owner = 0;
        CFNumberRef owner_value = static_cast<CFNumberRef>(CFDictionaryGetValue(info, kCGWindowOwnerPID));
        if (owner_value) CFNumberGetValue(owner_value, kCFNumberIntType, &owner);
        if (owner != pid) continue;
        CGRect rect = CGRectZero;
        CFDictionaryRef bounds = static_cast<CFDictionaryRef>(CFDictionaryGetValue(info, kCGWindowBounds));
        if (!bounds || !CGRectMakeWithDictionaryRepresentation(bounds, &rect)) continue;
        if (rect.size.width < 200 || rect.size.height < 100) continue;
        window_rect = rect;
        CFNumberRef number = static_cast<CFNumberRef>(CFDictionaryGetValue(info, kCGWindowNumber));
        if (number) CFNumberGetValue(number, kCFNumberIntType, &window_id);
      }
      CFRelease(list);
    }
    if (window_rect.size.width > 0) {
      char command[320];
      std::snprintf(command, sizeof command,
                    "screencapture -x -R %.0f,%.0f,%.0f,%.0f build/macos-edr-probe/window.png",
                    window_rect.origin.x, window_rect.origin.y,
                    window_rect.size.width, window_rect.size.height);
      std::system(command);
    }
    std::printf("headroom before=%.3f after=%.3f peak=%.3f potential=%.3f window=%d colorspace=%d\n",
                before, after, peak_headroom, potential, window_id,
                probe.layer.wantsExtendedDynamicRangeContent);
    std::fflush(stdout);
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:3]];
    return 0;
  }
}
