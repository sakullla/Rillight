#include "android_color_pipeline.h"
#include "android_dovi_surface.h"
#include "dovi_color_metadata.h"

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <GLES2/gl2ext.h>
#include <android/log.h>
#include <android/native_window.h>
#include <cstring>
#include <limits>
#include <stdexcept>
#include <string>
#include <array>
#include <algorithm>
#include <cmath>

extern "C" {
#include <libavutil/pixfmt.h>
}

namespace {
struct PolynomialCurve {
  rillight_color::Vec4 bounds;
  rillight_color::Vec4 pivots[3];
  rillight_color::Vec4 pieces[8];
};
struct PolynomialConstants {
  rillight_color::Vec4 output, visible, range, offset;
  rillight_color::Vec4 nonlinear[3], linear[3];
  PolynomialCurve curves[3];
};
static_assert(offsetof(PolynomialConstants, curves) == offsetof(rillight_color::Constants, curves));
constexpr char kVertex[] = R"glsl(#version 300 es
precision highp float;
out vec2 uv;
void main() {
  vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
  gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
  uv = vec2(p.x, 1.0 - p.y);
}
)glsl";

// Same RPU polynomial/MMR and matrix equations as our portable/D3D11 paths.
// Integer textures retain all P010 bits; interpolation happens at highp.
constexpr char kFragment[] = R"glsl(#version 300 es
#ifdef RILLIGHT_EXTERNAL
#extension GL_EXT_YUV_target : require
#endif
precision highp float;
precision highp int;
precision highp usampler2D;
#ifdef RILLIGHT_POLYNOMIAL
struct Piece { vec4 polynomial; };
#else
struct Piece { vec4 polynomial; vec4 mmr[6]; };
#endif
struct Curve { vec4 bounds; vec4 pivots[3]; Piece pieces[8]; };
layout(std140) uniform Params {
  vec4 outputInfo;
  vec4 visible;
  vec4 rangeInfo;
  vec4 offset;
  vec4 nonlinear[3];
  vec4 linearMatrix[3];
  Curve curves[3];
};
uniform usampler2D luma;
uniform usampler2D chroma;
uniform float inputMaximum;
uniform highp sampler2D transferTable;
#ifdef RILLIGHT_EXTERNAL
uniform highp __samplerExternal2DY2YEXT source;
#endif
in vec2 uv;
out vec4 color;

vec2 samplePlane(usampler2D plane, vec2 position) {
  ivec2 size = textureSize(plane, 0);
  vec2 p = position * vec2(size) - 0.5;
  ivec2 base = ivec2(floor(p));
  vec2 f = fract(p);
  ivec2 high = size - 1;
  vec2 a = vec2(texelFetch(plane, clamp(base, ivec2(0), high), 0).rg);
  vec2 b = vec2(texelFetch(plane, clamp(base + ivec2(1, 0), ivec2(0), high), 0).rg);
  vec2 c = vec2(texelFetch(plane, clamp(base + ivec2(0, 1), ivec2(0), high), 0).rg);
  vec2 d = vec2(texelFetch(plane, clamp(base + ivec2(1, 1), ivec2(0), high), 0).rg);
  return mix(mix(a, b, f.x), mix(c, d, f.x), f.y) / inputMaximum;
}
float pivot(int channel, int i) { return curves[channel].pivots[i / 4][i % 4]; }
#ifdef RILLIGHT_POLYNOMIAL
// Constant member offsets avoid mobile drivers lowering nested dynamic
// uniform-array indexing to a large sequence of per-pixel selections.
#define POLY_BODY(c) \
  if (curves[c].bounds.x == 0.0) return x; \
  vec4 p = curves[c].pieces[0].polynomial; \
  if (curves[c].bounds.x > 2.0 && x >= curves[c].pivots[0].y) p = curves[c].pieces[1].polynomial; \
  if (curves[c].bounds.x > 3.0 && x >= curves[c].pivots[0].z) p = curves[c].pieces[2].polynomial; \
  if (curves[c].bounds.x > 4.0 && x >= curves[c].pivots[0].w) p = curves[c].pieces[3].polynomial; \
  if (curves[c].bounds.x > 5.0 && x >= curves[c].pivots[1].x) p = curves[c].pieces[4].polynomial; \
  if (curves[c].bounds.x > 6.0 && x >= curves[c].pivots[1].y) p = curves[c].pieces[5].polynomial; \
  if (curves[c].bounds.x > 7.0 && x >= curves[c].pivots[1].z) p = curves[c].pieces[6].polynomial; \
  if (curves[c].bounds.x > 8.0 && x >= curves[c].pivots[1].w) p = curves[c].pieces[7].polynomial; \
  return clamp((p.z * x + p.y) * x + p.x, curves[c].bounds.y, curves[c].bounds.z);
float reshape0(float x) { POLY_BODY(0) }
float reshape1(float x) { POLY_BODY(1) }
float reshape2(float x) { POLY_BODY(2) }
#endif
float reshape(int channel, vec3 signal) {
  int count = int(curves[channel].bounds.x);
  if (count == 0) return signal[channel];
  float x = signal[channel];
  int index = 0;
  for (int i = 1; i < 8; ++i)
    if (i < count - 1 && x >= pivot(channel, i)) index = i;
  vec4 polynomial = curves[channel].pieces[index].polynomial;
  float value = polynomial.x;
#ifdef RILLIGHT_POLYNOMIAL
  value = (polynomial.z * x + polynomial.y) * x + value;
#else
  if (polynomial.w == 0.0) {
    value = (polynomial.z * x + polynomial.y) * x + value;
  } else {
    vec3 powers = signal;
    vec4 crossTerms = vec4(signal.x * signal.y, signal.x * signal.z,
                           signal.y * signal.z, signal.x * signal.y * signal.z);
    vec4 crossPowers = crossTerms;
    for (int order = 0; order < 3; ++order) {
      if (order < int(polynomial.w))
        value += dot(curves[channel].pieces[index].mmr[2 * order].xyz, powers) +
                 dot(curves[channel].pieces[index].mmr[2 * order + 1], crossPowers);
      powers *= signal;
      crossPowers *= crossTerms;
    }
  }
#endif
  return clamp(value, curves[channel].bounds.y, curves[channel].bounds.z);
}
vec3 pqDecode(vec3 code) {
  vec3 at = (clamp(code, 0.0, 1.0) * float(textureSize(transferTable, 0).x - 1) + 0.5) / float(textureSize(transferTable, 0).x);
  return vec3(texture(transferTable, vec2(at.r, 0.5)).r,
              texture(transferTable, vec2(at.g, 0.5)).r,
              texture(transferTable, vec2(at.b, 0.5)).r);
}
vec3 pqEncode(vec3 nits) {
  vec3 p = pow(clamp(nits / 10000.0, 0.0, 1.0), vec3(0.1593017578125));
  return pow((0.8359375 + 18.8515625 * p) / (1.0 + 18.6875 * p), vec3(78.84375));
}
vec3 srgb(vec3 linear) {
  vec3 at = (clamp(linear, 0.0, 1.0) * float(textureSize(transferTable, 0).x - 1) + 0.5) / float(textureSize(transferTable, 0).x);
  return vec3(texture(transferTable, vec2(at.r, 0.5)).g,
              texture(transferTable, vec2(at.g, 0.5)).g,
              texture(transferTable, vec2(at.b, 0.5)).g);
}
void main() {
  vec3 signal;
#ifdef RILLIGHT_EXTERNAL
    signal = clamp(texture(source, uv).rgb, 0.0, 1.0);
#else
    signal = clamp(vec3(samplePlane(luma, uv).r, samplePlane(chroma, uv)), 0.0, 1.0);
#endif
#ifdef RILLIGHT_POLYNOMIAL
  vec3 shaped = vec3(reshape0(signal.x), reshape1(signal.y), reshape2(signal.z)) - offset.xyz;
#else
  vec3 shaped = vec3(reshape(0, signal), reshape(1, signal), reshape(2, signal)) - offset.xyz;
#endif
  vec3 encoded = vec3(dot(nonlinear[0].xyz, shaped), dot(nonlinear[1].xyz, shaped),
                 dot(nonlinear[2].xyz, shaped));
  vec3 decoded = pqDecode(encoded);
  vec3 rgb = vec3(dot(linearMatrix[0].xyz, decoded), dot(linearMatrix[1].xyz, decoded),
                  dot(linearMatrix[2].xyz, decoded)); // Linear BT.2020 in nits.
  if (rangeInfo.w > 0.0) {
    color = vec4(pqEncode(rgb), 1.0); // 10-bit BT.2020 PQ native window.
    return;
  }
  rgb = vec3(dot(vec3(1.660491, -.587641, -.072850), rgb),
              dot(vec3(-.124550, 1.132900, -.008349), rgb),
              dot(vec3(-.018151, -.100579, 1.118730), rgb));
  float luminance = max(dot(vec3(.2126, .7152, .0722), rgb), 0.0);
  float peak = max(visible.w, 203.0);
  float mapped = luminance * (1.0 + 203.0 / peak) / (203.0 + luminance);
  rgb *= luminance > 1e-6 ? mapped / luminance : 0.0;
  float low = min(rgb.r, min(rgb.g, rgb.b));
  float high = max(rgb.r, max(rgb.g, rgb.b));
  float neutral = clamp(mapped, 0.0, 1.0);
  float amount = 1.0;
  if (low < 0.0) amount = min(amount, mapped / max(mapped - low, 1e-6));
  if (high > 1.0) amount = min(amount, (1.0 - neutral) / max(high - mapped, 1e-6));
  color = vec4(srgb(mix(vec3(neutral), rgb, clamp(amount, 0.0, 1.0))), 1.0);
}
)glsl";

bool HasExtension(const char* extensions, const char* name) {
  if (!extensions) return false;
  const size_t length = std::strlen(name);
  const char* cursor = extensions;
  while ((cursor = std::strstr(cursor, name))) {
    if ((cursor == extensions || cursor[-1] == ' ') &&
        (cursor[length] == '\0' || cursor[length] == ' ')) return true;
    cursor += length;
  }
  return false;
}

GLuint Compile(GLenum type, const char* source) {
  GLuint shader = glCreateShader(type);
  glShaderSource(shader, 1, &source, nullptr);
  glCompileShader(shader);
  GLint passed = 0;
  glGetShaderiv(shader, GL_COMPILE_STATUS, &passed);
  if (!passed) {
    char error[1024]{};
    glGetShaderInfoLog(shader, sizeof(error), nullptr, error);
    __android_log_print(ANDROID_LOG_ERROR, "RillightColor", "shader: %s", error);
    glDeleteShader(shader);
    throw std::runtime_error("Android color shader compilation failed");
  }
  return shader;
}
}  // namespace

struct AndroidColorPipeline::Impl {
  EGLDisplay display = EGL_NO_DISPLAY;
  EGLContext context = EGL_NO_CONTEXT;
  EGLSurface surface = EGL_NO_SURFACE;
  ANativeWindow* window = nullptr;
  GLuint program = 0, parameters = 0, textures[2]{}, vertex_array = 0;
  GLuint polynomial_program = 0;
  GLuint transfer_table = 0;
  int width = 0, height = 0;
  int source_format = AV_PIX_FMT_NONE;
  bool hdr = false, requested_hdr = false;
  bool external = false;
  EGLImageKHR imported = EGL_NO_IMAGE_KHR;
  std::shared_ptr<AVFrame> imported_frame;
  PFNEGLCREATEIMAGEKHRPROC create_image = nullptr;
  PFNEGLDESTROYIMAGEKHRPROC destroy_image = nullptr;
  PFNEGLGETNATIVECLIENTBUFFERANDROIDPROC client_buffer = nullptr;
  PFNGLEGLIMAGETARGETTEXTURE2DOESPROC image_target = nullptr;
  ~Impl() { Reset(); }

  void Reset() {
    if (display != EGL_NO_DISPLAY) {
      if (context != EGL_NO_CONTEXT && surface != EGL_NO_SURFACE &&
          eglMakeCurrent(display, surface, surface, context)) {
        glFinish();
        glDeleteTextures(2, textures);
        if (transfer_table) glDeleteTextures(1, &transfer_table);
        if (parameters) glDeleteBuffers(1, &parameters);
        if (program) glDeleteProgram(program);
        if (polynomial_program) glDeleteProgram(polynomial_program);
        if (vertex_array) glDeleteVertexArrays(1, &vertex_array);
      }
      if (imported != EGL_NO_IMAGE_KHR && destroy_image) destroy_image(display, imported);
      imported = EGL_NO_IMAGE_KHR;
      imported_frame.reset();
      eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
      if (surface != EGL_NO_SURFACE) eglDestroySurface(display, surface);
      if (context != EGL_NO_CONTEXT) eglDestroyContext(display, context);
      // The display is process shared with Flutter; do not terminate it.
    }
    if (window) ANativeWindow_release(window);
    display = EGL_NO_DISPLAY; context = EGL_NO_CONTEXT; surface = EGL_NO_SURFACE;
    window = nullptr; program = parameters = vertex_array = textures[0] = textures[1] = 0;
    polynomial_program = 0;
    transfer_table = 0;
    width = height = 0; hdr = false;
  }

  bool Create(ANativeWindow* target, bool prefer_hdr, bool use_external) {
    Reset();
    external = use_external;
    requested_hdr = prefer_hdr;
    display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (display == EGL_NO_DISPLAY || !eglInitialize(display, nullptr, nullptr)) return false;
    if (!eglBindAPI(EGL_OPENGL_ES_API)) return false;
    const char* extensions = eglQueryString(display, EGL_EXTENSIONS);
    bool want_hdr = prefer_hdr && HasExtension(extensions, "EGL_KHR_gl_colorspace") &&
        HasExtension(extensions, "EGL_EXT_gl_colorspace_bt2020_pq");
    EGLConfig config = nullptr;
    for (int attempt = 0; attempt < 2; ++attempt) {
      EGLint count = 0;
      const EGLint attributes[] = {
        EGL_SURFACE_TYPE, EGL_WINDOW_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT_KHR,
        EGL_RED_SIZE, want_hdr ? 10 : 8, EGL_GREEN_SIZE, want_hdr ? 10 : 8,
        EGL_BLUE_SIZE, want_hdr ? 10 : 8, EGL_ALPHA_SIZE, want_hdr ? 2 : 8, EGL_NONE};
      if (eglChooseConfig(display, attributes, &config, 1, &count) && count) {
        EGLint red = 0, green = 0, blue = 0;
        eglGetConfigAttrib(display, config, EGL_RED_SIZE, &red);
        eglGetConfigAttrib(display, config, EGL_GREEN_SIZE, &green);
        eglGetConfigAttrib(display, config, EGL_BLUE_SIZE, &blue);
        if (!want_hdr || (red == 10 && green == 10 && blue == 10)) break;
      }
      if (!want_hdr) return false;
      want_hdr = false; config = nullptr;
    }
    if (!config) return false;
    const EGLint context_attributes[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
    context = eglCreateContext(display, config, EGL_NO_CONTEXT, context_attributes);
    if (context == EGL_NO_CONTEXT) return false;
    EGLint visual = 0;
    if (!eglGetConfigAttrib(display, config, EGL_NATIVE_VISUAL_ID, &visual) ||
        ANativeWindow_setBuffersGeometry(target, 0, 0, visual) != 0) return false;
    const EGLint hdr_attributes[] = {
        EGL_GL_COLORSPACE_KHR, EGL_GL_COLORSPACE_BT2020_PQ_EXT, EGL_NONE};
    const EGLint sdr_attributes[] = {EGL_NONE};
    surface = eglCreateWindowSurface(display, config, target, want_hdr ? hdr_attributes : sdr_attributes);
    if (surface == EGL_NO_SURFACE && want_hdr) {
      // Retry with a complete 8-bit SDR configuration, never tag SDR as PQ.
      const bool created = Create(target, false, use_external);
      requested_hdr = prefer_hdr;
      return created;
    }
    if (surface == EGL_NO_SURFACE || !eglMakeCurrent(display, surface, surface, context)) return false;
    window = target; ANativeWindow_acquire(window);
    hdr = want_hdr;
    if (external) {
      if (!HasExtension(reinterpret_cast<const char*>(glGetString(GL_EXTENSIONS)), "GL_EXT_YUV_target"))
        return false;
      create_image = reinterpret_cast<PFNEGLCREATEIMAGEKHRPROC>(eglGetProcAddress("eglCreateImageKHR"));
      destroy_image = reinterpret_cast<PFNEGLDESTROYIMAGEKHRPROC>(eglGetProcAddress("eglDestroyImageKHR"));
      client_buffer = reinterpret_cast<PFNEGLGETNATIVECLIENTBUFFERANDROIDPROC>(eglGetProcAddress("eglGetNativeClientBufferANDROID"));
      image_target = reinterpret_cast<PFNGLEGLIMAGETARGETTEXTURE2DOESPROC>(eglGetProcAddress("glEGLImageTargetTexture2DOES"));
      if (!create_image || !destroy_image || !client_buffer || !image_target) return false;
    }
    // The core already schedules frames against the media/audio clock.
    // SurfaceFlinger owns display vsync; do not add a second blocking interval.
    eglSwapInterval(display, 0);
    const GLuint vertex = Compile(GL_VERTEX_SHADER, kVertex);
    GLuint fragment = 0;
    std::string fragment_source = kFragment;
    if (external) fragment_source.insert(fragment_source.find('\n') + 1, "#define RILLIGHT_EXTERNAL\n");
    try { fragment = Compile(GL_FRAGMENT_SHADER, fragment_source.c_str()); }
    catch (...) { glDeleteShader(vertex); throw; }
    program = glCreateProgram();
    glAttachShader(program, vertex); glAttachShader(program, fragment); glLinkProgram(program);
    glDeleteShader(vertex); glDeleteShader(fragment);
    GLint linked = 0; glGetProgramiv(program, GL_LINK_STATUS, &linked);
    if (!linked) throw std::runtime_error("Android color shader linking failed");
    // Avoid the MMR coefficient arrays entirely for polynomial-only RPUs.
    // Copying a dynamically selected whole Piece costs many uniform loads on
    // mobile GPUs even when every frame takes the polynomial branch.
    fragment_source.insert(fragment_source.find('\n') + 1, "#define RILLIGHT_POLYNOMIAL\n");
    const auto poly_vertex = Compile(GL_VERTEX_SHADER, kVertex);
    GLuint poly_fragment = 0;
    try { poly_fragment = Compile(GL_FRAGMENT_SHADER, fragment_source.c_str()); }
    catch (...) { glDeleteShader(poly_vertex); throw; }
    polynomial_program = glCreateProgram();
    glAttachShader(polynomial_program, poly_vertex); glAttachShader(polynomial_program, poly_fragment);
    glLinkProgram(polynomial_program);
    glDeleteShader(poly_vertex); glDeleteShader(poly_fragment);
    glGetProgramiv(polynomial_program, GL_LINK_STATUS, &linked);
    if (!linked) throw std::runtime_error("Android polynomial shader linking failed");
    const GLuint block = glGetUniformBlockIndex(program, "Params");
    GLint size = 0;
    glGetActiveUniformBlockiv(program, block, GL_UNIFORM_BLOCK_DATA_SIZE, &size);
    if (block == GL_INVALID_INDEX || size != sizeof(rillight_color::Constants))
      throw std::runtime_error("Android color uniform layout mismatch");
    glUniformBlockBinding(program, block, 0);
    const auto poly_block = glGetUniformBlockIndex(polynomial_program, "Params");
    glGetActiveUniformBlockiv(polynomial_program, poly_block, GL_UNIFORM_BLOCK_DATA_SIZE, &size);
    if (poly_block == GL_INVALID_INDEX || size != sizeof(PolynomialConstants))
      throw std::runtime_error("Android polynomial uniform layout mismatch");
    glUniformBlockBinding(polynomial_program, poly_block, 0);
    glGenBuffers(1, &parameters); glBindBuffer(GL_UNIFORM_BUFFER, parameters);
    glBufferData(GL_UNIFORM_BUFFER, sizeof(rillight_color::Constants), nullptr, GL_DYNAMIC_DRAW);
    glBindBufferBase(GL_UNIFORM_BUFFER, 0, parameters);
    glGenTextures(2, textures);
    // GLES 3 guarantees filtering for half-float textures. A compact transfer
    // table replaces nine per-pixel powers on SDR presentation; output remains
    // independently negotiated and the RPU reshape/matrices are unchanged.
    GLint maximum_texture = 0; glGetIntegerv(GL_MAX_TEXTURE_SIZE, &maximum_texture);
    const int transfer_size = std::min(4096, maximum_texture);
    if (transfer_size < 2048) return false;
    std::array<float, 4096 * 2> transfer{};
    for (size_t i = 0; i < static_cast<size_t>(transfer_size); ++i) {
      const double x = i / double(transfer_size - 1);
      const double p = std::pow(x, 1.0 / 78.84375);
      transfer[i * 2] = static_cast<float>(10000.0 * std::pow(
          std::max(p - .8359375, 0.0) / (18.8515625 - 18.6875 * p), 1.0 / .1593017578125));
      transfer[i * 2 + 1] = static_cast<float>(x <= .0031308 ? 12.92 * x :
          1.055 * std::pow(x, 1.0 / 2.4) - .055);
    }
    glGenTextures(1, &transfer_table); glActiveTexture(GL_TEXTURE2);
    glBindTexture(GL_TEXTURE_2D, transfer_table);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RG16F, transfer_size, 1, 0, GL_RG, GL_FLOAT, transfer.data());
    glGenVertexArrays(1, &vertex_array); glBindVertexArray(vertex_array);
    for (const auto shader : {program, polynomial_program}) {
      glUseProgram(shader);
      glUniform1i(glGetUniformLocation(shader, "luma"), 0);
      glUniform1i(glGetUniformLocation(shader, "chroma"), 1);
      glUniform1i(glGetUniformLocation(shader, "transferTable"), 2);
      if (external) glUniform1i(glGetUniformLocation(shader, "source"), 0);
    }
    return glGetError() == GL_NO_ERROR;
  }

  bool Render(const AVFrame* frame, ANativeWindow* target, bool prefer_hdr) {
    auto* decoder_surface = AndroidDoviSurface::From(frame);
    if (!frame || !target ||
        (frame->format != AV_PIX_FMT_P010LE && frame->format != AV_PIX_FMT_NV12 &&
         !(frame->format == AV_PIX_FMT_MEDIACODEC && decoder_surface))) return false;
    const bool ten_bit = frame->format == AV_PIX_FMT_P010LE;
    const int component_bytes = ten_bit ? 2 : 1;
    if (frame->width <= 0 || frame->height <= 0 ||
        frame->width > std::numeric_limits<int>::max() / 2) return false;
    if (!decoder_surface &&
        (!frame->data[0] || !frame->data[1] || frame->linesize[0] < frame->width * component_bytes ||
        frame->linesize[1] < ((frame->width + 1) / 2) * 2 * component_bytes ||
        frame->linesize[0] % component_bytes ||
        frame->linesize[1] % (2 * component_bytes))) return false;
    rillight_color::Constants constants{};
    constants.visible = {1, 1, 1, 1000};
    if (!rillight_color::DoviConstants(frame, &constants)) return false;
    bool polynomial_only = true;
    for (const auto& curve : constants.curves)
      for (int piece = 0; piece < static_cast<int>(curve.bounds.x) - 1; ++piece)
        if (curve.pieces[piece].polynomial.w != 0) polynomial_only = false;
    if (target != window || prefer_hdr != requested_hdr || external != (decoder_surface != nullptr))
      if (!Create(target, prefer_hdr, decoder_surface != nullptr)) return false;
    if (!eglMakeCurrent(display, surface, surface, context)) return false;
    constants.range.w = hdr ? 1 : 0;
    glBindBuffer(GL_UNIFORM_BUFFER, parameters);
    if (polynomial_only) {
      PolynomialConstants packed{};
      std::memcpy(&packed, &constants, offsetof(PolynomialConstants, curves));
      for (int c = 0; c < 3; ++c) {
        packed.curves[c].bounds = constants.curves[c].bounds;
        std::copy_n(constants.curves[c].pivots, 3, packed.curves[c].pivots);
        for (int p = 0; p < 8; ++p)
          packed.curves[c].pieces[p] = constants.curves[c].pieces[p].polynomial;
      }
      glBufferSubData(GL_UNIFORM_BUFFER, 0, sizeof(packed), &packed);
    } else glBufferSubData(GL_UNIFORM_BUFFER, 0, sizeof(constants), &constants);
    const auto selected_program = polynomial_only ? polynomial_program : program;
    glUseProgram(selected_program);
    if (decoder_surface) {
      // Finish sampling before returning the previous gralloc image. Importing
      // the next buffer does not copy 4K planes through CPU memory.
      glFinish();
      if (imported != EGL_NO_IMAGE_KHR) destroy_image(display, imported);
      imported = EGL_NO_IMAGE_KHR;
      imported_frame.reset();
      auto* buffer = decoder_surface->Acquire(frame);
      if (!buffer) return false;
      const EGLint attributes[] = {EGL_IMAGE_PRESERVED_KHR, EGL_TRUE, EGL_NONE};
      imported = create_image(display, EGL_NO_CONTEXT, EGL_NATIVE_BUFFER_ANDROID,
                               client_buffer(buffer), attributes);
      if (imported == EGL_NO_IMAGE_KHR) return false;
      imported_frame = std::shared_ptr<AVFrame>(av_frame_clone(frame),
          [](AVFrame* retained) { av_frame_free(&retained); });
      if (!imported_frame) return false;
      glActiveTexture(GL_TEXTURE0); glBindTexture(GL_TEXTURE_EXTERNAL_OES, textures[0]);
      glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
      glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
      glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
      glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
      image_target(GL_TEXTURE_EXTERNAL_OES, imported);
    } else {
      glUniform1f(glGetUniformLocation(selected_program, "inputMaximum"), ten_bit ? 65472.f : 255.f);
      glPixelStorei(GL_UNPACK_ALIGNMENT, component_bytes);
      const bool allocate = width != frame->width || height != frame->height || source_format != frame->format;
      for (int plane = 0; plane < 2; ++plane) {
        const int plane_width = plane == 0 ? frame->width : (frame->width + 1) / 2;
        const int plane_height = plane == 0 ? frame->height : (frame->height + 1) / 2;
        const GLenum format = plane == 0 ? GL_RED_INTEGER : GL_RG_INTEGER;
        glActiveTexture(GL_TEXTURE0 + plane); glBindTexture(GL_TEXTURE_2D, textures[plane]);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        glPixelStorei(GL_UNPACK_ROW_LENGTH, frame->linesize[plane] / (component_bytes * (plane == 0 ? 1 : 2)));
        const GLenum component = ten_bit ? GL_UNSIGNED_SHORT : GL_UNSIGNED_BYTE;
        const GLenum storage = ten_bit ? (plane == 0 ? GL_R16UI : GL_RG16UI) :
                                        (plane == 0 ? GL_R8UI : GL_RG8UI);
        if (allocate) glTexImage2D(GL_TEXTURE_2D, 0, storage,
            plane_width, plane_height, 0, format, component, nullptr);
        glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, plane_width, plane_height,
            format, component, frame->data[plane]);
      }
      glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
      width = frame->width; height = frame->height;
      source_format = frame->format;
    }
    EGLint output_width = 0, output_height = 0;
    if (!eglQuerySurface(display, surface, EGL_WIDTH, &output_width) ||
        !eglQuerySurface(display, surface, EGL_HEIGHT, &output_height) ||
        output_width <= 0 || output_height <= 0) return false;
    glUseProgram(selected_program); glBindVertexArray(vertex_array);
    glViewport(0, 0, output_width, output_height);
    glDrawArrays(GL_TRIANGLES, 0, 3);
    return glGetError() == GL_NO_ERROR && eglSwapBuffers(display, surface);
  }
};

AndroidColorPipeline::AndroidColorPipeline() : impl_(std::make_unique<Impl>()) {}
AndroidColorPipeline::~AndroidColorPipeline() = default;
bool AndroidColorPipeline::SupportsPrivateYuv() {
  static const bool supported = [] {
    const auto previous_display = eglGetCurrentDisplay();
    const auto previous_context = eglGetCurrentContext();
    const auto previous_draw = eglGetCurrentSurface(EGL_DRAW);
    const auto previous_read = eglGetCurrentSurface(EGL_READ);
    const auto display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (display == EGL_NO_DISPLAY || !eglInitialize(display, nullptr, nullptr)) return false;
    const EGLint attributes[] = {EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT_KHR, EGL_NONE};
    EGLConfig config{}; EGLint count = 0;
    if (!eglChooseConfig(display, attributes, &config, 1, &count) || !count) return false;
    const EGLint context_attributes[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
    const EGLint surface_attributes[] = {EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE};
    const auto context = eglCreateContext(display, config, EGL_NO_CONTEXT, context_attributes);
    const auto surface = eglCreatePbufferSurface(display, config, surface_attributes);
    const bool ready = context != EGL_NO_CONTEXT && surface != EGL_NO_SURFACE &&
        eglMakeCurrent(display, surface, surface, context);
    const bool result = ready && HasExtension(
        reinterpret_cast<const char*>(glGetString(GL_EXTENSIONS)), "GL_EXT_YUV_target") &&
        eglGetProcAddress("eglCreateImageKHR") && eglGetProcAddress("eglDestroyImageKHR") &&
        eglGetProcAddress("eglGetNativeClientBufferANDROID") &&
        eglGetProcAddress("glEGLImageTargetTexture2DOES");
    eglMakeCurrent(previous_display == EGL_NO_DISPLAY ? display : previous_display,
                    previous_draw, previous_read, previous_context);
    if (surface != EGL_NO_SURFACE) eglDestroySurface(display, surface);
    if (context != EGL_NO_CONTEXT) eglDestroyContext(display, context);
    return result;
  }();
  return supported;
}
bool AndroidColorPipeline::Render(const AVFrame* frame, ANativeWindow* window, bool hdr_supported) {
  try { return impl_->Render(frame, window, hdr_supported); }
  catch (const std::exception& error) {
    __android_log_print(ANDROID_LOG_ERROR, "RillightColor", "%s", error.what());
    return false;
  }
}
