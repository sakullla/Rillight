#import "RillightPlayerPlugin.h"
#import <AppKit/AppKit.h>
#import <OpenGL/gl3.h>
#import <OpenGL/CGLIOSurface.h>
#import <IOSurface/IOSurface.h>
#import <CoreVideo/CoreVideo.h>
#include <mpv/client.h>
#include <mpv/render_gl.h>
#include <dlfcn.h>
#include <atomic>

@interface RillightSurface : NSObject <FlutterTexture> {
 @public
  mpv_handle* player;
  mpv_render_context* render;
  id<FlutterTextureRegistry> registry;
  int64_t textureId;
  dispatch_queue_t queue;
  NSOpenGLContext* context;
  NSLock* lock;
  CVPixelBufferRef latest;
  std::atomic<bool> stopped;
  std::atomic<bool> scheduled;
  std::atomic<bool> dirty;
  std::atomic<int> width;
  std::atomic<int> height;
  int64_t frames;
  NSString* error;
  void (^closed)(void);
}
- (void)start:(void (^)(NSString*))ready;
- (void)schedule;
- (void)stop:(void (^)(void))done;
@end

static void Update(void* data) { [(__bridge RillightSurface*)data schedule]; }
@implementation RillightSurface
- (instancetype)init {
  if ((self = [super init])) {
    queue = dispatch_queue_create("app.rillight.video", DISPATCH_QUEUE_SERIAL);
    lock = [[NSLock alloc] init];
    stopped = false; scheduled = false; dirty = false;
    width = 1280; height = 720; frames = 0; render = nullptr; latest = nullptr;
    error = @"";
  }
  return self;
}
- (void)start:(void (^)(NSString*))ready {
  dispatch_async(queue, ^{
    NSOpenGLPixelFormatAttribute attributes[] = {NSOpenGLPFAOpenGLProfile, NSOpenGLProfileVersion3_2Core, NSOpenGLPFAAccelerated, NSOpenGLPFAAllowOfflineRenderers, 0};
    NSOpenGLPixelFormat* format = [[NSOpenGLPixelFormat alloc] initWithAttributes:attributes];
    self->context = [[NSOpenGLContext alloc] initWithFormat:format shareContext:nil];
    if (!self->context) { ready(@"OpenGL context creation failed"); return; }
    [self->context makeCurrentContext];
    mpv_opengl_init_params gl{[](void*, const char* name) -> void* { return dlsym(RTLD_DEFAULT, name); }, nullptr};
    int advanced = 1;
    mpv_render_param params[] = {{MPV_RENDER_PARAM_API_TYPE, const_cast<char*>(MPV_RENDER_API_TYPE_OPENGL)}, {MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &gl}, {MPV_RENDER_PARAM_ADVANCED_CONTROL, &advanced}, {MPV_RENDER_PARAM_INVALID, nullptr}};
    int result = mpv_render_context_create(&self->render, self->player, params);
    if (result < 0) { ready([NSString stringWithUTF8String:mpv_error_string(result)]); return; }
    mpv_render_context_set_update_callback(self->render, Update, (__bridge void*)self);
    ready(nil);
  });
}
- (void)schedule {
  if (stopped.load()) return;
  dirty = true;
  if (scheduled.exchange(true)) return;
  dispatch_async(queue, ^{
    if (!self->stopped.load() && self->render && self->dirty.exchange(false)) {
      [self->context makeCurrentContext];
      mpv_render_context_update(self->render);
      int w = self->width.load(), h = self->height.load();
      CVPixelBufferRef buffer = nullptr;
      NSDictionary* attrs = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}, (id)kCVPixelBufferOpenGLCompatibilityKey: @YES};
      CVReturn allocated = CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)attrs, &buffer);
      GLuint image = 0, fbo = 0;
      NSString* failure = nil;
      if (allocated == kCVReturnSuccess) {
        glGenTextures(1, &image); glBindTexture(GL_TEXTURE_RECTANGLE, image);
        CGLError bound = CGLTexImageIOSurface2D(self->context.CGLContextObj, GL_TEXTURE_RECTANGLE, GL_RGBA8, w, h, GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV, CVPixelBufferGetIOSurface(buffer), 0);
        glGenFramebuffers(1, &fbo); glBindFramebuffer(GL_FRAMEBUFFER, fbo);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_RECTANGLE, image, 0);
        if (bound != kCGLNoError || glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) failure = @"IOSurface framebuffer creation failed";
        else {
          mpv_opengl_fbo target{static_cast<int>(fbo), w, h, 0}; int flip = 0, block = 0;
          mpv_render_frame_info info{};
          mpv_render_context_get_info(self->render, {MPV_RENDER_PARAM_NEXT_FRAME_INFO, &info});
          mpv_render_param params[] = {{MPV_RENDER_PARAM_OPENGL_FBO, &target}, {MPV_RENDER_PARAM_FLIP_Y, &flip}, {MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, &block}, {MPV_RENDER_PARAM_INVALID, nullptr}};
          int result = mpv_render_context_render(self->render, params);
          glFinish();
          if (result < 0) failure = [NSString stringWithUTF8String:mpv_error_string(result)];
          else {
            [self->lock lock];
            if (!self->stopped.load()) {
              if (self->latest) CVPixelBufferRelease(self->latest);
              self->latest = CVPixelBufferRetain(buffer);
              if (info.flags & MPV_RENDER_FRAME_INFO_PRESENT) self->frames++;
            }
            [self->lock unlock];
            if (!self->stopped.load()) [self->registry textureFrameAvailable:self->textureId];
            mpv_render_context_report_swap(self->render);
          }
        }
      } else failure = @"CVPixelBuffer allocation failed";
      glBindFramebuffer(GL_FRAMEBUFFER, 0); glBindTexture(GL_TEXTURE_RECTANGLE, 0);
      if (fbo) glDeleteFramebuffers(1, &fbo);
      if (image) glDeleteTextures(1, &image);
      if (buffer) CVPixelBufferRelease(buffer);
      if (failure) { [self->lock lock]; self->error = failure; [self->lock unlock]; }
    }
    self->scheduled = false;
    if (self->dirty.load() && !self->stopped.load()) [self schedule];
  });
}
- (CVPixelBufferRef)copyPixelBuffer {
  [lock lock];
  CVPixelBufferRef result = !stopped.load() && latest ? CVPixelBufferRetain(latest) : nullptr;
  [lock unlock];
  // Every publication owns a fresh IOSurface. Neither CV buffer nor GPU
  // allocation is recycled while Flutter/Metal can retain it.
  return result;
}
- (void)stop:(void (^)(void))done {
  stopped = true;
  closed = done;
  dispatch_async(queue, ^{
    // Drain all producer work before unregister; no notification can overtake it.
    dispatch_async(dispatch_get_main_queue(), ^{ [self->registry unregisterTexture:self->textureId]; });
  });
}
- (void)onTextureUnregistered:(NSObject<FlutterTexture>*)texture {
  (void)texture;
  dispatch_async(queue, ^{
    [self->context makeCurrentContext];
    if (self->render) { mpv_render_context_set_update_callback(self->render, nullptr, nullptr); mpv_render_context_free(self->render); self->render = nullptr; }
    [self->lock lock]; if (self->latest) { CVPixelBufferRelease(self->latest); self->latest = nullptr; } [self->lock unlock];
    [NSOpenGLContext clearCurrentContext]; self->context = nil;
    dispatch_async(dispatch_get_main_queue(), ^{ if (self->closed) { self->closed(); self->closed = nil; } });
  });
}
@end

@implementation RillightPlayerPlugin {
  id<FlutterTextureRegistry> _registry;
  NSMutableDictionary<NSNumber*, RillightSurface*>* _surfaces;
}
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  RillightPlayerPlugin* plugin = [[RillightPlayerPlugin alloc] init];
  plugin->_registry = registrar.textures;
  plugin->_surfaces = [NSMutableDictionary dictionary];
  FlutterMethodChannel* channel = [FlutterMethodChannel methodChannelWithName:@"rillight_player" binaryMessenger:registrar.messenger];
  [registrar addMethodCallDelegate:plugin channel:channel];
}
- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
  NSNumber* handle = call.arguments[@"handle"];
  RillightSurface* surface = _surfaces[handle];
  if ([call.method isEqualToString:@"create"]) {
    if (surface) { result([FlutterError errorWithCode:@"duplicate" message:@"Surface already exists" details:nil]); return; }
    surface = [[RillightSurface alloc] init];
    surface->player = reinterpret_cast<mpv_handle*>(handle.longLongValue);
    surface->registry = _registry;
    surface->textureId = [_registry registerTexture:surface];
    _surfaces[handle] = surface;
    [surface start:^(NSString* error) {
      dispatch_async(dispatch_get_main_queue(), ^{
        if (error) [surface stop:^{ [self->_surfaces removeObjectForKey:handle]; result([FlutterError errorWithCode:@"render" message:error details:nil]); }];
        else result(@(surface->textureId));
      });
    }];
  } else if ([call.method isEqualToString:@"dispose"]) {
    if (!surface) result(nil);
    else [surface stop:^{ [self->_surfaces removeObjectForKey:handle]; result(nil); }];
  } else if (!surface) result([FlutterError errorWithCode:@"missing" message:@"Surface unavailable" details:nil]);
  else if ([call.method isEqualToString:@"resize"]) {
    surface->width = MAX(1, MIN(7680, [call.arguments[@"width"] intValue])); surface->height = MAX(1, MIN(4320, [call.arguments[@"height"] intValue]));
    [surface schedule]; result(nil);
  } else if ([call.method isEqualToString:@"status"]) {
    [surface->lock lock]; NSDictionary* status = @{@"frames": @(surface->frames), @"error": surface->error}; [surface->lock unlock]; result(status);
  } else result(FlutterMethodNotImplemented);
}
@end
