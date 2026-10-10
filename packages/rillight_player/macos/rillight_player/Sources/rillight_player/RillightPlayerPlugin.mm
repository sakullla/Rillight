#import "include/rillight_player/RillightPlayerPlugin.h"
#import <CoreVideo/CoreVideo.h>
#import <IOSurface/IOSurface.h>
#import <Foundation/Foundation.h>

#include "rillight_core.h"
#include "CoreAudioOutput.h"
#include "FrameOutput.h"
#include "FrameTiming.h"
#include "MetalEdrOutput.h"
#include "PixelBufferOutput.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstring>
#include <memory>
#include <vector>

using Clock = std::chrono::steady_clock;

static OSStatus RillightDefaultOutputChanged(AudioObjectID, UInt32,
    const AudioObjectPropertyAddress *, void *client) {
  if (client) static_cast<std::atomic<bool> *>(client)->store(true);
  return noErr;
}

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
  std::atomic<bool> notificationPending;
  int64_t frames;
  int64_t copiedFrames;
  int64_t lateFrames;
  int64_t conversionUs;
  int64_t maxConversionUs;
  int64_t presentIntervalUs;
  NSString* error;
  uint32_t actualHardware;
  NSView* flutterView;
}
- (void)start:(void (^)(NSString* error))ready;
- (BOOL)detach;
- (void)retire:(void (^)(void))done;
- (void)resizeWidth:(int)w height:(int)h;
- (void)activateOverlay;
- (BOOL)extendedOutput;
- (BOOL)lastFrameLinear;
- (double)edrHeadroom;
- (rillight_macos::EdrPresentationStats)presentationStats;
@end

@implementation RillightSurface {
  dispatch_queue_t _queue;
  dispatch_source_t _timer;
  dispatch_queue_t _audioQueue;
  dispatch_source_t _audioTimer;
  uint64_t _audioSession, _audioTimeline;
  // Protected by lock; no device objects are shared with the video queue.
  uint64_t _outputSession, _outputTimeline;
  bool _holdVideo, _audioDrained;
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
  bool _needsPublication;
  bool _newFramePending;
  rillight_macos::PixelBufferOutput _videoOutput;
  int64_t _audioEndPts;
  double _audioSpeed;
  bool _audioClockStarted;
  bool _audioHandedOff;
  bool _audioPaused;
  Clock::time_point _audioGapSince;
  Clock::time_point _audioStartupSince;
  Clock::time_point _firstAudioWriteSince;
  rillight_macos::EdrSurface _edr;
  std::vector<uint16_t> _linear;
  bool _lastHalf;
  bool _usingEdr;
  bool _havePresent;
  Clock::time_point _lastPresent;
  int _hardwareStream;
  int _hardwareTicks;
  int _pcmChannels;
  AudioDeviceID _audioDevice;
  uint32_t _audioAccept, _rejectedAudioFormats;
  bool _routeListener;
  std::atomic<bool> _routeChanged;
}

- (rillight_macos::EdrPresentationStats)presentationStats {
  return rillight_macos::ReadEdrPresentationStats(&_edr);
}

- (instancetype)init {
  if ((self = [super init])) {
    _queue = dispatch_queue_create("app.rillight.core.macos", DISPATCH_QUEUE_SERIAL);
    _audioQueue = dispatch_queue_create("app.rillight.core.macos.audio", DISPATCH_QUEUE_SERIAL);
    _closeBlocks = [NSMutableArray array];
    lock = [[NSLock alloc] init];
    latest = nullptr;
    stopped = false;
    detached = false;
    notificationPending = false;
    width = 1280;
    height = 720;
    frames = 0;
    error = @"";
    actualHardware = 0;
    presentIntervalUs = 0;
    _lastHalf = false;
    _usingEdr = false;
    _havePresent = false;
    _hardwareStream = -2;
    _hardwareTicks = 0;
    _pcmChannels = 2;
    _routeListener = false;
    _routeChanged.store(false);
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
    RillightCoreAudioSink sink{};
    sink.struct_size = sizeof(sink);
    sink.max_pcm_channels = rillight_macos::DefaultOutputChannelTarget();
    _audioDevice = rillight_macos::DigitalDefaultDevice();
    _audioAccept = rillight_macos::DigitalAcceptedFormats(_audioDevice);
    sink.accepted_passthrough = _audioAccept;
    sink.reports_atmos = 0;
    _pcmChannels = sink.max_pcm_channels;
    rillight_core_configure_audio_sink(self->core, &sink);
    if (!_routeListener) {
      const AudioObjectPropertyAddress address =
          rillight_macos::DefaultOutputDeviceAddress();
      if (AudioObjectAddPropertyListener(
              kAudioObjectSystemObject, &address, RillightDefaultOutputChanged,
              &_routeChanged) == noErr)
        _routeListener = true;
    }
    double headroom = 1;
    if (rillight_macos::CreateEdrSurface(&self->_edr, self->flutterView,
                                         &headroom) &&
        rillight_core_configure_macos_edr(self->core, 1) != 0) {
      rillight_macos::DestroyEdrSurface(&self->_edr);
    }
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self->_queue);
    dispatch_source_set_timer(_timer, dispatch_time(DISPATCH_TIME_NOW, 0),
                              5 * NSEC_PER_MSEC, NSEC_PER_MSEC);
    dispatch_source_set_event_handler(_timer, ^{ [self tick]; });
    dispatch_resume(_timer);
    dispatch_async(self->_audioQueue, ^{
      if (self->stopped.load()) return;
      self->_audioTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self->_audioQueue);
      dispatch_source_set_timer(self->_audioTimer, dispatch_time(DISPATCH_TIME_NOW, 0),
                                2 * NSEC_PER_MSEC, NSEC_PER_MSEC);
      dispatch_source_set_event_handler(self->_audioTimer, ^{ [self audioTick]; });
      dispatch_resume(self->_audioTimer);
    });
    dispatch_async(dispatch_get_main_queue(), ^{ ready(nil); });
  });
}

- (void)releaseAudio {
  if (_pendingAudio) {
    rillight_core_release_frame(_pendingAudio);
    _pendingAudio = nullptr;
  }
  _audioOffset = 0;
}

- (void)releaseVideo {
  if (_pendingVideo) {
    rillight_core_release_frame(_pendingVideo);
    _pendingVideo = nullptr;
  }
  if (_lastVideo) {
    rillight_core_release_frame(_lastVideo);
    _lastVideo = nullptr;
  }
}

- (void)notifyTexture {
  if (notificationPending.exchange(true)) return;
  dispatch_async(dispatch_get_main_queue(), ^{
    self->notificationPending.store(false);
    if (!self->stopped.load())
      [self->registry textureFrameAvailable:self->textureId];
  });
}

- (void)notePresent:(BOOL)linear elapsed:(int64_t)elapsed newFrame:(BOOL)newFrame {
  const auto now = Clock::now();
  [lock lock];
  if (newFrame) ++frames;
  conversionUs = elapsed;
  maxConversionUs = std::max(maxConversionUs, elapsed);
  _lastHalf = linear;
  if (linear) _usingEdr = true;
  if (_havePresent) {
    presentIntervalUs = std::chrono::duration_cast<std::chrono::microseconds>(
        now - _lastPresent).count();
  }
  _lastPresent = now;
  _havePresent = true;
  [lock unlock];
}

- (BOOL)publishLinear:(const RillightCoreFrame&)frame width:(int)outputWidth
               height:(int)outputHeight newFrame:(BOOL)newFrame
              session:(uint64_t)session timeline:(uint64_t)timeline {
  const auto started = Clock::now();
  const size_t stride = static_cast<size_t>(outputWidth) * 8;
  _linear.resize(static_cast<size_t>(outputWidth) * outputHeight * 4);
  RillightCoreSubtitleOverlay overlay{};
  overlay.struct_size = sizeof(overlay);
  const RillightCoreSubtitleOverlay* subtitles = nullptr;
  if (rillight_core_frame_subtitle_overlay(&frame, &overlay) == 0)
    subtitles = &overlay;
  if (!rillight_macos::WriteLinearHalf(
          frame, outputWidth, outputHeight, _linear.data(), stride,
          _linear.size() * sizeof(uint16_t), subtitles)) {
    [self setFailure:@"Extended-range frame fit failed"];
    return NO;
  }
  RillightCoreSnapshot current{};
  current.struct_size = sizeof(current);
  if (stopped.load() || rillight_core_snapshot(core, &current) != 0 ||
      current.session_id != session || current.timeline_version != timeline) {
    return NO;
  }
  if (!rillight_macos::PresentEdrSurface(&_edr, _linear.data(), outputWidth,
                                         outputHeight, stride)) {
    [self setFailure:@"Extended-range drawable was not presented"];
    return NO;
  }
  const int64_t elapsed = std::chrono::duration_cast<std::chrono::microseconds>(
      Clock::now() - started).count();
  [self notePresent:frame.type == RILLIGHT_CORE_VIDEO_RGBA16F elapsed:elapsed
           newFrame:newFrame];
  return YES;
}

- (BOOL)publish:(const RillightCoreFrame&)frame width:(int)outputWidth
        height:(int)outputHeight
        newFrame:(BOOL)newFrame
        session:(uint64_t)session timeline:(uint64_t)timeline {
  if (stopped.load()) return NO;
  if (_edr.ready &&
      (_usingEdr || frame.type == RILLIGHT_CORE_VIDEO_RGBA16F)) {
    return [self publishLinear:frame width:outputWidth height:outputHeight
                      newFrame:newFrame session:session timeline:timeline];
  }
  const auto started = Clock::now();
  CVPixelBufferRef buffer = nullptr;
  const CVReturn created = _videoOutput.Render(
      frame, outputWidth, outputHeight, &buffer);
  if (created != kCVReturnSuccess || !buffer) {
    [self setFailure:[NSString stringWithFormat:
        @"CVPixelBuffer output failed (%d)", created]];
    return NO;
  }
  const int64_t elapsed = std::chrono::duration_cast<std::chrono::microseconds>(
      Clock::now() - started).count();
  BOOL published = NO;
  RillightCoreSnapshot current{};
  current.struct_size = sizeof(current);
  if (!stopped.load() && rillight_core_snapshot(core, &current) == 0 &&
      current.session_id == session && current.timeline_version == timeline) {
    [lock lock];
    if (!stopped.load()) {
      CVPixelBufferRef old = latest;
      latest = CVPixelBufferRetain(buffer);
      if (newFrame) ++frames;
      conversionUs = elapsed;
      maxConversionUs = std::max(maxConversionUs, elapsed);
      _lastHalf = false;
      const auto presented = Clock::now();
      if (_havePresent) {
        presentIntervalUs = std::chrono::duration_cast<std::chrono::microseconds>(
            presented - _lastPresent).count();
      }
      _lastPresent = presented;
      _havePresent = true;
      published = YES;
      if (old) CVPixelBufferRelease(old);
    }
    [lock unlock];
    if (published) [self notifyTexture];
  }
  CVPixelBufferRelease(buffer);
  return published;
}

- (void)clearImage {
  rillight_macos::ResetEdrPresentationStats(&_edr);
  [lock lock];
  if (latest) { CVPixelBufferRelease(latest); latest = nullptr; }
  frames = 0;
  copiedFrames = lateFrames = conversionUs = maxConversionUs = 0;
  actualHardware = 0;
  [lock unlock];
  [self notifyTexture];
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

- (void)audioTick {
  if (stopped.load()) return;
  RillightCoreSnapshot snapshot{};
  snapshot.struct_size = sizeof(snapshot);
  if (rillight_core_snapshot(core, &snapshot) != 0 ||
      snapshot.abi_version != RILLIGHT_CORE_ABI_VERSION) {
    [self setFailure:@"Core snapshot unavailable"];
    return;
  }
  if (_routeChanged.exchange(false)) {
    const int channels = rillight_macos::DefaultOutputChannelTarget();
    const auto device = rillight_macos::DigitalDefaultDevice();
    if (channels != _pcmChannels || device != _audioDevice) {
      if (device != _audioDevice) _rejectedAudioFormats = 0;
      _audioDevice = device;
      _audioAccept = rillight_macos::DigitalAcceptedFormats(device) & ~_rejectedAudioFormats;
      _pcmChannels = channels;
      RillightCoreAudioSink sink{};
      sink.struct_size = sizeof(sink);
      sink.max_pcm_channels = channels;
      sink.accepted_passthrough = _audioAccept;
      sink.reports_atmos = 0;
      rillight_core_configure_audio_sink(core, &sink);
      if (_audio) _audio->Reset();
      _audio.reset();
      [self releaseAudio];
      _audioEndPts = -1;
      _audioClockStarted = _audioHandedOff = false;
    }
  }
  if (snapshot.session_id != _audioSession || snapshot.timeline_version != _audioTimeline) {
    if (_audio) _audio->Reset();
    [self releaseAudio];
    _audioSession = snapshot.session_id;
    _audioTimeline = snapshot.timeline_version;
    _audioEndPts = -1;
    _audioClockStarted = _audioHandedOff = _audioPaused = false;
    _audioGapSince = _audioStartupSince = _firstAudioWriteSince = {};
  }
  auto rejectCompressed = [&](int kind) {
    const auto bit = rillight_passthrough_accept_bit(kind);
    _rejectedAudioFormats |= bit ? bit : _audioAccept;
    _audioAccept &= ~_rejectedAudioFormats;
    // Destroy the HAL output first, restoring format/mixing/hog ownership
    // before a new PCM AudioQueue can open the same device.
    _audio.reset();
    [self releaseAudio];
    RillightCoreAudioSink sink{};
    sink.struct_size = sizeof(sink);
    sink.max_pcm_channels = _pcmChannels;
    sink.accepted_passthrough = _audioAccept;
    sink.reports_atmos = 0;
    rillight_core_configure_audio_sink(core, &sink);
    _audioEndPts = -1;
    _audioClockStarted = _audioHandedOff = _audioPaused = false;
    _audioGapSince = _audioStartupSince = _firstAudioWriteSince = {};
  };
  if (_audio && _audio->rejected()) rejectCompressed(_audio->kind());
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
  if (snapshot.state == RILLIGHT_CORE_PLAYING) {
    for (int attempts = 0; attempts < 8; ++attempts) {
      if (!_pendingAudio) {
        _pendingAudio = rillight_core_take_frame(core, RILLIGHT_CORE_AUDIO_S16);
        _audioOffset = 0;
      }
      if (!_pendingAudio) break;
      auto* frame = _pendingAudio;
      const bool compressed = frame->type == RILLIGHT_CORE_AUDIO_PASSTHROUGH;
      const int stride = rillight_core_pcm_bytes_per_frame(frame);
      if ((!compressed && frame->type != RILLIGHT_CORE_AUDIO_S16) ||
          frame->session_id != snapshot.session_id ||
          frame->timeline_version != snapshot.timeline_version ||
          (!compressed && (frame->sample_rate != 48000 || frame->channels < 1 ||
           frame->sample_count <= 0 ||
           static_cast<int64_t>(frame->sample_count) * stride != frame->data_size)) ||
          frame->data_size <= 0 ||
          !frame->data) {
        rillight_core_release_frame(frame);
        _pendingAudio = nullptr;
        continue;
      }
      const int kind = compressed ? frame->audio_codec_id : 0;
      if (compressed && (frame->sample_rate <= 0 || frame->sample_count <= 0 ||
          !(_audioAccept & rillight_passthrough_accept_bit(kind)))) {
        rejectCompressed(kind);
        continue;
      }
      if (!_audio || _audio->channels() != frame->channels || _audio->kind() != kind ||
          _audio->sample_rate() != frame->sample_rate) {
        _audio.reset();
        _audio = std::make_unique<rillight_macos::CoreAudioOutput>(frame->channels, kind, frame->sample_rate);
        if (_audio->rejected()) { rejectCompressed(kind); continue; }
        if (!_audio->error().empty()) break;
      }
      if (frame->pts_us >= 0 &&
          frame->pts_us > snapshot.position_us + 50000 &&
          (!_audioClockStarted || _audioEndPts < 0 || frame->pts_us > _audioEndPts + 1000)) {
        waitingFutureAudio = true;
        break;
      }
      if (!compressed && !_audioClockStarted && frame->pts_us >= 0) {
        if (snapshot.position_us > frame->pts_us && snapshot.playback_speed > 0) {
          const double late = (snapshot.position_us - frame->pts_us) * 48000.0 /
                              (1000000.0 * snapshot.playback_speed);
          _audioOffset = std::max(_audioOffset,
              static_cast<int>(std::min<double>(frame->sample_count,
                                               std::ceil(late))) * stride);
        }
      }
      if (_audioOffset >= frame->data_size) {
        rillight_core_release_frame(frame);
        _pendingAudio = nullptr;
        continue;
      }
      const size_t written = compressed
          ? _audio->WriteCompressed(frame->data, frame->data_size, frame->sample_count)
          : _audio->Write(frame->data + _audioOffset, frame->data_size - _audioOffset);
      if (_audio->rejected()) { rejectCompressed(kind); continue; }
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
            (compressed ? frame->sample_count : (_audioOffset / static_cast<double>(stride))) *
            1000000.0 / frame->sample_rate *
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
  [lock lock];
  _outputSession = snapshot.session_id;
  _outputTimeline = snapshot.timeline_version;
  _holdVideo = holdVideo;
  _audioDrained = snapshot.source_eof && snapshot.queued_audio_frames == 0 &&
                  !_pendingAudio && delay >= 0 && delay < 10000;
  [lock unlock];
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
    [self releaseVideo];
    _session = snapshot.session_id;
    _timeline = snapshot.timeline_version;
    _renderedWidth = _renderedHeight = 0;
    _needsPublication = _newFramePending = false;
    [self clearImage];
  }
  // Hardware mode is for the status readout. Walking every track on the
  // 5 ms video tick competes with frame conversion.
  if (snapshot.video_stream_index >= 0 &&
      (snapshot.video_stream_index != _hardwareStream ||
       ++_hardwareTicks >= 40)) {
    _hardwareTicks = 0;
    _hardwareStream = snapshot.video_stream_index;
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

  [lock lock];
  const bool currentAudio = _outputSession == snapshot.session_id &&
                            _outputTimeline == snapshot.timeline_version;
  const bool holdVideo = snapshot.audio_stream_index >= 0 &&
      snapshot.state == RILLIGHT_CORE_PLAYING && (!currentAudio || _holdVideo);
  const bool drainedAudio = currentAudio && _audioDrained;
  [lock unlock];
  if (!holdVideo && !_pendingVideo)
    _pendingVideo = rillight_core_take_frame(core, RILLIGHT_CORE_VIDEO_RGBA);
  if (_pendingVideo) {
    const bool current = _pendingVideo->session_id == snapshot.session_id &&
                         _pendingVideo->timeline_version == snapshot.timeline_version;
    const bool acceptable = _edr.ready
        ? rillight_macos::ValidLinearSource(*_pendingVideo)
        : rillight_macos::ValidSource(*_pendingVideo);
    if (!current || !acceptable) {
      if (current) [self setFailure:@"Core returned an invalid video frame"];
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
        _needsPublication = _newFramePending = true;
      } else {
        [lock lock]; ++lateFrames; [lock unlock];
        rillight_core_release_frame(_pendingVideo);
        _pendingVideo = nullptr;
      }
    }
  }
  if (_lastVideo &&
      (_needsPublication || _renderedWidth != width.load() ||
       _renderedHeight != height.load())) {
    const int outputWidth = width.load(), outputHeight = height.load();
    if ([self publish:*_lastVideo width:outputWidth height:outputHeight
              newFrame:_newFramePending
              session:snapshot.session_id timeline:snapshot.timeline_version]) {
      _renderedWidth = outputWidth; _renderedHeight = outputHeight;
      _needsPublication = _newFramePending = false;
    }
  }

  if (snapshot.source_eof && snapshot.queued_video_frames == 0 &&
      !_pendingVideo && !_needsPublication && drainedAudio)
    rillight_core_report_output_drained(core, snapshot.session_id,
                                       snapshot.timeline_version);
}

- (CVPixelBufferRef)copyPixelBuffer {
  [lock lock];
  CVPixelBufferRef result = !stopped.load() && latest ?
      CVPixelBufferRetain(latest) : nullptr;
  if (result) ++copiedFrames;
  [lock unlock];
  return result;
}

- (void)resizeWidth:(int)w height:(int)h {
  width = std::clamp(w, 1, 4096);
  height = std::clamp(h, 1, 2304);
  // Convert HDR at the physical viewport size, rather than converting every
  // source pixel and then discarding it during the native fit. The core keeps
  // SAR, rotation, subtitle coordinates and the current playback timeline.
  rillight_core_set_video_output_size(core, width.load(), height.load());
}

- (BOOL)detach {
  // Platform thread. Queue unregister without waiting for Impeller's raster
  // callback; Dart fences remaining copyPixelBuffer work with a picture snapshot.
  stopped.store(true);
  if (_routeListener) {
    const AudioObjectPropertyAddress address =
        rillight_macos::DefaultOutputDeviceAddress();
    AudioObjectRemovePropertyListener(kAudioObjectSystemObject, &address,
                                      RillightDefaultOutputChanged,
                                      &_routeChanged);
    _routeListener = false;
  }
  if (detached.exchange(true)) return YES;
  dispatch_sync(_queue, ^{
    if (self->_timer) {
      dispatch_source_cancel(self->_timer);
      self->_timer = nil;
    }
    [self releaseVideo];
  });
  dispatch_sync(_audioQueue, ^{
    if (self->_audioTimer) {
      dispatch_source_cancel(self->_audioTimer);
      self->_audioTimer = nil;
    }
    [self releaseAudio];
    self->_audio.reset();
  });
  [registry unregisterTexture:textureId];
  rillight_macos::DestroyEdrSurface(&_edr);
  return YES;
}

- (void)activateOverlay {
  rillight_macos::ActivateEdrSurface(&_edr, flutterView);
}

- (BOOL)extendedOutput {
  [lock lock];
  const bool usingEdr = _usingEdr;
  [lock unlock];
  return usingEdr;
}
- (double)edrHeadroom {
  NSScreen* screen = flutterView.window.screen ?: NSScreen.mainScreen;
  if (screen) return screen.maximumExtendedDynamicRangeColorComponentValue;
  return _edr.headroom;
}
- (BOOL)lastFrameLinear {
  [lock lock];
  const bool linear = _lastHalf;
  [lock unlock];
  return linear;
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
  id<FlutterPluginRegistrar> _registrar;
  id<FlutterTextureRegistry> _registry;
  NSMutableDictionary<NSNumber*, RillightSurface*>* _surfaces;
}

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  RillightPlayerPlugin* plugin = [[RillightPlayerPlugin alloc] init];
  plugin->_registrar = registrar;
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
    surface->flutterView = _registrar.view;
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
  } else if ([call.method isEqualToString:@"activateOverlay"]) {
    [surface activateOverlay];
    result(nil);
  } else if ([call.method isEqualToString:@"resize"]) {
    [surface resizeWidth:[arguments[@"width"] intValue]
                 height:[arguments[@"height"] intValue]];
    result(nil);
  } else if ([call.method isEqualToString:@"status"]) {
    RillightCoreSnapshot snapshot{};
    snapshot.struct_size = sizeof(snapshot);
    const bool hasSnapshot = rillight_core_snapshot(surface->core, &snapshot) == 0;
    const double sourceFrameRate = rillight_core_video_frame_rate(surface->core);
    const bool extended = [surface extendedOutput];
    const bool linear = [surface lastFrameLinear];
    const double headroom = [surface edrHeadroom];
    const auto presented = [surface presentationStats];
    [surface->lock lock];
    NSString* decoder = !hasSnapshot || snapshot.video_stream_index < 0 ?
        @"none" : !snapshot.first_video_frame_ready ? @"pending" :
        surface->actualHardware == RILLIGHT_CORE_HW_VIDEOTOOLBOX ?
        @"videotoolbox" : @"software";
    NSDictionary* status = @{@"frames": @(surface->frames),
                             @"presentedFrames": @(presented.frames),
                             @"firstPresentedUs": @(presented.first_presented_us),
                             @"lastPresentedUs": @(presented.last_presented_us),
                             @"maxPresentIntervalUs": @(presented.max_interval_us),
                             @"textureCopies": @(surface->copiedFrames),
                             @"lateFrames": @(surface->lateFrames),
                             @"conversionUs": @(surface->conversionUs),
                             @"maxConversionUs": @(surface->maxConversionUs),
                             @"outputPixelFormat": extended
                                 ? (linear ? @"rgba16f-extended-linear"
                                           : @"rgba8-on-edr-layer")
                                 : @"bgra8-srgb",
                             @"hdrOutput": @(extended && linear),
                             @"videoOutputKind": @(hasSnapshot ? snapshot.video_output_kind : 0),
                             @"doviReconstruction": @(hasSnapshot ? snapshot.dovi_reconstruction : 0),
                             @"sdrMapped": @(!extended),
                             @"nativeOverlay": @(extended),
                             @"edrHeadroom": @(headroom),
                             @"presentIntervalUs": @(surface->presentIntervalUs),
                             @"sourceFrameRate": @(sourceFrameRate),
                             @"queuedVideoFrames": @(hasSnapshot ? snapshot.queued_video_frames : 0),
                             @"queuedAudioFrames": @(hasSnapshot ? snapshot.queued_audio_frames : 0),
                             @"coreState": @(hasSnapshot ? snapshot.state : 0),
                             @"coreError": @(hasSnapshot ? snapshot.ffmpeg_error : 0),
                             @"videoStreamIndex": @(hasSnapshot ? snapshot.video_stream_index : -1),
                             @"audioStreamIndex": @(hasSnapshot ? snapshot.audio_stream_index : -1),
                             @"firstVideoReady": @(hasSnapshot && snapshot.first_video_frame_ready != 0),
                             @"firstAudioReady": @(hasSnapshot && snapshot.first_audio_frame_ready != 0),
                             @"sourceEof": @(hasSnapshot && snapshot.source_eof != 0),
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
