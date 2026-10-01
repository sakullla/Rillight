#import "MetalEdrOutput.h"

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include <cstring>
#include <vector>

namespace rillight_macos {
namespace {

NSString* const kShader = @R"(
#include <metal_stdlib>
using namespace metal;
struct VertexOut { float4 position [[position]]; float2 uv; };
vertex VertexOut edr_vertex(uint id [[vertex_id]]) {
  const float2 corners[3] = {float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0)};
  const float2 coords[3] = {float2(0.0, 1.0), float2(2.0, 1.0), float2(0.0, -1.0)};
  VertexOut output;
  output.position = float4(corners[id], 0.0, 1.0);
  output.uv = coords[id];
  return output;
}
fragment float4 edr_fragment(VertexOut input [[stage_in]],
                             texture2d<float> image [[texture(0)]]) {
  constexpr sampler color(filter::linear, address::clamp_to_edge);
  return image.sample(color, input.uv);
}
)";

struct Presenter {
  CAMetalLayer* layer = nil;
  id<MTLDevice> device = nil;
  id<MTLCommandQueue> queue = nil;
  id<MTLRenderPipelineState> pipeline = nil;

  bool Open(CAMetalLayer* target) {
    layer = target;
    device = layer.device ?: MTLCreateSystemDefaultDevice();
    if (!device || !layer) return false;
    layer.device = device;
    queue = [device newCommandQueue];
    NSError* error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:kShader options:nil
                                                     error:&error];
    if (!library) return false;
    MTLRenderPipelineDescriptor* descriptor =
        [[MTLRenderPipelineDescriptor alloc] init];
    descriptor.vertexFunction = [library newFunctionWithName:@"edr_vertex"];
    descriptor.fragmentFunction = [library newFunctionWithName:@"edr_fragment"];
    descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;
    pipeline = [device newRenderPipelineStateWithDescriptor:descriptor
                                                       error:&error];
    return pipeline != nil && queue != nil;
  }

  bool Draw(const uint16_t* pixels, int width, int height, size_t stride) {
    if (!layer || !pipeline || width <= 0 || height <= 0 || !pixels) return false;
    std::vector<uint16_t> packed;
    const uint16_t* rows = pixels;
    size_t row_bytes = stride;
    if (stride != static_cast<size_t>(width) * 8) {
      packed.resize(static_cast<size_t>(width) * height * 4);
      for (int y = 0; y < height; ++y) {
        std::memcpy(packed.data() + static_cast<size_t>(y) * width * 4,
                    reinterpret_cast<const uint8_t*>(pixels) +
                        static_cast<size_t>(y) * stride,
                    static_cast<size_t>(width) * 8);
      }
      rows = packed.data();
      row_bytes = static_cast<size_t>(width) * 8;
    }
    MTLTextureDescriptor* description = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                      width:static_cast<NSUInteger>(width)
                                     height:static_cast<NSUInteger>(height)
                                  mipmapped:NO];
    description.usage = MTLTextureUsageShaderRead;
    description.storageMode = MTLStorageModeShared;
    id<MTLTexture> image = [device newTextureWithDescriptor:description];
    if (!image) return false;
    [image replaceRegion:MTLRegionMake2D(0, 0, static_cast<NSUInteger>(width),
                                         static_cast<NSUInteger>(height))
              mipmapLevel:0
                withBytes:rows
              bytesPerRow:row_bytes];
    const CGFloat scale = layer.contentsScale > 0 ? layer.contentsScale : 1;
    const NSSize view_pixels = layer.bounds.size;
    if (view_pixels.width >= 1 && view_pixels.height >= 1)
      layer.drawableSize = CGSizeMake(view_pixels.width * scale,
                                      view_pixels.height * scale);
    else
      layer.drawableSize = CGSizeMake(width, height);
    id<CAMetalDrawable> drawable = [layer nextDrawable];
    if (!drawable) return false;
    id<MTLCommandBuffer> commands = [queue commandBuffer];
    if (!commands) return false;
    MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = drawable.texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    id<MTLRenderCommandEncoder> encoder =
        [commands renderCommandEncoderWithDescriptor:pass];
    if (!encoder) return false;
    [encoder setRenderPipelineState:pipeline];
    [encoder setFragmentTexture:image atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];
    [commands presentDrawable:drawable];
    [commands commit];
    return true;
  }
};

void RunOnMain(void (^block)()) {
  if (NSThread.isMainThread) block();
  else dispatch_sync(dispatch_get_main_queue(), block);
}

}  // namespace

void ConfigureEdrLayer(CAMetalLayer* layer, NSScreen* screen) {
  layer.pixelFormat = MTLPixelFormatRGBA16Float;
  CGColorSpaceRef space =
      CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearDisplayP3);
  layer.colorspace = space;
  CGColorSpaceRelease(space);
  layer.wantsExtendedDynamicRangeContent = YES;
  layer.framebufferOnly = YES;
  layer.opaque = YES;
  layer.contentsGravity = kCAGravityResizeAspect;
  const CGFloat scale = screen.backingScaleFactor > 0 ? screen.backingScaleFactor : 2;
  layer.contentsScale = scale;
}

}  // namespace rillight_macos

@interface RillightEdrView : NSView
@end

@implementation RillightEdrView
- (CALayer*)makeBackingLayer {
  CAMetalLayer* layer = [CAMetalLayer layer];
  rillight_macos::ConfigureEdrLayer(layer, self.window.screen ?: NSScreen.mainScreen);
  return layer;
}
- (BOOL)isOpaque { return YES; }
@end

namespace rillight_macos {

bool CreateEdrSurface(EdrSurface* surface, NSView* flutter_view, double* headroom) {
  if (!surface) return false;
  DestroyEdrSurface(surface);
  if (headroom) *headroom = 1;
  if (!flutter_view) return false;
  __block double measured = 1;
  RunOnMain(^{
    NSScreen* screen = flutter_view.window.screen ?: NSScreen.mainScreen;
    // Potential, not the current headroom. Current stays at 1 until an
    // extended-range layer is on screen, so it cannot be the enable gate.
    if (screen)
      measured = screen.maximumPotentialExtendedDynamicRangeColorComponentValue;
  });
  surface->headroom = measured;
  if (headroom) *headroom = measured;
  if (measured <= 1.0) return false;

  __block bool opened = false;
  RunOnMain(^{
    NSView* parent = flutter_view.superview ?: flutter_view;
    RillightEdrView* view = [[RillightEdrView alloc] initWithFrame:parent.bounds];
    view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    view.wantsLayer = YES;
    CAMetalLayer* layer = (CAMetalLayer*)view.layer;
    auto* presenter = new Presenter();
    if (!presenter->Open(layer)) {
      delete presenter;
      return;
    }
    if (parent == flutter_view)
      [flutter_view addSubview:view positioned:NSWindowBelow relativeTo:nil];
    else
      [parent addSubview:view positioned:NSWindowBelow relativeTo:flutter_view];
    ConfigureEdrLayer(layer, view.window.screen ?: NSScreen.mainScreen);
    surface->view = view;
    surface->presenter = presenter;
    surface->ready = true;
    opened = true;
  });
  if (!opened) DestroyEdrSurface(surface);
  return opened;
}

void DestroyEdrSurface(EdrSurface* surface) {
  if (!surface) return;
  NSView* view = surface->view;
  auto* presenter = static_cast<Presenter*>(surface->presenter);
  surface->view = nil;
  surface->presenter = nullptr;
  surface->ready = false;
  if (view || presenter) {
    RunOnMain(^{
      [view removeFromSuperview];
    });
  }
  delete presenter;
}

void ActivateEdrSurface(EdrSurface* surface, NSView* flutter_view) {
  if (!surface || !surface->ready) return;
  RunOnMain(^{
    NSView* view = flutter_view ?: surface->view.superview;
    NSWindow* window = view.window ?: surface->view.window;
    window.opaque = NO;
    window.backgroundColor = NSColor.clearColor;
    if (view) {
      view.wantsLayer = YES;
      view.layer.opaque = NO;
      view.layer.backgroundColor = CGColorGetConstantColor(kCGColorClear);
    }
    NSViewController* controller = view.window.contentViewController;
    if ([controller isKindOfClass:[NSViewController class]])
      controller.view.layer.backgroundColor = CGColorGetConstantColor(kCGColorClear);
    surface->view.frame = (surface->view.superview ?: view).bounds;
    if ([surface->view.layer isKindOfClass:[CAMetalLayer class]])
      ConfigureEdrLayer((CAMetalLayer*)surface->view.layer,
                        window.screen ?: NSScreen.mainScreen);
  });
}

bool PresentEdrSurface(EdrSurface* surface, const uint16_t* pixels, int width,
                       int height, size_t stride) {
  if (!surface || !surface->ready || !surface->presenter) return false;
  return static_cast<Presenter*>(surface->presenter)->Draw(
      pixels, width, height, stride);
}

}  // namespace rillight_macos
