#include "gpu_present.h"

#include <d3dcompiler.h>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <stdexcept>
#include <thread>

namespace rillight_windows {
namespace {
using Microsoft::WRL::ComPtr;
void Check(HRESULT result) {
  if (FAILED(result)) throw std::runtime_error("GPU video presentation failed");
}
constexpr char kShader[] = R"hlsl(
cbuffer Params : register(b0) { float4 shape; float4 subtitleRect; float4 outputInfo; };
struct Vertex { float4 position : SV_Position; float2 uv : TEXCOORD0; };
Vertex vs(uint id : SV_VertexID) {
  float2 uv = float2(id % 2, id / 2);
  Vertex v;
  v.position = float4((uv * float2(2,-2) + float2(-1,1)) * shape.xy, 0, 1);
  if (shape.z == 1) uv = float2(uv.y, 1-uv.x);
  else if (shape.z == 2) uv = 1-uv;
  else if (shape.z == 3) uv = float2(1-uv.y, uv.x);
  v.uv = uv;
  return v;
}
Texture2D<float4> video : register(t0);
Texture2D<float4> subtitles : register(t1);
SamplerState sampling : register(s0);
float toLinear(float code) { return code <= .04045 ? code / 12.92 : pow((code + .055) / 1.055, 2.4); }
float3 linearRgb(float3 code) { return float3(toLinear(code.r), toLinear(code.g), toLinear(code.b)); }
float4 ps(Vertex v) : SV_Target {
  float4 pixel = video.Sample(sampling, v.uv);
  if (shape.w > 0) pixel.rgb = linearRgb(saturate(pixel.rgb)) * shape.w;
  if (outputInfo.z > 0) {
    float2 uv = (v.uv - subtitleRect.xy) / subtitleRect.zw;
    if (all(uv >= 0) && all(uv <= 1)) {
      float4 overlay = subtitles.Sample(sampling, uv);
      if (overlay.a > 0) {
        float3 foreground = linearRgb(saturate(overlay.rgb / overlay.a)) * outputInfo.y;
        pixel.rgb = lerp(pixel.rgb, foreground, overlay.a);
      }
    }
  }
  return float4(pixel.rgb, 1);
}
)hlsl";
}

GpuPresenter::GpuPresenter(IDXGIAdapter* adapter) {
  const D3D_FEATURE_LEVEL level = D3D_FEATURE_LEVEL_11_0;
  Check(D3D11CreateDevice(adapter,
      adapter ? D3D_DRIVER_TYPE_UNKNOWN : D3D_DRIVER_TYPE_HARDWARE,
      nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT, &level, 1, D3D11_SDK_VERSION,
      &device_, nullptr, &context_));
  ComPtr<ID3DBlob> vs, ps, error;
  Check(D3DCompile(kShader, sizeof(kShader)-1, "rillight-present", nullptr,
      nullptr, "vs", "vs_5_0", D3DCOMPILE_OPTIMIZATION_LEVEL3, 0, &vs, &error));
  Check(D3DCompile(kShader, sizeof(kShader)-1, "rillight-present", nullptr,
      nullptr, "ps", "ps_5_0", D3DCOMPILE_OPTIMIZATION_LEVEL3, 0, &ps, &error));
  Check(device_->CreateVertexShader(vs->GetBufferPointer(), vs->GetBufferSize(), nullptr, &vertex_));
  Check(device_->CreatePixelShader(ps->GetBufferPointer(), ps->GetBufferSize(), nullptr, &pixel_));
  D3D11_BUFFER_DESC buffer{};
  buffer.ByteWidth = 48; buffer.Usage = D3D11_USAGE_DEFAULT;
  buffer.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
  Check(device_->CreateBuffer(&buffer, nullptr, &parameters_));
  D3D11_SAMPLER_DESC sampler{};
  sampler.Filter = D3D11_FILTER_MIN_MAG_LINEAR_MIP_POINT;
  sampler.AddressU = sampler.AddressV = sampler.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
  sampler.MaxLOD = D3D11_FLOAT32_MAX;
  Check(device_->CreateSamplerState(&sampler, &sampler_));
  D3D11_RASTERIZER_DESC raster{};
  raster.FillMode = D3D11_FILL_SOLID; raster.CullMode = D3D11_CULL_NONE;
  raster.DepthClipEnable = TRUE;
  Check(device_->CreateRasterizerState(&raster, &raster_));
  D3D11_QUERY_DESC query{D3D11_QUERY_EVENT, 0};
  Check(device_->CreateQuery(&query, &complete_));
}

std::shared_ptr<GpuPixelFrame> GpuPresenter::Present(const RillightCoreFrame& source,
    void* native_texture, int width, int height) {
  auto frame = std::make_shared<GpuPixelFrame>();
  frame->width = std::clamp(width, 1, 4096);
  frame->height = std::clamp(height, 1, 2304);
  D3D11_TEXTURE2D_DESC desc{};
  desc.Width = frame->width; desc.Height = frame->height;
  desc.MipLevels = desc.ArraySize = desc.SampleDesc.Count = 1;
  desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
  desc.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
  desc.MiscFlags = D3D11_RESOURCE_MISC_SHARED;
  Check(device_->CreateTexture2D(&desc, nullptr, &frame->texture));
  ComPtr<IDXGIResource> resource; Check(frame->texture.As(&resource));
  Check(resource->GetSharedHandle(&frame->handle));
  Draw(source, native_texture, frame->texture.Get(), frame->width, frame->height, 203, nullptr);
  return frame;
}

void GpuPresenter::PresentHdr(const RillightCoreFrame& source, void* native_texture,
    ID3D11Texture2D* target, float sdr_white_nits, const RillightCoreSubtitleOverlay* overlay) {
  D3D11_TEXTURE2D_DESC desc{}; target->GetDesc(&desc);
  if (desc.Format != DXGI_FORMAT_R16G16B16A16_FLOAT || !std::isfinite(sdr_white_nits) ||
      sdr_white_nits < 48 || sdr_white_nits > 1000)
    throw std::runtime_error("Invalid native HDR output");
  Draw(source, native_texture, target, static_cast<int>(desc.Width), static_cast<int>(desc.Height),
       sdr_white_nits, overlay);
}

void GpuPresenter::Draw(const RillightCoreFrame& source, void* native_texture,
    ID3D11Texture2D* output, int width, int height, float sdr_white_nits,
    const RillightCoreSubtitleOverlay* overlay) {
  if (source.width <= 0 || source.height <= 0 || source.width > 8192 || source.height > 8192)
    throw std::runtime_error("Invalid GPU source dimensions");
  ComPtr<ID3D11Texture2D> input;
  if (native_texture) {
    ComPtr<IDXGIResource> resource;
    Check(static_cast<ID3D11Texture2D*>(native_texture)->QueryInterface(IID_PPV_ARGS(&resource)));
    HANDLE handle = nullptr; Check(resource->GetSharedHandle(&handle));
    const HRESULT imported = device_->OpenSharedResource(handle, IID_PPV_ARGS(&input));
    if (imported == DXGI_ERROR_DEVICE_REMOVED || imported == DXGI_ERROR_DEVICE_RESET)
      Check(imported);
    if (FAILED(imported)) throw GpuImportUnavailable();
  } else {
    if (!source.data || source.stride < source.width * 4 ||
        static_cast<int64_t>(source.stride) * source.height > source.data_size)
      throw std::runtime_error("Invalid CPU source frame");
    D3D11_TEXTURE2D_DESC desc{};
    desc.Width = source.width; desc.Height = source.height;
    desc.MipLevels = desc.ArraySize = desc.SampleDesc.Count = 1;
    desc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    desc.Usage = D3D11_USAGE_IMMUTABLE; desc.BindFlags = D3D11_BIND_SHADER_RESOURCE;
    D3D11_SUBRESOURCE_DATA data{};
    data.pSysMem = source.data; data.SysMemPitch = source.stride;
    Check(device_->CreateTexture2D(&desc, &data, &input));
  }
  ComPtr<ID3D11ShaderResourceView> input_view;
  Check(device_->CreateShaderResourceView(input.Get(), nullptr, &input_view));
  D3D11_TEXTURE2D_DESC input_desc{}, output_desc{};
  input->GetDesc(&input_desc); output->GetDesc(&output_desc);
  const bool hdr = output_desc.Format == DXGI_FORMAT_R16G16B16A16_FLOAT;
  const bool linear_input = input_desc.Format == DXGI_FORMAT_R16G16B16A16_FLOAT;
  if (linear_input && !hdr) throw std::runtime_error("HDR frame cannot enter an SDR Flutter texture");
  ComPtr<ID3D11Texture2D> subtitle_texture;
  ComPtr<ID3D11ShaderResourceView> subtitle_view;
  if (hdr && overlay && overlay->data && overlay->width > 0 && overlay->height > 0 &&
      overlay->width <= source.width && overlay->height <= source.height && overlay->stride >= overlay->width * 4) {
    D3D11_TEXTURE2D_DESC desc{};
    desc.Width = overlay->width; desc.Height = overlay->height;
    desc.MipLevels = desc.ArraySize = desc.SampleDesc.Count = 1;
    desc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    desc.Usage = D3D11_USAGE_IMMUTABLE; desc.BindFlags = D3D11_BIND_SHADER_RESOURCE;
    D3D11_SUBRESOURCE_DATA data{}; data.pSysMem = overlay->data; data.SysMemPitch = overlay->stride;
    Check(device_->CreateTexture2D(&desc, &data, &subtitle_texture));
    Check(device_->CreateShaderResourceView(subtitle_texture.Get(), nullptr, &subtitle_view));
  }
  ComPtr<ID3D11RenderTargetView> target;
  Check(device_->CreateRenderTargetView(output, nullptr, &target));
  int rotation = 0;
  if (source.has_display_matrix) {
    rotation = static_cast<int>(std::lround(std::atan2(source.display_matrix[1],
        source.display_matrix[0]) / (3.14159265358979323846 / 2)));
    rotation = (rotation % 4 + 4) % 4;
  }
  const double sar = source.sar_num > 0 && source.sar_den > 0
      ? std::clamp(static_cast<double>(source.sar_num)/source.sar_den, .1, 10.0) : 1;
  const double sw = rotation % 2 ? source.height : source.width * sar;
  const double sh = rotation % 2 ? source.width * sar : source.height;
  const double fit = std::min(width/sw, height/sh);
  const float shape[] = {static_cast<float>(sw*fit/width),
      static_cast<float>(sh*fit/height), static_cast<float>(rotation),
      hdr && !linear_input ? sdr_white_nits / 80 : 0,
      subtitle_view ? static_cast<float>(overlay->x) / source.width : 0,
      subtitle_view ? static_cast<float>(overlay->y) / source.height : 0,
      subtitle_view ? static_cast<float>(overlay->width) / source.width : 1,
      subtitle_view ? static_cast<float>(overlay->height) / source.height : 1,
      hdr ? 1.0f : 0, sdr_white_nits / 80, subtitle_view ? 1.0f : 0, 0};
  context_->UpdateSubresource(parameters_.Get(), 0, nullptr, shape, 0, 0);
  const float black[] = {0,0,0,1};
  context_->ClearRenderTargetView(target.Get(), black);
  auto* render_target = target.Get();
  context_->OMSetRenderTargets(1, &render_target, nullptr);
  context_->OMSetBlendState(nullptr, nullptr, 0xffffffff);
  const D3D11_VIEWPORT viewport{0,0,static_cast<float>(width),static_cast<float>(height),0,1};
  context_->RSSetViewports(1, &viewport); context_->RSSetState(raster_.Get());
  context_->IASetInputLayout(nullptr);
  context_->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP);
  context_->VSSetShader(vertex_.Get(), nullptr, 0);
  auto* params = parameters_.Get(); context_->VSSetConstantBuffers(0,1,&params);
  context_->PSSetConstantBuffers(0,1,&params);
  context_->PSSetShader(pixel_.Get(), nullptr, 0);
  ID3D11ShaderResourceView* views[] = {input_view.Get(), subtitle_view.Get()};
  context_->PSSetShaderResources(0,2,views);
  auto* sampler = sampler_.Get(); context_->PSSetSamplers(0,1,&sampler);
  context_->Draw(4,0);
  ID3D11ShaderResourceView* none[] = {nullptr,nullptr}; context_->PSSetShaderResources(0,2,none);
  context_->OMSetRenderTargets(0,nullptr,nullptr);
  context_->End(complete_.Get()); context_->Flush();
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
  HRESULT result;
  while ((result = context_->GetData(complete_.Get(), nullptr, 0, D3D11_ASYNC_GETDATA_DONOTFLUSH)) == S_FALSE) {
    if (std::chrono::steady_clock::now() >= deadline)
      throw std::runtime_error("GPU video presentation timed out");
    std::this_thread::yield();
  }
  Check(result);
}
}  // namespace rillight_windows
