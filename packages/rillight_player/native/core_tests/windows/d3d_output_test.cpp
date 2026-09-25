#include <Windows.h>
#include <d3d11.h>
#include <dxgi.h>
#include <wrl/client.h>

#include <cstdint>
#include <cstdio>
#include <initializer_list>

using Microsoft::WRL::ComPtr;

int main() {
  ComPtr<ID3D11Device> device;
  ComPtr<ID3D11DeviceContext> context;
  const D3D_FEATURE_LEVEL level = D3D_FEATURE_LEVEL_11_0;
  const HRESULT created = D3D11CreateDevice(
      nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
      D3D11_CREATE_DEVICE_BGRA_SUPPORT, &level, 1, D3D11_SDK_VERSION,
      &device, nullptr, &context);
  if (FAILED(created)) {
    std::fprintf(stderr, "D3D11 hardware device unavailable: 0x%08lx\n",
                 static_cast<unsigned long>(created));
    return 1;
  }
  D3D11_TEXTURE2D_DESC shared_description{};
  shared_description.Width = 2;
  shared_description.Height = 1;
  shared_description.MipLevels = 1;
  shared_description.ArraySize = 1;
  shared_description.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
  shared_description.SampleDesc.Count = 1;
  shared_description.Usage = D3D11_USAGE_DEFAULT;
  shared_description.BindFlags =
      D3D11_BIND_SHADER_RESOURCE | D3D11_BIND_RENDER_TARGET;
  shared_description.MiscFlags = D3D11_RESOURCE_MISC_SHARED;
  D3D11_TEXTURE2D_DESC readback_description = shared_description;
  readback_description.Usage = D3D11_USAGE_STAGING;
  readback_description.BindFlags = 0;
  readback_description.MiscFlags = 0;
  readback_description.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
  ComPtr<ID3D11Texture2D> readback;
  if (FAILED(device->CreateTexture2D(&readback_description, nullptr,
                                     &readback))) return 2;
  for (uint8_t value : {static_cast<uint8_t>(0x21),
                        static_cast<uint8_t>(0xb4)}) {
    uint8_t pixels[8] = {value, 0, 0, 255, value, 0, 0, 255};
    D3D11_SUBRESOURCE_DATA initial{};
    initial.pSysMem = pixels;
    initial.SysMemPitch = 8;
    ComPtr<ID3D11Texture2D> shared;
    if (FAILED(device->CreateTexture2D(&shared_description, &initial,
                                       &shared))) return 3;
    context->Flush();
    ComPtr<IDXGIResource> resource;
    if (FAILED(shared.As(&resource))) return 4;
    HANDLE handle = nullptr;
    if (FAILED(resource->GetSharedHandle(&handle)) || !handle) return 5;
    ComPtr<ID3D11Texture2D> imported;
    if (FAILED(device->OpenSharedResource(handle, IID_PPV_ARGS(&imported))))
      return 6;
    context->CopyResource(readback.Get(), imported.Get());
    D3D11_MAPPED_SUBRESOURCE mapped{};
    if (FAILED(context->Map(readback.Get(), 0, D3D11_MAP_READ, 0, &mapped)))
      return 7;
    const auto* actual = static_cast<const uint8_t*>(mapped.pData);
    const bool matched = actual[0] == value && actual[4] == value &&
                         actual[3] == 255 && actual[7] == 255;
    if (!matched) {
      std::fprintf(stderr,
                   "shared frame mismatch: wanted=%u got=[%u,%u,%u,%u] pitch=%u\n",
                   value, actual[0], actual[3], actual[4], actual[7],
                   mapped.RowPitch);
    }
    context->Unmap(readback.Get(), 0);
    if (!matched) return 8;
  }
  std::puts("D3D11 shared textures contained both changing frames");
  return 0;
}
