#include "android_color_pipeline.h"
#include "dovi_color_metadata.h"

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <android/log.h>
#include <android/native_window.h>
#include <cstring>
#include <limits>
#include <stdexcept>

extern "C" {
#include <libavutil/pixfmt.h>
}

namespace {
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
precision highp float;
precision highp int;
precision highp usampler2D;
struct Piece { vec4 polynomial; vec4 mmr[6]; };
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
  return mix(mix(a, b, f.x), mix(c, d, f.x), f.y) / 65472.0;
}
float pivot(int channel, int i) { return curves[channel].pivots[i / 4][i % 4]; }
float reshape(int channel, vec3 signal) {
  int count = int(curves[channel].bounds.x);
  if (count == 0) return signal[channel];
  float x = signal[channel];
  int index = 0;
  for (int i = 1; i < 8; ++i)
    if (i < count - 1 && x >= pivot(channel, i)) index = i;
  Piece piece = curves[channel].pieces[index];
  float value = piece.polynomial.x;
  if (piece.polynomial.w == 0.0) {
    value = (piece.polynomial.z * x + piece.polynomial.y) * x + value;
  } else {
    vec3 powers = signal;
    vec4 crossTerms = vec4(signal.x * signal.y, signal.x * signal.z,
                           signal.y * signal.z, signal.x * signal.y * signal.z);
    vec4 crossPowers = crossTerms;
    for (int order = 0; order < 3; ++order) {
      if (order < int(piece.polynomial.w))
        value += dot(piece.mmr[2 * order].xyz, powers) + dot(piece.mmr[2 * order + 1], crossPowers);
      powers *= signal;
      crossPowers *= crossTerms;
    }
  }
  return clamp(value, curves[channel].bounds.y, curves[channel].bounds.z);
}
vec3 pqDecode(vec3 code) {
  vec3 p = pow(clamp(code, 0.0, 1.0), vec3(1.0 / 78.84375));
  return 10000.0 * pow(max(p - 0.8359375, 0.0) /
      max(18.8515625 - 18.6875 * p, 1e-6), vec3(1.0 / 0.1593017578125));
}
vec3 pqEncode(vec3 nits) {
  vec3 p = pow(clamp(nits / 10000.0, 0.0, 1.0), vec3(0.1593017578125));
  return pow((0.8359375 + 18.8515625 * p) / (1.0 + 18.6875 * p), vec3(78.84375));
}
vec3 srgb(vec3 linear) {
  vec3 x = clamp(linear, 0.0, 1.0);
  return mix(12.92 * x, 1.055 * pow(x, vec3(1.0 / 2.4)) - 0.055,
             greaterThan(x, vec3(0.0031308)));
}
void main() {
  vec3 signal = clamp(vec3(samplePlane(luma, uv).r, samplePlane(chroma, uv)), 0.0, 1.0);
  vec3 shaped = vec3(reshape(0, signal), reshape(1, signal), reshape(2, signal)) - offset.xyz;
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
  int width = 0, height = 0;
  bool hdr = false, requested_hdr = false;
  ~Impl() { Reset(); }

  void Reset() {
    if (display != EGL_NO_DISPLAY) {
      if (context != EGL_NO_CONTEXT && surface != EGL_NO_SURFACE &&
          eglMakeCurrent(display, surface, surface, context)) {
        glDeleteTextures(2, textures);
        if (parameters) glDeleteBuffers(1, &parameters);
        if (program) glDeleteProgram(program);
        if (vertex_array) glDeleteVertexArrays(1, &vertex_array);
      }
      eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
      if (surface != EGL_NO_SURFACE) eglDestroySurface(display, surface);
      if (context != EGL_NO_CONTEXT) eglDestroyContext(display, context);
      // The display is process shared with Flutter; do not terminate it.
    }
    if (window) ANativeWindow_release(window);
    display = EGL_NO_DISPLAY; context = EGL_NO_CONTEXT; surface = EGL_NO_SURFACE;
    window = nullptr; program = parameters = vertex_array = textures[0] = textures[1] = 0;
    width = height = 0; hdr = false;
  }

  bool Create(ANativeWindow* target, bool prefer_hdr) {
    Reset();
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
      const bool created = Create(target, false);
      requested_hdr = prefer_hdr;
      return created;
    }
    if (surface == EGL_NO_SURFACE || !eglMakeCurrent(display, surface, surface, context)) return false;
    window = target; ANativeWindow_acquire(window);
    hdr = want_hdr;
    eglSwapInterval(display, 1);
    const GLuint vertex = Compile(GL_VERTEX_SHADER, kVertex);
    GLuint fragment = 0;
    try { fragment = Compile(GL_FRAGMENT_SHADER, kFragment); }
    catch (...) { glDeleteShader(vertex); throw; }
    program = glCreateProgram();
    glAttachShader(program, vertex); glAttachShader(program, fragment); glLinkProgram(program);
    glDeleteShader(vertex); glDeleteShader(fragment);
    GLint linked = 0; glGetProgramiv(program, GL_LINK_STATUS, &linked);
    if (!linked) throw std::runtime_error("Android color shader linking failed");
    const GLuint block = glGetUniformBlockIndex(program, "Params");
    GLint size = 0;
    glGetActiveUniformBlockiv(program, block, GL_UNIFORM_BLOCK_DATA_SIZE, &size);
    if (block == GL_INVALID_INDEX || size != sizeof(rillight_color::Constants))
      throw std::runtime_error("Android color uniform layout mismatch");
    glUniformBlockBinding(program, block, 0);
    glGenBuffers(1, &parameters); glBindBuffer(GL_UNIFORM_BUFFER, parameters);
    glBufferData(GL_UNIFORM_BUFFER, sizeof(rillight_color::Constants), nullptr, GL_DYNAMIC_DRAW);
    glBindBufferBase(GL_UNIFORM_BUFFER, 0, parameters);
    glGenTextures(2, textures);
    glGenVertexArrays(1, &vertex_array); glBindVertexArray(vertex_array);
    glUseProgram(program);
    glUniform1i(glGetUniformLocation(program, "luma"), 0);
    glUniform1i(glGetUniformLocation(program, "chroma"), 1);
    __android_log_print(ANDROID_LOG_INFO, "RillightColor", "GLES P010/RPU output=%s renderer=%s",
        hdr ? "BT2020-PQ-10bit" : "SDR-8bit", glGetString(GL_RENDERER));
    return glGetError() == GL_NO_ERROR;
  }

  bool Render(const AVFrame* frame, ANativeWindow* target, bool prefer_hdr) {
    if (!frame || !target || frame->format != AV_PIX_FMT_P010LE || frame->width <= 0 ||
        frame->height <= 0 || frame->width > std::numeric_limits<int>::max() / 2 ||
        !frame->data[0] || !frame->data[1] || frame->linesize[0] < frame->width * 2 ||
        frame->linesize[1] < ((frame->width + 1) / 2) * 4 ||
        (frame->linesize[0] & 1) || (frame->linesize[1] & 3)) return false;
    rillight_color::Constants constants{};
    constants.visible = {1, 1, 1, 1000};
    if (!rillight_color::DoviConstants(frame, &constants)) return false;
    if (target != window || prefer_hdr != requested_hdr)
      if (!Create(target, prefer_hdr)) return false;
    if (!eglMakeCurrent(display, surface, surface, context)) return false;
    constants.range.w = hdr ? 1 : 0;
    glBindBuffer(GL_UNIFORM_BUFFER, parameters);
    glBufferSubData(GL_UNIFORM_BUFFER, 0, sizeof(constants), &constants);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 2);
    const bool allocate = width != frame->width || height != frame->height;
    for (int plane = 0; plane < 2; ++plane) {
      const int plane_width = plane == 0 ? frame->width : (frame->width + 1) / 2;
      const int plane_height = plane == 0 ? frame->height : (frame->height + 1) / 2;
      const GLenum format = plane == 0 ? GL_RED_INTEGER : GL_RG_INTEGER;
      glActiveTexture(GL_TEXTURE0 + plane); glBindTexture(GL_TEXTURE_2D, textures[plane]);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
      glPixelStorei(GL_UNPACK_ROW_LENGTH, frame->linesize[plane] / (plane == 0 ? 2 : 4));
      if (allocate) glTexImage2D(GL_TEXTURE_2D, 0, plane == 0 ? GL_R16UI : GL_RG16UI,
          plane_width, plane_height, 0, format, GL_UNSIGNED_SHORT, nullptr);
      glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, plane_width, plane_height,
          format, GL_UNSIGNED_SHORT, frame->data[plane]);
    }
    glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
    width = frame->width; height = frame->height;
    EGLint output_width = 0, output_height = 0;
    if (!eglQuerySurface(display, surface, EGL_WIDTH, &output_width) ||
        !eglQuerySurface(display, surface, EGL_HEIGHT, &output_height) ||
        output_width <= 0 || output_height <= 0) return false;
    glViewport(0, 0, output_width, output_height);
    glUseProgram(program); glBindVertexArray(vertex_array);
    glDrawArrays(GL_TRIANGLES, 0, 3);
    return glGetError() == GL_NO_ERROR && eglSwapBuffers(display, surface);
  }
};

AndroidColorPipeline::AndroidColorPipeline() : impl_(std::make_unique<Impl>()) {}
AndroidColorPipeline::~AndroidColorPipeline() = default;
bool AndroidColorPipeline::Render(const AVFrame* frame, ANativeWindow* window, bool hdr_supported) {
  try { return impl_->Render(frame, window, hdr_supported); }
  catch (const std::exception& error) {
    __android_log_print(ANDROID_LOG_ERROR, "RillightColor", "%s", error.what());
    return false;
  }
}
