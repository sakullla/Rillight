#include "../../../windows/gpu_present.h"

#include <cassert>
#include <cstring>
#include <vector>

using Microsoft::WRL::ComPtr;
std::vector<uint8_t> Read(const std::shared_ptr<rillight_windows::GpuPixelFrame>& frame) {
  ComPtr<ID3D11Device> device; frame->texture->GetDevice(&device);
  ComPtr<ID3D11DeviceContext> context; device->GetImmediateContext(&context);
  D3D11_TEXTURE2D_DESC desc{}; frame->texture->GetDesc(&desc);
  desc.Usage = D3D11_USAGE_STAGING; desc.BindFlags = desc.MiscFlags = 0;
  desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
  ComPtr<ID3D11Texture2D> staging;
  assert(SUCCEEDED(device->CreateTexture2D(&desc, nullptr, &staging)));
  context->CopyResource(staging.Get(), frame->texture.Get());
  D3D11_MAPPED_SUBRESOURCE mapped{};
  assert(SUCCEEDED(context->Map(staging.Get(),0,D3D11_MAP_READ,0,&mapped)));
  std::vector<uint8_t> pixels(frame->width*frame->height*4);
  for (int y=0;y<frame->height;++y)
    std::memcpy(pixels.data()+y*frame->width*4,
        static_cast<const uint8_t*>(mapped.pData)+y*mapped.RowPitch,frame->width*4);
  context->Unmap(staging.Get(),0);
  return pixels;
}

int main() {
  rillight_windows::GpuPresenter presenter(nullptr);
  uint8_t rgba[] = {255,0,0,255, 0,0,255,255};
  RillightCoreFrame source{};
  source.type = RILLIGHT_CORE_VIDEO_RGBA;
  source.width = 2; source.height = 1; source.stride = source.data_size = 8;
  source.data = rgba; source.sar_num = source.sar_den = 1;
  auto first = presenter.Present(source,nullptr,2,1);
  const std::vector<uint8_t> bgra = {0,0,255,255, 255,0,0,255};
  assert(Read(first) == bgra); // channels, top-down orientation and alpha
  source.has_display_matrix = 1; source.display_matrix[1] = 65536;
  auto rotated = presenter.Present(source,nullptr,1,2);
  assert(Read(rotated) == bgra);
  source.has_display_matrix = 0;
  auto boxed = presenter.Present(source,nullptr,2,3);
  const auto pixels = Read(boxed);
  assert(pixels[0] == 0 && pixels[1] == 0 && pixels[2] == 0 && pixels[3] == 255);
  assert(pixels[8+2] == 255 && pixels[12] == 255);
  assert(Read(first) == bgra); // later publications never mutate a held frame

  ComPtr<ID3D11Device> device;
  assert(SUCCEEDED(D3D11CreateDevice(nullptr,D3D_DRIVER_TYPE_HARDWARE,nullptr,
      D3D11_CREATE_DEVICE_BGRA_SUPPORT,nullptr,0,D3D11_SDK_VERSION,&device,nullptr,nullptr)));
  D3D11_TEXTURE2D_DESC desc{};
  desc.Width = 2; desc.Height = 1;
  desc.MipLevels = desc.ArraySize = desc.SampleDesc.Count = 1;
  desc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
  desc.BindFlags = D3D11_BIND_SHADER_RESOURCE | D3D11_BIND_RENDER_TARGET;
  desc.MiscFlags = D3D11_RESOURCE_MISC_SHARED;
  D3D11_SUBRESOURCE_DATA data{}; data.pSysMem = rgba; data.SysMemPitch = 8;
  ComPtr<ID3D11Texture2D> gpu;
  assert(SUCCEEDED(device->CreateTexture2D(&desc,&data,&gpu)));
  ComPtr<ID3D11DeviceContext> context; device->GetImmediateContext(&context); context->Flush();
  source.type = RILLIGHT_CORE_VIDEO_D3D11; source.data = nullptr;
  assert(Read(presenter.Present(source,gpu.Get(),2,1)) == bgra);
  bool invalid = false;
  try { presenter.Present(source,nullptr,2,1); }
  catch (const std::exception&) { invalid = true; }
  assert(invalid);

  // Native output preserves FP16 highlights. Its cropped subtitle overlay
  // blends in linear light at the configured SDR white level.
  desc.Format = DXGI_FORMAT_R16G16B16A16_FLOAT;
  const uint16_t bright[] = {0x4a40,0x4a40,0x4a40,0x3c00, 0x4a40,0x4a40,0x4a40,0x3c00}; // 12.5 = 1000 nits
  data.pSysMem = bright; data.SysMemPitch = 16;
  gpu.Reset(); assert(SUCCEEDED(device->CreateTexture2D(&desc,&data,&gpu)));
  context->Flush();
  desc.MiscFlags = 0;
  ComPtr<ID3D11Texture2D> hdr;
  assert(SUCCEEDED(presenter.device()->CreateTexture2D(&desc,nullptr,&hdr)));
  auto read_hdr = [&]() {
    ComPtr<ID3D11DeviceContext> render; presenter.device()->GetImmediateContext(&render);
    auto staging_desc = desc;
    staging_desc.Usage = D3D11_USAGE_STAGING; staging_desc.BindFlags = 0;
    staging_desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    ComPtr<ID3D11Texture2D> staging;
    assert(SUCCEEDED(presenter.device()->CreateTexture2D(&staging_desc,nullptr,&staging)));
    render->CopyResource(staging.Get(),hdr.Get());
    D3D11_MAPPED_SUBRESOURCE mapped{};
    assert(SUCCEEDED(render->Map(staging.Get(),0,D3D11_MAP_READ,0,&mapped)));
    std::vector<uint16_t> pixels(8); std::memcpy(pixels.data(),mapped.pData,16);
    render->Unmap(staging.Get(),0); return pixels;
  };
  presenter.PresentHdr(source,gpu.Get(),hdr.Get(),160);
  assert(read_hdr() == std::vector<uint16_t>(std::begin(bright),std::end(bright)));
  const uint8_t white[] = {128,128,128,128};
  RillightCoreSubtitleOverlay overlay{sizeof(overlay),0,0,1,1,4,white};
  presenter.PresentHdr(source,gpu.Get(),hdr.Get(),160,&overlay);
  auto composed = read_hdr();
  assert(composed[0] > 0x4700 && composed[0] < 0x4750); // approximately 7.23, still HDR
  assert(composed[1] == composed[0] && composed[2] == composed[0]);
  assert(composed[4] == bright[4] && composed[5] == bright[5] && composed[6] == bright[6]);
  bool hdr_to_sdr_rejected = false;
  try { presenter.Present(source,gpu.Get(),2,1); }
  catch (const std::exception&) { hdr_to_sdr_rejected = true; }
  assert(hdr_to_sdr_rejected);
}
