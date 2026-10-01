#pragma once

#include <d3d11.h>
#include <dxgi.h>
#include <wrl/client.h>
#include <memory>
#include <stdexcept>

#include "../native/core/rillight_core.h"

namespace rillight_windows {
class GpuImportUnavailable : public std::runtime_error {
 public:
  GpuImportUnavailable() : std::runtime_error("Decoder GPU texture cannot be imported on the display adapter") {}
};
struct GpuPixelFrame {
  Microsoft::WRL::ComPtr<ID3D11Texture2D> texture;
  HANDLE handle = nullptr;
  int width = 0;
  int height = 0;
};

// The Flutter ANGLE framebuffer imports BGRA render targets. Keep each
// published allocation immutable until Flutter retires its imported image.
class GpuPresenter {
 public:
  explicit GpuPresenter(IDXGIAdapter* adapter);
  std::shared_ptr<GpuPixelFrame> Present(const RillightCoreFrame& frame,
      void* native_texture, int width, int height);
  ID3D11Device* device() const { return device_.Get(); }
  void PresentHdr(const RillightCoreFrame& frame, void* native_texture,
      ID3D11Texture2D* target, float sdr_white_nits,
      const RillightCoreSubtitleOverlay* overlay = nullptr);

 private:
  void Draw(const RillightCoreFrame& frame, void* native_texture,
      ID3D11Texture2D* target, int width, int height, float sdr_white_nits,
      const RillightCoreSubtitleOverlay* overlay);
  Microsoft::WRL::ComPtr<ID3D11Device> device_;
  Microsoft::WRL::ComPtr<ID3D11DeviceContext> context_;
  Microsoft::WRL::ComPtr<ID3D11VertexShader> vertex_;
  Microsoft::WRL::ComPtr<ID3D11PixelShader> pixel_;
  Microsoft::WRL::ComPtr<ID3D11Buffer> parameters_;
  Microsoft::WRL::ComPtr<ID3D11SamplerState> sampler_;
  Microsoft::WRL::ComPtr<ID3D11RasterizerState> raster_;
  Microsoft::WRL::ComPtr<ID3D11Query> complete_;
};
}  // namespace rillight_windows
