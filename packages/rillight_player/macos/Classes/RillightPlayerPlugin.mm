#import "RillightPlayerPlugin.h"
#import <CoreVideo/CoreVideo.h>
#import <IOSurface/IOSurface.h>
#import <Foundation/Foundation.h>

#include "../../native/core/rillight_core.h"
#include "CoreAudioOutput.h"
#include "FrameOutput.h"
#include "FrameTiming.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstring>
#include <memory>

using Clock = std::chrono::steady_clock;

@interface RillightSurface : NSObject <FlutterTexture> {
 @public
  RillightCore* core;  // Owned by Dart; Dart destroys it after dispose returns.
  id<FlutterTextureRegistry> registry;
  int64_t textureId;
  NSLock* lock;
  CVPixelBufferRef latest;
  std::atomic<bool> stopped;
  std::atomic<bool> detached;
  std::atomic<int> width;
  std::atomic<int> height;
  int64_t frames;
  NSString* error;
  uint32_t actualHardware;
}
- (void)start:(void (^)(NSString* error))ready;
- (BOOL)detach;
- (void)retire:(void (^)(void))done;
- (void)resizeWidth:(int)w height:(int)h;
@end

@implementation RillightSurface {
  dispatch_queue_t _queue;
  dispatch_source_t _timer;
  NSMutableArray* _closeBlocks;
  std::unique_ptr<rillight_macos::CoreAudioOutput> _audio;
  RillightCoreFrame* _pendingAudio;
  int _audioOffset;
  RillightCoreFrame* _pendingVideo;
  RillightCoreFrame* _lastVideo;
  uint64_t _session;
  uint64_t _timeline;
  int _renderedWidth;
  int _renderedHeight;
  int64_t _audioEndPts;
  double _audioSpeed;
  bool _audioClockStarted;
  bool _audioHandedOff;
  bool _audioPaused;
  Clock::time_point _audioGapSince;
  Clock::time_point _audioStartupSince;
  Clock::time_point _firstAudioWriteSince;
}

- (instancetype)init {
  if ((self = [super init])) {
    _queue = dispatch_queue_create("app.rillight.core.macos", DISPATCH_QUEUE_SERIAL);
    _closeBlocks = [NSMutableArray array];
    lock = [[NSLock alloc] init];
    latest = nullptr;
    stopped = false;
    detached = false;
    width = 1280;
    height = 720;
    frames = 0;
    error = @"";
    actualHardware = 0;
    _audioEndPts = -1;
    _audioSpeed = 1.0;
  }
  return self;
}

- (void)setFailure:(NSString*)failure {
  [lock lock];
  error = failure;
  [lock unlock];
}

- (void)start:(void (^)(NSString*))ready {
  dispatch_async(_queue, ^{
    if (rillight_core_abi_version() != RILLIGHT_CORE_ABI_VERSION) {
      dispatch_async(dispatch_get_main_queue(), ^{ ready(@"Core ABI mismatch"); });
      return;
    }
    // DesktopCorePlayer awaits texture creation before calling core_open.
    // Prefer VideoToolbox for this session, with the owned software decoder
    // available when a device or codec cannot use hardware acceleration.
    if (rillight_core_configure_hardware(
            self->core, RILLIGHT_CORE_HW_VIDEOTOOLBOX, 1) != 0) {
      dispatch_async(dispatch_get_main_queue(), ^{
        ready(@"Core VideoToolbox preference could not be configured");
      });
      return;
    }
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self->_queue);
    dispatch_source_set_timer(_timer, dispatch_time(DISPATCH_TIME_NOW, 0),
                              5 * NSEC_PER_MSEC, NSEC_PER_MSEC);
    dispatch_source_set_event_handler(_timer, ^{ [self tick]; });
    dispatch_resume(_timer);
    dispatch_async(dispatch_get_main_queue(), ^{ ready(nil); });
  });
}

- (void)releasePending {
  if (_pendingAudio) {
    rillight_core_release_frame(_pendingAudio);
    _pendingAudio = nullptr;
  }
  _audioOffset = 0;
  if (_pendingVideo) {
    rillight_core_release_frame(_pendingVideo);
    _pendingVideo = nullptr;
  }
  if (_lastVideo) {
    rillight_core_release_frame(_lastVideo);
    _lastVideo = nullptr;
  }
}

- (void)publish:(const rillight_macos::PixelFrame&)pixels newFrame:(BOOL)newFrame
        session:(uint64_t)session timeline:(uint64_t)timeline {
  if (stopped.load() || !pixels.width || !pixels.height) return;
  NSDictionary* attributes = @{
    (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    (id)kCVPixelBufferMetalCompatibilityKey: @YES,
  };
  CVPixelBufferRef buffer = nullptr;
  const CVReturn created = CVPixelBufferCreate(
      kCFAllocatorDefault, pixels.width, pixels.height,
      kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)attributes, &buffer);
  if (created != kCVReturnSuccess || !buffer) {
    [self setFailure:@"CVPixelBuffer/IOSurface allocation failed"];
    return;
  }
  if (!CVPixelBufferGetIOSurface(buffer)) {
    [self setFailure:@"CVPixelBuffer has no IOSurface"];
    CVPixelBufferRelease(buffer);
    return;
  }
  if (CVPixelBufferLockBaseAddress(buffer, 0) != kCVReturnSuccess) {
    [self setFailure:@"CVPixelBuffer lock failed"];
    CVPixelBufferRelease(buffer);
    return;
  }
  auto* base = static_cast<uint8_t*>(CVPixelBufferGetBaseAddress(buffer));
  const size_t stride = CVPixelBufferGetBytesPerRow(buffer);
  for (int y = 0; y < pixels.height; ++y)
    std::memcpy(base + static_cast<size_t>(y) * stride,
                pixels.bgra.data() + static_cast<size_t>(y) * pixels.width * 4,
                static_cast<size_t>(pixels.width) * 4);
  CVPixelBufferUnlockBaseAddress(buffer, 0);
  RillightCoreSnapshot current{};
  current.struct_size = sizeof(current);
  if (!stopped.load() && rillight_core_snapshot(core, &current) == 0 &&
      current.session_id == session && current.timeline_version == timeline) {
    [lock lock];
    if (!stopped.load()) {
      CVPixelBufferRef old = latest;
      latest = CVPixelBufferRetain(buffer);
      if (newFrame) ++frames;
      if (old) CVPixelBufferRelease(old);
    }
    [lock unlock];
    dispatch_async(dispatch_get_main_queue(), ^{
      if (!self->stopped.load())
        [self->registry textureFrameAvailable:self->textureId];
    });
  }
  CVPixelBufferRelease(buffer);
}

- (void)clearImage {
  [lock lock];
  if (latest) { CVPixelBufferRelease(latest); latest = nullptr; }
  frames = 0;
  actualHardware = 0;
  [lock unlock];
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!self->stopped.load())
      [self->registry textureFrameAvailable:self->textureId];
  });
}

- (void)reportAudio:(const RillightCoreSnapshot&)snapshot delay:(int64_t)delay {
  if (_audioEndPts < 0 || delay < 0) return;
  RillightCoreSnapshot current{};
  current.struct_size = sizeof(current);
  if (rillight_core_snapshot(core, &current) != 0 ||
      current.session_id != snapshot.session_id ||
      current.timeline_version != snapshot.timeline_version) return;
  if (rillight_core_report_audio_played(
          core, snapshot.session_id, snapshot.timeline_version, _audioEndPts,
          static_cast<int64_t>(delay * _audioSpeed)) == 0) {
    _audioClockStarted = true;
    _audioHandedOff = false;
  }
}

- (void)tick {
  if (stopped.load()) return;
  RillightCoreSnapshot snapshot{};
  snapshot.struct_size = sizeof(snapshot);
  if (rillight_core_snapshot(core, &snapshot) != 0 ||
      snapshot.abi_version != RILLIGHT_CORE_ABI_VERSION) {
    [self setFailure:@"Core snapshot unavailable"];
    return;
  }
  if (snapshot.session_id != _session || snapshot.timeline_version != _timeline) {
    if (_audio) _audio->Reset();
    [self releasePending];
    _session = snapshot.session_id;
    _timeline = snapshot.timeline_version;
    _renderedWidth = _renderedHeight = 0;
    _audioEndPts = -1;
    _audioClockStarted = _audioHandedOff = _audioPaused = false;
    _audioGapSince = _audioStartupSince = _firstAudioWriteSince = {};
    [self clearImage];
  }

  if (snapshot.video_stream_index >= 0) {
    const int tracks = rillight_core_track_count(core);
    for (int i = 0; i < tracks; ++i) {
      RillightCoreTrack track{};
      track.struct_size = sizeof(track);
      if (rillight_core_get_track(core, i, &track) == 0 &&
          track.type == RILLIGHT_CORE_TRACK_VIDEO &&
          track.stream_index == snapshot.video_stream_index) {
        [lock lock]; actualHardware = track.actual_hardware; [lock unlock];
        break;
      }
    }
  }

  if (snapshot.audio_stream_index >= 0 && !_audio &&
      snapshot.state == RILLIGHT_CORE_PLAYING) {
    _audio = std::make_unique<rillight_macos::CoreAudioOutput>();
  }
  if (_audio && !_audio->error().empty()) {
    [self setFailure:[NSString stringWithUTF8String:_audio->error().c_str()]];
    return;
  }
  if (_audio && snapshot.state == RILLIGHT_CORE_PAUSED && !_audioPaused) {
    [self reportAudio:snapshot delay:_audio->DelayUs()];
    _audio->Pause(true);
    _audioPaused = true;
  } else if (_audio && snapshot.state == RILLIGHT_CORE_PLAYING && _audioPaused) {
    _audio->Pause(false);
    _audioPaused = false;
  }
  if (_audio && _audioEndPts >= 0 &&
      (snapshot.state == RILLIGHT_CORE_PLAYING ||
       snapshot.state == RILLIGHT_CORE_BUFFERING))
    [self reportAudio:snapshot delay:_audio->DelayUs()];

  bool waitingFutureAudio = false;
  if (_audio && snapshot.state == RILLIGHT_CORE_PLAYING) {
    for (int attempts = 0; attempts < 8; ++attempts) {
      if (!_pendingAudio) {
        _pendingAudio = rillight_core_take_frame(core, RILLIGHT_CORE_AUDIO_S16);
        _audioOffset = 0;
      }
      if (!_pendingAudio) break;
      auto* frame = _pendingAudio;
      if (frame->session_id != snapshot.session_id ||
          frame->timeline_version != snapshot.timeline_version ||
          frame->sample_rate != 48000 || frame->channels != 2 ||
          frame->sample_count <= 0 ||
          static_cast<int64_t>(frame->sample_count) * 4 != frame->data_size ||
          !frame->data) {
        rillight_core_release_frame(frame);
        _pendingAudio = nullptr;
        continue;
      }
      if (frame->pts_us >= 0 &&
          frame->pts_us > snapshot.position_us + 50000) {
        waitingFutureAudio = true;
        break;
      }
      if (!_audioClockStarted && frame->pts_us >= 0) {
        if (snapshot.position_us > frame->pts_us && snapshot.playback_speed > 0) {
          const double late = (snapshot.position_us - frame->pts_us) * 48000.0 /
                              (1000000.0 * snapshot.playback_speed);
          _audioOffset = std::max(_audioOffset,
              static_cast<int>(std::min<double>(frame->sample_count,
                                               std::ceil(late))) * 4);
        }
      }
      if (_audioOffset >= frame->data_size) {
        rillight_core_release_frame(frame);
        _pendingAudio = nullptr;
        continue;
      }
      const size_t written = _audio->Write(frame->data + _audioOffset,
                                            frame->data_size - _audioOffset);
      if (!written) break;
      if (_audioHandedOff) {
        _audioHandedOff = false;
        _audioEndPts = -1;
        _firstAudioWriteSince = {};
      }
      _audioOffset += static_cast<int>(written);
      if (frame->pts_us >= 0) {
        if (_firstAudioWriteSince == Clock::time_point{})
          _firstAudioWriteSince = Clock::now();
        _audioEndPts = frame->pts_us + static_cast<int64_t>(
            (_audioOffset / 4.0) * 1000000.0 / 48000.0 *
            snapshot.playback_speed);
        _audioSpeed = snapshot.playback_speed;
        [self reportAudio:snapshot delay:_audio->DelayUs()];
      }
      if (_audioOffset == frame->data_size) {
        rillight_core_release_frame(frame);
        _pendingAudio = nullptr;
      }
    }
  }
  if (_audio && !_audio->error().empty()) {
    [self setFailure:[NSString stringWithUTF8String:_audio->error().c_str()]];
    return;
  }
  const int64_t delay = _audio ? _audio->DelayUs() : 0;
  const auto now = Clock::now();
  if (_audioClockStarted && snapshot.state == RILLIGHT_CORE_PLAYING &&
      snapshot.queued_video_frames > 0 && snapshot.queued_audio_frames == 0 &&
      (!_pendingAudio || waitingFutureAudio) &&
      delay >= 0 && delay <= 1000) {
    if (_audioGapSince == Clock::time_point{}) _audioGapSince = now;
    if (!_audioHandedOff && now - _audioGapSince > std::chrono::milliseconds(150) &&
        rillight_core_report_audio_unavailable(
            core, snapshot.session_id, snapshot.timeline_version) == 0) {
      _audio->Reset();  // New PCM starts from a fresh device sample timeline.
      _audioHandedOff = true;
      _audioClockStarted = false;
      _audioEndPts = -1;
      _firstAudioWriteSince = {};
    }
  } else _audioGapSince = {};

  bool holdVideo = false;
  if (snapshot.state == RILLIGHT_CORE_PLAYING &&
      snapshot.audio_stream_index >= 0 && !_audioClockStarted &&
      !_audioHandedOff) {
    if (_audioStartupSince == Clock::time_point{}) _audioStartupSince = now;
    if (_firstAudioWriteSince != Clock::time_point{} &&
        now - _firstAudioWriteSince > std::chrono::seconds(2)) {
      [self setFailure:@"Core Audio playback clock unavailable"];
      return;
    }
    holdVideo = (_pendingAudio && _pendingAudio->pts_us >= 0 &&
                 _pendingAudio->pts_us <= snapshot.position_us + 50000) ||
                _audioEndPts >= 0 ||
                now - _audioStartupSince < std::chrono::milliseconds(150);
  } else _audioStartupSince = {};
  if (!holdVideo && !_pendingVideo)
    _pendingVideo = rillight_core_take_frame(core, RILLIGHT_CORE_VIDEO_RGBA);
  if (_pendingVideo) {
    const bool current = _pendingVideo->session_id == snapshot.session_id &&
                         _pendingVideo->timeline_version == snapshot.timeline_version;
    if (!current || !rillight_macos::ValidSource(*_pendingVideo)) {
      if (current) [self setFailure:@"Core returned invalid RGBA frame"];
      rillight_core_release_frame(_pendingVideo);
      _pendingVideo = nullptr;
    } else if (!holdVideo &&
               rillight_macos::VideoDue(*_pendingVideo, snapshot)) {
      const bool tooLate = rillight_macos::VideoTooLate(*_pendingVideo,
                                                        snapshot);
      if (!tooLate) {
        if (_lastVideo) rillight_core_release_frame(_lastVideo);
        _lastVideo = _pendingVideo;
        _pendingVideo = nullptr;
        const int w = width.load(), h = height.load();
        [self publish:rillight_macos::Present(*_lastVideo, w, h) newFrame:YES
              session:snapshot.session_id timeline:snapshot.timeline_version];
        _renderedWidth = w; _renderedHeight = h;
      } else {
        rillight_core_release_frame(_pendingVideo);
        _pendingVideo = nullptr;
      }
    }
  }
  if (_lastVideo &&
      (_renderedWidth != width.load() || _renderedHeight != height.load())) {
    const int w = width.load(), h = height.load();
    [self publish:rillight_macos::Present(*_lastVideo, w, h) newFrame:NO
          session:snapshot.session_id timeline:snapshot.timeline_version];
    _renderedWidth = w; _renderedHeight = h;
  }

  if (snapshot.source_eof && snapshot.queued_video_frames == 0 &&
      snapshot.queued_audio_frames == 0 && !_pendingAudio && !_pendingVideo &&
      delay >= 0 && delay < 10000)
    rillight_core_report_output_drained(core, snapshot.session_id,
                                       snapshot.timeline_version);
}

- (CVPixelBufferRef)copyPixelBuffer {
  [lock lock];
  CVPixelBufferRef result = !stopped.load() && latest ?
      CVPixelBufferRetain(latest) : nullptr;
  [lock unlock];
  return result;
}

- (void)resizeWidth:(int)w height:(int)h {
  width = std::clamp(w, 1, 4096);
  height = std::clamp(h, 1, 2304);
}

- (BOOL)detach {
  // Platform thread. Queue unregister without waiting for Impeller's raster
  // callback; Dart fences remaining copyPixelBuffer work with a picture snapshot.
  stopped.store(true);
  if (detached.exchange(true)) return YES;
  dispatch_sync(_queue, ^{
    if (self->_timer) {
      dispatch_source_cancel(self->_timer);
      self->_timer = nil;
    }
    [self releasePending];
    self->_audio.reset();
  });
  [registry unregisterTexture:textureId];
  return YES;
}

- (void)retire:(void (^)(void))done {
  if (done) [_closeBlocks addObject:[done copy]];
  [lock lock];
  if (latest) {
    CVPixelBufferRelease(latest);
    latest = nullptr;
  }
  [lock unlock];
  NSArray* callbacks = [_closeBlocks copy];
  [_closeBlocks removeAllObjects];
  for (id entry in callbacks) {
    void (^callback)(void) = entry;
    callback();
  }
}

- (void)onTextureUnregistered:(NSObject<FlutterTexture>*)texture {
  (void)texture;
  [lock lock];
  if (latest) {
    CVPixelBufferRelease(latest);
    latest = nullptr;
  }
  [lock unlock];
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
  FlutterMethodChannel* channel = [FlutterMethodChannel
      methodChannelWithName:@"rillight_player" binaryMessenger:registrar.messenger];
  [registrar addMethodCallDelegate:plugin channel:channel];
}

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
  NSDictionary* arguments = [call.arguments isKindOfClass:[NSDictionary class]] ?
      call.arguments : @{};
  NSNumber* handle = arguments[@"handle"];
  if (![handle isKindOfClass:[NSNumber class]] || handle.longLongValue == 0) {
    result([FlutterError errorWithCode:@"handle" message:@"Invalid core handle"
                                details:nil]);
    return;
  }
  RillightSurface* surface = _surfaces[handle];
  if ([call.method isEqualToString:@"create"]) {
    if (surface) {
      result([FlutterError errorWithCode:@"duplicate"
                                    message:@"Surface already exists" details:nil]);
      return;
    }
    surface = [[RillightSurface alloc] init];
    surface->core = reinterpret_cast<RillightCore*>(handle.longLongValue);
    surface->registry = _registry;
    surface->textureId = [_registry registerTexture:surface];
    _surfaces[handle] = surface;
    [surface start:^(NSString* failure) {
      if (failure) {
        [surface detach];
        [surface retire:^{
          if (self->_surfaces[handle] == surface)
            [self->_surfaces removeObjectForKey:handle];
          result([FlutterError errorWithCode:@"render" message:failure
                                      details:nil]);
        }];
      } else result(@(surface->textureId));
    }];
  } else if ([call.method isEqualToString:@"detach"]) {
    result(surface ? @([surface detach]) : @NO);
  } else if ([call.method isEqualToString:@"dispose"]) {
    if (!surface) result(nil);
    else if (!surface->detached.load()) {
      result([FlutterError errorWithCode:@"retirement"
                                 message:@"Detach and raster barrier required"
                                 details:nil]);
    } else {
      [surface retire:^{
        if (self->_surfaces[handle] == surface)
          [self->_surfaces removeObjectForKey:handle];
        result(nil);
      }];
    }
  } else if (!surface) {
    result([FlutterError errorWithCode:@"missing"
                                  message:@"Surface unavailable" details:nil]);
  } else if ([call.method isEqualToString:@"resize"]) {
    [surface resizeWidth:[arguments[@"width"] intValue]
                 height:[arguments[@"height"] intValue]];
    result(nil);
  } else if ([call.method isEqualToString:@"status"]) {
    RillightCoreSnapshot snapshot{};
    snapshot.struct_size = sizeof(snapshot);
    const bool hasSnapshot = rillight_core_snapshot(surface->core, &snapshot) == 0;
    [surface->lock lock];
    NSString* decoder = !hasSnapshot || snapshot.video_stream_index < 0 ?
        @"none" : !snapshot.first_video_frame_ready ? @"pending" :
        surface->actualHardware == RILLIGHT_CORE_HW_VIDEOTOOLBOX ?
        @"videotoolbox" : @"software";
    NSDictionary* status = @{@"frames": @(surface->frames),
                             @"error": surface->error,
                             @"actualHardware": @(surface->actualHardware),
                             @"preferredHardware": @(hasSnapshot ?
                                 snapshot.preferred_hardware : 0),
                             @"allowSoftwareFallback": @(hasSnapshot &&
                                 snapshot.allow_software_fallback != 0),
                             @"decoder": decoder,
                             @"session": @(hasSnapshot ? snapshot.session_id : 0),
                             @"timeline": @(hasSnapshot ? snapshot.timeline_version : 0)};
    [surface->lock unlock];
    result(status);
  } else result(FlutterMethodNotImplemented);
}
@end
