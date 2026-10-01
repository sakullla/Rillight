#include "windows_color_pipeline.h"
#include "dovi_color_metadata.h"

#include <d3d11.h>
#include <d3dcompiler.h>
#include <wrl/client.h>
#include <algorithm>
#include <cmath>
#include <cstring>
#include <stdexcept>
#include <chrono>
#include <thread>
#include <vector>

extern "C" {
#include <libavutil/dovi_meta.h>
#include <libavutil/frame.h>
#include <libavutil/hwcontext.h>
#include <libavutil/hwcontext_d3d11va.h>
#include <libavutil/mastering_display_metadata.h>
#include <libavutil/pixfmt.h>
#include <libavutil/pixdesc.h>
}

namespace {
using Microsoft::WRL::ComPtr;
void Check(HRESULT result) {
  if (FAILED(result)) {
    throw std::runtime_error("GPU color conversion failed");
  }
}

using rillight_color::Vec4;
using rillight_color::Constants;
using rillight_color::DoviConstants;

// RPU reshaping and IPT-PQ conversion follow the equations used by
// libplacebo's pl_shader_dovi_reshape/pl_shader_decode_color (LGPL-2.1+):
// https://github.com/haasn/libplacebo/blob/master/src/shaders/colorspace.c
// FFmpeg dovi_meta.h defines the coefficient normalization and matrix order.
// This shader consumes the parsed per-frame metadata, including polynomial
// and MMR curves, rather than interpreting Profile 5 as ordinary YCbCr.
constexpr char kShader[] = R"hlsl(
struct Piece { float4 polynomial; float4 mmr[6]; };
struct Curve { float4 bounds; float4 pivots[3]; Piece pieces[8]; };
cbuffer Params : register(b0) {
  float4 outputInfo;
  float4 visible;
  float4 range;
  float4 offset;
  float4 nonlinear[3];
  float4 linearMatrix[3];
  Curve curves[3];
};
Texture2D<float> luma : register(t0);
Texture2D<float2> chroma : register(t1);
Texture1D<float2> transferLut : register(t2);
SamplerState sampleLinear : register(s0);
RWTexture2D<float4> destination : register(u0);

float pivot(int c, int i) { return curves[c].pivots[i / 4][i % 4]; }
float reshape(int c, float3 sig) {
  int count = (int)curves[c].bounds.x;
  if (count == 0) return sig[c];
  float x = sig[c];
  int piece = 0;
  [unroll] for (int i = 1; i < 8; ++i)
    if (i < count - 1 && x >= pivot(c, i)) piece = i;
  Piece p = curves[c].pieces[piece];
  float value;
  if (p.polynomial.w == 0) {
    value = (p.polynomial.z * x + p.polynomial.y) * x + p.polynomial.x;
  } else {
    value = p.polynomial.x;
    float4 crossTerms = float4(sig.x * sig.y, sig.x * sig.z,
                               sig.y * sig.z, sig.x * sig.y * sig.z);
    float3 power = sig;
    float4 crossPower = crossTerms;
    [unroll] for (int order = 0; order < 3; ++order) {
      if (order < (int)p.polynomial.w)
        value += dot(p.mmr[2 * order].xyz, power) +
                 dot(p.mmr[2 * order + 1], crossPower);
      power *= sig;
      crossPower *= crossTerms;
    }
  }
  return clamp(value, curves[c].bounds.y, curves[c].bounds.z);
}
float3 pq(float3 code) {
  float3 uv = (saturate(code) * 4095.0 + 0.5) / 4096.0;
  return float3(transferLut.SampleLevel(sampleLinear, uv.r, 0).x,
                transferLut.SampleLevel(sampleLinear, uv.g, 0).x,
                transferLut.SampleLevel(sampleLinear, uv.b, 0).x);
}
float3 srgb(float3 x) {
  float3 uv = (saturate(x) * 4095.0 + 0.5) / 4096.0;
  return float3(transferLut.SampleLevel(sampleLinear, uv.r, 0).y,
                transferLut.SampleLevel(sampleLinear, uv.g, 0).y,
                transferLut.SampleLevel(sampleLinear, uv.b, 0).y);
}
[numthreads(8, 8, 1)]
void main(uint3 id : SV_DispatchThreadID) {
  if (id.x >= (uint)outputInfo.x || id.y >= (uint)outputInfo.y) return;
  float2 uv = (float2(id.xy) + 0.5) / outputInfo.xy * visible.xy;
  float3 sig = float3(luma.SampleLevel(sampleLinear, uv, 0),
                      chroma.SampleLevel(sampleLinear, uv, 0)) * outputInfo.z;
  float3 rgb;
  if (outputInfo.w == 3) {
    sig = saturate(sig);
    float3 shaped = float3(reshape(0, sig), reshape(1, sig), reshape(2, sig));
    shaped -= offset.xyz;
    float3 encoded = float3(dot(nonlinear[0].xyz, shaped),
                            dot(nonlinear[1].xyz, shaped),
                            dot(nonlinear[2].xyz, shaped));
    float3 decoded = pq(encoded);
    rgb = float3(dot(linearMatrix[0].xyz, decoded), dot(linearMatrix[1].xyz, decoded),
                 dot(linearMatrix[2].xyz, decoded));
  } else {
    sig = float3((sig.x - range.x) * range.y,
                  (sig.yz - range.z) * range.w);
    rgb = float3(dot(nonlinear[0].xyz, sig), dot(nonlinear[1].xyz, sig),
                 dot(nonlinear[2].xyz, sig));
    if (outputInfo.w == 1) rgb = pq(rgb);
    else if (outputInfo.w == 2) {
      rgb = saturate(rgb);
      rgb = float3(rgb.r <= .5 ? rgb.r * rgb.r / 3 :
                   (exp((rgb.r - .55991073) / .17883277) + .28466892) / 12,
                   rgb.g <= .5 ? rgb.g * rgb.g / 3 :
                   (exp((rgb.g - .55991073) / .17883277) + .28466892) / 12,
                   rgb.b <= .5 ? rgb.b * rgb.b / 3 :
                   (exp((rgb.b - .55991073) / .17883277) + .28466892) / 12) * 1000;
    }
  }
  if (offset.w > 0 && outputInfo.w == 2) {
    // HLG inverse OETF gives scene light. Apply the BT.2100 reference OOTF.
    float3 weights = visible.z > 0 ? float3(.2627,.6780,.0593) : float3(.2126,.7152,.0722);
    rgb *= pow(max(dot(weights, rgb / 1000.0), 0.0), .2);
  }
  if (outputInfo.w != 0) {
    if (visible.z > 0) {
      rgb = float3(dot(float3(1.660491, -.587641, -.072850), rgb),
                   dot(float3(-.124550, 1.132900, -.008349), rgb),
                   dot(float3(-.018151, -.100579, 1.118730), rgb));
    }
    if (offset.w > 0) {
      // scRGB has an absolute 80-nit unit. Retain highlights and the signed
      // gamut instead of tone mapping or applying the sRGB output transfer.
      destination[id.xy] = float4(clamp(rgb / 80.0, -65504.0, 65504.0), 1.0);
      return;
    }
    // Luminance-based compression preserves chromatic ratios. The RPU source
    // peak controls the shoulder for DV; HDR10 uses its mastering metadata.
    float luminance = max(dot(float3(.2126, .7152, .0722), rgb), 0.0);
    float peak = max(visible.w, 203.0);
    float mapped = luminance * (1.0 + 203.0 / peak) / (203.0 + luminance);
    rgb *= luminance > 1e-6 ? mapped / luminance : 0.0;
    // Compress out-of-gamut components towards neutral before clipping.
    float low = min(rgb.r, min(rgb.g, rgb.b));
    float high = max(rgb.r, max(rgb.g, rgb.b));
    float amount = 1.0;
    if (low < 0) amount = min(amount, mapped / max(mapped - low, 1e-6));
    if (high > 1) amount = min(amount, (1.0 - saturate(mapped)) / max(high - mapped, 1e-6));
    rgb = srgb(lerp(saturate(mapped).xxx, rgb, saturate(amount)));
  }
  if (offset.w > 0) {
    rgb = saturate(rgb);
    float3 low = rgb / 12.92;
    float3 high = pow((rgb + .055) / 1.055, 2.4);
    rgb = float3(rgb.r <= .04045 ? low.r : high.r,
                 rgb.g <= .04045 ? low.g : high.g,
                 rgb.b <= .04045 ? low.b : high.b) * (offset.w / 80.0);
  }
  destination[id.xy] = float4(offset.w > 0 ? rgb : saturate(rgb), 1.0);
}
)hlsl";

class DeviceLock {
 public:
  explicit DeviceLock(AVD3D11VADeviceContext* device) : device_(device) {
    if (device_ && device_->lock) device_->lock(device_->lock_ctx);
  }
  ~DeviceLock() {
    if (device_ && device_->unlock) device_->unlock(device_->lock_ctx);
  }
 private:
  AVD3D11VADeviceContext* device_;
};


}  // namespace

struct WindowsColorPipeline::Impl {
  ComPtr<ID3D11Device> device;
  ComPtr<ID3D11DeviceContext> context;
  ComPtr<ID3D11ComputeShader> shader;
  ComPtr<ID3D11SamplerState> sampler;
  ComPtr<ID3D11Buffer> parameters;
  ComPtr<ID3D11Texture2D> input, luma_texture, chroma_texture, output, staging;
  ComPtr<ID3D11ShaderResourceView> luma, chroma;
  ComPtr<ID3D11Texture1D> transfer_lut;
  ComPtr<ID3D11ShaderResourceView> transfer_view;
  ComPtr<ID3D11UnorderedAccessView> target;
  ComPtr<ID3D11Query> gpu_complete;
  int input_width = 0, input_height = 0, input_mode = -1;
  DXGI_FORMAT input_format = DXGI_FORMAT_UNKNOWN;
  int output_width = 0, output_height = 0;
  std::vector<uint16_t> interleaved;

  void Initialize(ID3D11Device* selected, ID3D11DeviceContext* selected_context) {
    if (shader && (!selected || selected == device.Get())) return;
    input.Reset(); luma_texture.Reset(); chroma_texture.Reset(); luma.Reset(); chroma.Reset();
    output.Reset(); staging.Reset(); target.Reset(); gpu_complete.Reset();
    shader.Reset(); sampler.Reset(); parameters.Reset();
    transfer_view.Reset(); transfer_lut.Reset();
    input_width = input_height = output_width = output_height = 0;
    if (selected) { device = selected; context = selected_context; }
    else {
      device.Reset(); context.Reset();
      D3D_FEATURE_LEVEL level;
      const D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_0};
      Check(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, 0,
          levels, 1, D3D11_SDK_VERSION, &device, &level, &context));
    }
    ComPtr<ID3DBlob> binary, error;
    const HRESULT compiled = D3DCompile(kShader, sizeof(kShader) - 1, "rillight-color", nullptr, nullptr,
                     "main", "cs_5_0", D3DCOMPILE_OPTIMIZATION_LEVEL3, 0, &binary, &error);
    Check(compiled);
    Check(device->CreateComputeShader(binary->GetBufferPointer(), binary->GetBufferSize(), nullptr, &shader));
    D3D11_SAMPLER_DESC sampling{};
    sampling.Filter = D3D11_FILTER_MIN_MAG_LINEAR_MIP_POINT;
    sampling.AddressU = sampling.AddressV = sampling.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
    sampling.MaxLOD = D3D11_FLOAT32_MAX;
    Check(device->CreateSamplerState(&sampling, &sampler));
    // Immutable high precision LUTs avoid six per-pixel power functions.
    // Half-texel addressing in HLSL preserves the exact black/white endpoints.
    std::vector<float> values(4096 * 2);
    for (int i = 0; i < 4096; ++i) {
      const double code = i / 4095.0;
      const double p = std::pow(code, 1.0 / 78.84375);
      values[2 * i] = static_cast<float>(10000.0 * std::pow(
          std::max(p - .8359375, 0.0) / (18.8515625 - 18.6875 * p),
          1.0 / .1593017578125));
      values[2 * i + 1] = static_cast<float>(code <= .0031308 ? 12.92 * code :
          1.055 * std::pow(code, 1.0 / 2.4) - .055);
    }
    D3D11_TEXTURE1D_DESC lut{};
    lut.Width = 4096; lut.MipLevels = lut.ArraySize = 1;
    lut.Format = DXGI_FORMAT_R32G32_FLOAT;
    lut.Usage = D3D11_USAGE_IMMUTABLE; lut.BindFlags = D3D11_BIND_SHADER_RESOURCE;
    D3D11_SUBRESOURCE_DATA data{}; data.pSysMem = values.data();
    Check(device->CreateTexture1D(&lut, &data, &transfer_lut));
    Check(device->CreateShaderResourceView(transfer_lut.Get(), nullptr, &transfer_view));
    D3D11_BUFFER_DESC buffer{};
    buffer.ByteWidth = sizeof(Constants);
    buffer.Usage = D3D11_USAGE_DEFAULT;
    buffer.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
    Check(device->CreateBuffer(&buffer, nullptr, &parameters));
  }

  void CreateInput(int width, int height, DXGI_FORMAT format, int mode) {
    if (input_width == width && input_height == height && input_format == format && input_mode == mode) return;
    input.Reset(); luma_texture.Reset(); chroma_texture.Reset(); luma.Reset(); chroma.Reset();
    D3D11_TEXTURE2D_DESC desc{};
    desc.Width = width; desc.Height = height;
    desc.MipLevels = desc.ArraySize = 1; desc.SampleDesc.Count = 1;
    desc.Usage = D3D11_USAGE_DEFAULT; desc.BindFlags = D3D11_BIND_SHADER_RESOURCE;
    if (mode == 0) {
      desc.Format = format;
      Check(device->CreateTexture2D(&desc, nullptr, &input));
      D3D11_SHADER_RESOURCE_VIEW_DESC view{};
      view.ViewDimension = D3D11_SRV_DIMENSION_TEXTURE2D; view.Texture2D.MipLevels = 1;
      view.Format = format == DXGI_FORMAT_NV12 ? DXGI_FORMAT_R8_UNORM : DXGI_FORMAT_R16_UNORM;
      Check(device->CreateShaderResourceView(input.Get(), &view, &luma));
      view.Format = format == DXGI_FORMAT_NV12 ? DXGI_FORMAT_R8G8_UNORM : DXGI_FORMAT_R16G16_UNORM;
      Check(device->CreateShaderResourceView(input.Get(), &view, &chroma));
    } else {
      desc.Format = DXGI_FORMAT_R16_UNORM;
      Check(device->CreateTexture2D(&desc, nullptr, &luma_texture));
      Check(device->CreateShaderResourceView(luma_texture.Get(), nullptr, &luma));
      desc.Width = (width + 1) / 2; desc.Height = (height + 1) / 2;
      desc.Format = DXGI_FORMAT_R16G16_UNORM;
      Check(device->CreateTexture2D(&desc, nullptr, &chroma_texture));
      Check(device->CreateShaderResourceView(chroma_texture.Get(), nullptr, &chroma));
    }
    input_width = width; input_height = height; input_format = format; input_mode = mode;
  }

  void AllocateOutput(int width, int height, ComPtr<ID3D11Texture2D>& image,
                      ComPtr<ID3D11UnorderedAccessView>& view,
                      DXGI_FORMAT format = DXGI_FORMAT_R8G8B8A8_UNORM) {
    D3D11_TEXTURE2D_DESC desc{};
    desc.Width = width; desc.Height = height; desc.MipLevels = desc.ArraySize = 1;
    desc.SampleDesc.Count = 1; desc.Format = format;
    desc.Usage = D3D11_USAGE_DEFAULT;
    desc.BindFlags = D3D11_BIND_UNORDERED_ACCESS | D3D11_BIND_SHADER_RESOURCE | D3D11_BIND_RENDER_TARGET;
    desc.MiscFlags = D3D11_RESOURCE_MISC_SHARED;
    Check(device->CreateTexture2D(&desc, nullptr, &image));
    Check(device->CreateUnorderedAccessView(image.Get(), nullptr, &view));
  }

  void CreateOutput(int width, int height) {
    if (output_width == width && output_height == height) return;
    output.Reset(); staging.Reset(); target.Reset();
    AllocateOutput(width, height, output, target);
    output_width = width; output_height = height;
  }

  bool Render(const AVFrame* frame, int width, int height, bool dovi, uint8_t* rgba, int stride,
              void** gpu = nullptr, float sc_rgb_white = 0) {
    const bool hardware = frame->format == AV_PIX_FMT_D3D11;
    const auto format = static_cast<AVPixelFormat>(frame->format);
    const bool packed = format == AV_PIX_FMT_P010LE || format == AV_PIX_FMT_P012LE ||
                        format == AV_PIX_FMT_P016LE;
    const bool planar = format == AV_PIX_FMT_YUV420P10LE || format == AV_PIX_FMT_YUV420P12LE ||
                        format == AV_PIX_FMT_YUV420P16LE;
    if (!hardware && !packed && !planar) return false;
    int bit_depth = hardware ? 10 : av_pix_fmt_desc_get(format)->comp[0].depth;
    if (hardware && frame->hw_frames_ctx) {
      const auto* frames = reinterpret_cast<AVHWFramesContext*>(frame->hw_frames_ctx->data);
      const auto* description = av_pix_fmt_desc_get(frames->sw_format);
      if (description) bit_depth = description->comp[0].depth;
    }
    if (bit_depth < 8 || bit_depth > 16) return false;
    const float maximum = static_cast<float>((1u << bit_depth) - 1);
    const float code_scale = static_cast<float>(1u << (bit_depth - 8));
    Constants constants{};
    constants.output = {static_cast<float>(width), static_cast<float>(height), 1,
        frame->color_trc == AVCOL_TRC_SMPTE2084 ? 1.0f : frame->color_trc == AVCOL_TRC_ARIB_STD_B67 ? 2.0f : 0.0f};
    constants.visible = {1, 1, frame->color_primaries == AVCOL_PRI_BT2020 ? 1.0f : 0.0f, 1000};
    if (const auto* mastering = av_frame_get_side_data(frame, AV_FRAME_DATA_MASTERING_DISPLAY_METADATA);
        mastering && mastering->size >= sizeof(AVMasteringDisplayMetadata)) {
      const auto* data = reinterpret_cast<const AVMasteringDisplayMetadata*>(mastering->data);
      if (data->has_luminance && data->max_luminance.den > 0) {
        const double peak = av_q2d(data->max_luminance);
        if (std::isfinite(peak) && peak >= 203 && peak <= 10000)
          constants.visible.w = static_cast<float>(peak);
      }
    }
    if (const auto* light = av_frame_get_side_data(frame, AV_FRAME_DATA_CONTENT_LIGHT_LEVEL);
        light && light->size >= sizeof(AVContentLightMetadata)) {
      const auto* data = reinterpret_cast<const AVContentLightMetadata*>(light->data);
      if (data->MaxCLL >= 203 && data->MaxCLL <= 10000)
        constants.visible.w = static_cast<float>(data->MaxCLL);
    }
    if (dovi && !DoviConstants(frame, &constants)) return false;
    // The RPU transform reserves offset.w. Apply sink policy after parsing.
    constants.offset.w = sc_rgb_white;
    if (!dovi) {
      const bool full = frame->color_range == AVCOL_RANGE_JPEG;
      constants.range = full ? Vec4{0, 1, 128 * code_scale / maximum, 1} :
          Vec4{16 * code_scale / maximum, maximum / (219 * code_scale),
               128 * code_scale / maximum, maximum / (224 * code_scale)};
      const bool bt2020 = frame->colorspace == AVCOL_SPC_BT2020_NCL;
      constants.nonlinear[0] = {1, 0, bt2020 ? 1.4746f : 1.5748f, 0};
      constants.nonlinear[1] = {1, bt2020 ? -.164553f : -.187324f, bt2020 ? -.571353f : -.468124f, 0};
      constants.nonlinear[2] = {1, bt2020 ? 1.8814f : 1.8556f, 0, 0};
    }
    AVD3D11VADeviceContext* shared = nullptr;
    if (hardware) {
      if (!frame->hw_frames_ctx || !frame->data[0]) return false;
      auto* frames = reinterpret_cast<AVHWFramesContext*>(frame->hw_frames_ctx->data);
      shared = reinterpret_cast<AVD3D11VADeviceContext*>(frames->device_ctx->hwctx);
    }
    DeviceLock lock(shared);
    Initialize(shared ? shared->device : nullptr, shared ? shared->device_context : nullptr);
    if (hardware) {
      auto* texture = reinterpret_cast<ID3D11Texture2D*>(frame->data[0]);
      D3D11_TEXTURE2D_DESC desc{}; texture->GetDesc(&desc);
      if (desc.Format != DXGI_FORMAT_NV12 && desc.Format != DXGI_FORMAT_P010 &&
          desc.Format != DXGI_FORMAT_P016) return false;
      CreateInput(static_cast<int>(desc.Width), static_cast<int>(desc.Height), desc.Format, 0);
      context->CopySubresourceRegion(input.Get(), 0, 0, 0, 0, texture,
          D3D11CalcSubresource(0, static_cast<UINT>(reinterpret_cast<intptr_t>(frame->data[1])), desc.MipLevels), nullptr);
      constants.output.z = desc.Format == DXGI_FORMAT_NV12 ? 1 :
          65535.0f / (maximum * (1u << (16 - bit_depth)));
      if (desc.Format == DXGI_FORMAT_NV12 && !dovi && frame->color_range != AVCOL_RANGE_JPEG)
        constants.range = {16.0f/255, 255.0f/219, 128.0f/255, 255.0f/224};
      constants.visible.x = static_cast<float>(frame->width) / desc.Width;
      constants.visible.y = static_cast<float>(frame->height) / desc.Height;
    } else {
      if (!frame->data[0] || !frame->data[1] || frame->linesize[0] <= 0 || frame->linesize[1] <= 0) return false;
      CreateInput(frame->width, frame->height, DXGI_FORMAT_R16_UNORM, 1);
      context->UpdateSubresource(luma_texture.Get(), 0, nullptr, frame->data[0], frame->linesize[0], 0);
      if (packed) {
        context->UpdateSubresource(chroma_texture.Get(), 0, nullptr, frame->data[1], frame->linesize[1], 0);
        constants.output.z = 65535.0f / (maximum * (1u << (16 - bit_depth)));
      } else {
        if (!frame->data[2] || frame->linesize[2] <= 0) return false;
        const int cw = (frame->width + 1) / 2, ch = (frame->height + 1) / 2;
        interleaved.resize(static_cast<size_t>(cw) * ch * 2);
        for (int y = 0; y < ch; ++y) {
          const auto* u = reinterpret_cast<const uint16_t*>(frame->data[1] + y * frame->linesize[1]);
          const auto* v = reinterpret_cast<const uint16_t*>(frame->data[2] + y * frame->linesize[2]);
          auto* row = interleaved.data() + static_cast<size_t>(y) * cw * 2;
          for (int x = 0; x < cw; ++x) { row[2*x] = u[x]; row[2*x+1] = v[x]; }
        }
        context->UpdateSubresource(chroma_texture.Get(), 0, nullptr, interleaved.data(), cw * 4, 0);
        constants.output.z = 65535.0f / maximum;
      }
    }
    ComPtr<ID3D11Texture2D> gpu_output;
    ComPtr<ID3D11UnorderedAccessView> gpu_target;
    if (gpu) {
      // Render directly into the allocation the sink will own. A separate
      // scratch image and full-frame CopyResource are unnecessary here.
      // Never write into an allocation retained by a previously returned frame.
      AllocateOutput(width, height, gpu_output, gpu_target,
          sc_rgb_white > 0 ? DXGI_FORMAT_R16G16B16A16_FLOAT : DXGI_FORMAT_R8G8B8A8_UNORM);
    } else {
      CreateOutput(width, height);
    }
    context->UpdateSubresource(parameters.Get(), 0, nullptr, &constants, 0, 0);
    ID3D11ShaderResourceView* views[] = {luma.Get(), chroma.Get(), transfer_view.Get()};
    ID3D11Buffer* buffer = parameters.Get();
    ID3D11SamplerState* sampling = sampler.Get();
    ID3D11UnorderedAccessView* view = gpu ? gpu_target.Get() : target.Get();
    context->CSSetShader(shader.Get(), nullptr, 0);
    context->CSSetShaderResources(0, 3, views);
    context->CSSetConstantBuffers(0, 1, &buffer);
    context->CSSetSamplers(0, 1, &sampling);
    context->CSSetUnorderedAccessViews(0, 1, &view, nullptr);
    context->Dispatch((width + 7) / 8, (height + 7) / 8, 1);
    ID3D11ShaderResourceView* empty_views[] = {nullptr, nullptr, nullptr};
    ID3D11UnorderedAccessView* empty_target = nullptr;
    context->CSSetShaderResources(0, 3, empty_views);
    context->CSSetUnorderedAccessViews(0, 1, &empty_target, nullptr);
    ID3D11Buffer* empty_buffer = nullptr;
    ID3D11SamplerState* empty_sampler = nullptr;
    context->CSSetConstantBuffers(0, 1, &empty_buffer);
    context->CSSetSamplers(0, 1, &empty_sampler);
    context->CSSetShader(nullptr, nullptr, 0);
    if (gpu) {
      if (!gpu_complete) {
        D3D11_QUERY_DESC query_desc{D3D11_QUERY_EVENT, 0};
        Check(device->CreateQuery(&query_desc, &gpu_complete));
      }
      context->End(gpu_complete.Get()); context->Flush();
      const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
      HRESULT result;
      while ((result = context->GetData(gpu_complete.Get(), nullptr, 0, D3D11_ASYNC_GETDATA_DONOTFLUSH)) == S_FALSE) {
        if (std::chrono::steady_clock::now() >= deadline) return false;
        std::this_thread::yield();
      }
      Check(result);
      Check(device->GetDeviceRemovedReason());
      *gpu = gpu_output.Detach();
      return true;
    }
    if (!staging) {
      D3D11_TEXTURE2D_DESC desc{}; output->GetDesc(&desc);
      desc.Usage = D3D11_USAGE_STAGING; desc.BindFlags = desc.MiscFlags = 0;
      desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
      Check(device->CreateTexture2D(&desc, nullptr, &staging));
    }
    context->CopyResource(staging.Get(), output.Get());
    D3D11_MAPPED_SUBRESOURCE mapped{};
    Check(context->Map(staging.Get(), 0, D3D11_MAP_READ, 0, &mapped));
    for (int y = 0; y < height; ++y)
      std::memcpy(rgba + y * stride, static_cast<uint8_t*>(mapped.pData) + y * mapped.RowPitch,
                   static_cast<size_t>(width) * 4);
    context->Unmap(staging.Get(), 0);
    return true;
  }
};

WindowsColorPipeline::WindowsColorPipeline() : impl_(std::make_unique<Impl>()) {}
WindowsColorPipeline::~WindowsColorPipeline() = default;
bool WindowsColorPipeline::Render(const AVFrame* frame, int width, int height,
                                  bool dovi, uint8_t* rgba, int stride) {
  if (!frame || !rgba || width <= 0 || height <= 0 || stride < width * 4) return false;
  try { return impl_->Render(frame, width, height, dovi, rgba, stride); }
  catch (const std::exception&) { return false; }
}

void* WindowsColorPipeline::RenderTexture(const AVFrame* frame, int width, int height,
                                         bool dovi) {
  if (!frame || width <= 0 || height <= 0) return nullptr;
  void* texture = nullptr;
  try { impl_->Render(frame, width, height, dovi, nullptr, 0, &texture); }
  catch (const std::exception&) { return nullptr; }
  return texture;
}

void* WindowsColorPipeline::RenderScRgbTexture(const AVFrame* frame, int width, int height,
                                              bool dovi, float sdr_white_nits) {
  if (!frame || width <= 0 || height <= 0 || !std::isfinite(sdr_white_nits) ||
      sdr_white_nits < 48 || sdr_white_nits > 1000) return nullptr;
  void* texture = nullptr;
  try { impl_->Render(frame, width, height, dovi, nullptr, 0, &texture, sdr_white_nits); }
  catch (const std::exception&) { return nullptr; }
  return texture;
}
