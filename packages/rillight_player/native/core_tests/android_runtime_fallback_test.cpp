// Device regression only: the send failure is injected into this translation unit.
// Production code has no fault injection hook. Input: 6s H.264/25fps, 96x64,
// B frames and a 30-frame GOP (see android_playback_checks.md).
extern "C" {
#include <libavcodec/avcodec.h>
}
#include <atomic>
#include <cassert>
#include <set>
#include <media/NdkImageReader.h>
#include <android/hardware_buffer.h>
#include <dlfcn.h>
static int injected_send_packet(AVCodecContext*, const AVPacket*);
#define avcodec_send_packet injected_send_packet
#include "../core/rillight_core.cpp"
#undef avcodec_send_packet
static std::atomic<int> hardware_packets{0};
static std::atomic<bool> injected{false};
static bool presentation_test = false;
static int injected_send_packet(AVCodecContext* c,const AVPacket* p) {
  if (p && c->codec && strstr(c->codec->name,"mediacodec") && ++hardware_packets==18 && !presentation_test) {
    injected=true;
    fprintf(stderr,"Injected one runtime hardware failure after 17 packets\n");
    return AVERROR(EIO);
  }
  return avcodec_send_packet(c,p);
}
static void* probe_open(void*,const char* path,int) { return fopen(path,"rb"); }
static int probe_read(void*,void* file,uint8_t* data,int size) {
  size_t n=fread(data,1,size,static_cast<FILE*>(file));return n?int(n):AVERROR_EOF;
}
static int64_t probe_seek(void*,void* file,int64_t offset,int whence) {
  FILE* f=static_cast<FILE*>(file);
  if(whence&AVSEEK_SIZE){long pos=ftell(f);fseek(f,0,SEEK_END);long size=ftell(f);fseek(f,pos,SEEK_SET);return size;}
  if(fseek(f,offset,whence&~AVSEEK_FORCE))return -1;return ftell(f);
}
static void probe_close(void*,void* file){fclose(static_cast<FILE*>(file));}
static void probe_cancel(void*){}
int main(int argc,char**argv) {
  setbuf(stdout,nullptr);
  assert(argc==2 || (argc==3 && !strcmp(argv[2], "--presentation")));
  presentation_test = argc == 3;
  RillightCoreIo io{nullptr,probe_open,probe_read,probe_seek,probe_close,probe_cancel,probe_cancel};
  auto* core=rillight_core_create(&io);assert(core);
  void* media=dlopen("libmediandk.so",RTLD_NOW|RTLD_LOCAL);assert(media);
  using NewReader=media_status_t(*)(int32_t,int32_t,int32_t,uint64_t,int32_t,AImageReader**);
  auto new_reader=reinterpret_cast<NewReader>(dlsym(media,"AImageReader_newWithUsage"));assert(new_reader);
  AImageReader* reader=nullptr; assert(new_reader(96,64,AIMAGE_FORMAT_PRIVATE,
      AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE,1,&reader)==AMEDIA_OK);
  ANativeWindow* window=nullptr; assert(AImageReader_getWindow(reader,&window)==AMEDIA_OK);
  assert(!rillight_core_set_android_window(core,window,0));
  assert(!rillight_core_configure_hardware(core,RILLIGHT_CORE_HW_MEDIACODEC,1));
  assert(!rillight_core_open(core,argv[1],1));
  assert(!rillight_core_set_playing(core,1,2));
  int frames=0, after=0; int64_t last=-1;std::set<uint32_t> colors;uint64_t initial=0,final=0;
  auto deadline=Clock::now()+std::chrono::seconds(15);
  while(Clock::now()<deadline){
    RillightCoreSnapshot s{};s.struct_size=sizeof(s);assert(!rillight_core_snapshot(core,&s));
    if(!initial)initial=s.timeline_version; final=s.timeline_version;
    if(s.state==RILLIGHT_CORE_FAILED){fprintf(stderr,"core error %d\n",s.ffmpeg_error);return 2;}
    auto* f=rillight_core_take_frame(core,RILLIGHT_CORE_VIDEO_MEDIACODEC);
    if(f && f->type==RILLIGHT_CORE_VIDEO_MEDIACODEC){
      rillight_core_render_mediacodec_frame(f);
      AImage* image=nullptr;AImageReader_acquireLatestImage(reader,&image);if(image)AImage_delete(image);
      if (presentation_test && frames >= 5 && !injected) {
        RillightCoreFrame stale = *f;
        ++stale.session_id;
        for (int i = 0; i < 4; ++i)
          assert(rillight_core_report_android_presentation(core, &stale, 0) == 0);
        stale = *f; ++stale.timeline_version;
        for (int i = 0; i < 4; ++i)
          assert(rillight_core_report_android_presentation(core, &stale, 0) == 0);
        assert(rillight_core_report_android_presentation(core, f, 0) == 0);
        assert(rillight_core_report_android_presentation(core, f, 0) == 0);
        assert(rillight_core_report_android_presentation(core, f, 1) == 0);
        assert(rillight_core_report_android_presentation(core, f, 0) == 0);
        assert(rillight_core_report_android_presentation(core, f, 0) == 0);
        assert(rillight_core_report_android_presentation(core, f, 0) == 1);
        // This old frame must not start another recovery after retirement.
        assert(rillight_core_report_android_presentation(core, f, 0) == 0);
        injected = true;
      }
    }
    if(f){frames++; if(injected && f->timeline_version>initial){after++;assert(f->pts_us>=last);last=f->pts_us;
      uint32_t hash=2166136261u;for(int i=0;i<f->data_size;i+=7) hash=(hash^f->data[i])*16777619u;colors.insert(hash);}
      rillight_core_release_frame(f);
    }
    if(s.source_eof && !s.queued_video_frames && after>=145) break;
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  }
  RillightCoreTrack track{};track.struct_size=sizeof(track);assert(!rillight_core_get_track(core,0,&track));
  printf("injected=%d packets=%d frames=%d software_frames=%d distinct=%zu timeline=%llu->%llu hardware=%u last_pts=%lld\n",
      injected.load(),hardware_packets.load(),frames,after,colors.size(),(unsigned long long)initial,(unsigned long long)final,track.actual_hardware,(long long)last);
  assert(injected && after>60 && colors.size()>60 && final>initial && track.actual_hardware==RILLIGHT_CORE_HW_NONE);
  rillight_core_destroy(core);AImageReader_delete(reader);return 0;
}
