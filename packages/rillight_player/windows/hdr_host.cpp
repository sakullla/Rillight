#include "hdr_host.h"

#include <dwmapi.h>
#include <algorithm>
#include <cmath>
#include <stdexcept>
#include <vector>

namespace rillight_windows {
namespace {
using Microsoft::WRL::ComPtr;
constexpr wchar_t kClass[] = L"RillightNativeHdrVideo";
void Check(HRESULT result) {
  if (FAILED(result)) throw std::runtime_error("Native HDR presentation failed");
}
float SdrWhite(HWND window) {
  MONITORINFOEXW monitor{}; monitor.cbSize = sizeof(monitor);
  if (!GetMonitorInfoW(MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST), reinterpret_cast<MONITORINFO*>(&monitor))) return 203;
  UINT paths_count = 0, modes_count = 0;
  if (GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, &paths_count, &modes_count) != ERROR_SUCCESS) return 203;
  std::vector<DISPLAYCONFIG_PATH_INFO> paths(paths_count);
  std::vector<DISPLAYCONFIG_MODE_INFO> modes(modes_count);
  if (QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, &paths_count, paths.data(), &modes_count, modes.data(), nullptr) != ERROR_SUCCESS) return 203;
  for (UINT i = 0; i < paths_count; ++i) {
    DISPLAYCONFIG_SOURCE_DEVICE_NAME source{};
    source.header = {DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME, sizeof(source), paths[i].sourceInfo.adapterId, paths[i].sourceInfo.id};
    if (DisplayConfigGetDeviceInfo(&source.header) != ERROR_SUCCESS ||
        wcscmp(source.viewGdiDeviceName, monitor.szDevice) != 0) continue;
    DISPLAYCONFIG_SDR_WHITE_LEVEL white{};
    white.header = {DISPLAYCONFIG_DEVICE_INFO_GET_SDR_WHITE_LEVEL, sizeof(white), paths[i].targetInfo.adapterId, paths[i].targetInfo.id};
    if (DisplayConfigGetDeviceInfo(&white.header) == ERROR_SUCCESS)
      return std::clamp(80.0f * white.SDRWhiteLevel / 1000.0f, 48.0f, 1000.0f);
  }
  return 203;
}
}

HdrDisplayInfo QueryHdrDisplay(HWND window, ID3D11Device* device) {
  HdrDisplayInfo result;
  ComPtr<IDXGIDevice> dxgi; ComPtr<IDXGIAdapter> adapter;
  if (FAILED(device->QueryInterface(IID_PPV_ARGS(&dxgi))) || FAILED(dxgi->GetAdapter(&adapter))) return result;
  const auto monitor = MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST);
  for (UINT index = 0;; ++index) {
    ComPtr<IDXGIOutput> output;
    if (adapter->EnumOutputs(index, &output) == DXGI_ERROR_NOT_FOUND) break;
    ComPtr<IDXGIOutput6> advanced;
    if (!output || FAILED(output.As(&advanced))) continue;
    DXGI_OUTPUT_DESC1 desc{};
    if (FAILED(advanced->GetDesc1(&desc)) || desc.Monitor != monitor || !desc.AttachedToDesktop) continue;
    result.active = desc.BitsPerColor >= 10 && desc.ColorSpace == DXGI_COLOR_SPACE_RGB_FULL_G2084_NONE_P2020;
    result.peak_nits = std::isfinite(desc.MaxLuminance) ? desc.MaxLuminance : 0;
    result.sdr_white_nits = SdrWhite(window);
    break;
  }
  return result;
}

HdrHost::HdrHost(HWND flutter_window, GpuPresenter* presenter) : presenter_(presenter) {
  parent_ = GetAncestor(flutter_window, GA_ROOT);
  const auto info = QueryHdrDisplay(parent_, presenter_->device());
  if (!info.active) throw std::runtime_error("HDR display is not active");
  sdr_white_nits_ = info.sdr_white_nits;
  ComPtr<IDXGIDevice> dxgi; Check(presenter_->device()->QueryInterface(IID_PPV_ARGS(&dxgi)));
  ComPtr<IDXGIAdapter> adapter; Check(dxgi->GetAdapter(&adapter));
  ComPtr<IDXGIFactory2> factory; Check(adapter->GetParent(IID_PPV_ARGS(&factory)));
  WNDCLASSW wc{}; wc.hInstance = GetModuleHandleW(nullptr);
  wc.lpfnWndProc = DefWindowProcW; wc.lpszClassName = kClass;
  if (!RegisterClassW(&wc) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS)
    throw std::runtime_error("Native HDR window registration failed");
  RECT client{}; GetClientRect(parent_, &client);
  POINT origin{}; ClientToScreen(parent_, &origin);
  window_ = CreateWindowExW(WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW, kClass, L"",
      WS_POPUP, origin.x, origin.y, std::max(1L, client.right), std::max(1L, client.bottom),
      nullptr, nullptr, wc.hInstance, nullptr);
  if (!window_) throw std::runtime_error("Native HDR window creation failed");
  try {
    width_ = std::max(1L, client.right); height_ = std::max(1L, client.bottom);
    DXGI_SWAP_CHAIN_DESC1 desc{};
    desc.Width = width_; desc.Height = height_; desc.Format = DXGI_FORMAT_R16G16B16A16_FLOAT;
    desc.SampleDesc.Count = 1; desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    desc.BufferCount = 2; desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL;
    desc.AlphaMode = DXGI_ALPHA_MODE_IGNORE;
    Check(factory->CreateSwapChainForHwnd(presenter_->device(), window_, &desc, nullptr, nullptr, &chain_));
    ComPtr<IDXGISwapChain3> advanced; Check(chain_.As(&advanced));
    UINT supported = 0;
    Check(advanced->CheckColorSpaceSupport(DXGI_COLOR_SPACE_RGB_FULL_G10_NONE_P709, &supported));
    if (!(supported & DXGI_SWAP_CHAIN_COLOR_SPACE_SUPPORT_FLAG_PRESENT))
      throw std::runtime_error("scRGB presentation is unavailable");
    Check(advanced->SetColorSpace1(DXGI_COLOR_SPACE_RGB_FULL_G10_NONE_P709));
    factory->MakeWindowAssociation(window_, DXGI_MWA_NO_ALT_ENTER);
    ComPtr<IDXGIDevice1> latency;
    if (SUCCEEDED(dxgi.As(&latency))) latency->SetMaximumFrameLatency(1);
    // Initialize the native image before any transparent Flutter frame appears.
    ComPtr<ID3D11Texture2D> buffer; Check(chain_->GetBuffer(0, IID_PPV_ARGS(&buffer)));
    ComPtr<ID3D11RenderTargetView> view;
    Check(presenter_->device()->CreateRenderTargetView(buffer.Get(), nullptr, &view));
    ComPtr<ID3D11DeviceContext> context; presenter_->device()->GetImmediateContext(&context);
    const float black[] = {0,0,0,1}; context->ClearRenderTargetView(view.Get(), black);
    Check(chain_->Present(0,0));
  } catch (...) { DestroyWindow(window_); window_ = nullptr; throw; }
}

HdrHost::~HdrHost() {
  if (!window_) return;
  // Renderer retirement may finish on Flutter's raster thread. Window
  // destruction belongs to its original UI thread in that case.
  if (GetCurrentThreadId() == GetWindowThreadProcessId(window_, nullptr)) DestroyWindow(window_);
  else PostMessageW(window_, WM_CLOSE, 0, 0);
}

void HdrHost::Activate() {
  MARGINS margins{-1,-1,-1,-1}; Check(DwmExtendFrameIntoClientArea(parent_, &margins));
  DWM_BLURBEHIND blur{}; blur.dwFlags = DWM_BB_ENABLE | DWM_BB_BLURREGION;
  blur.fEnable = TRUE; blur.hRgnBlur = CreateRectRgn(0,0,-1,-1);
  const auto result = DwmEnableBlurBehindWindow(parent_, &blur);
  DeleteObject(blur.hRgnBlur); Check(result);
  active_ = true; UpdateWindow();
}

void HdrHost::UpdateWindow() {
  if (!active_) return;
  if (!IsWindowVisible(parent_) || IsIconic(parent_)) { ShowWindow(window_, SW_HIDE); return; }
  RECT client{}; GetClientRect(parent_, &client);
  POINT origin{}; ClientToScreen(parent_, &origin);
  SetWindowPos(window_, parent_, origin.x, origin.y, std::max(1L, client.right), std::max(1L, client.bottom),
      SWP_NOACTIVATE | SWP_SHOWWINDOW);
  sdr_white_nits_ = SdrWhite(parent_);
}

void HdrHost::Hide() { active_ = false; ShowWindow(window_, SW_HIDE); }

void HdrHost::Draw(const RillightCoreFrame& source, void* texture,
    const RillightCoreSubtitleOverlay* overlay, int width, int height) {
  if (width != width_ || height != height_) {
    Check(chain_->ResizeBuffers(2, width, height, DXGI_FORMAT_R16G16B16A16_FLOAT, 0));
    ComPtr<IDXGISwapChain3> advanced;
    Check(chain_.As(&advanced));
    Check(advanced->SetColorSpace1(DXGI_COLOR_SPACE_RGB_FULL_G10_NONE_P709));
    width_ = width; height_ = height;
  }
  ComPtr<ID3D11Texture2D> buffer; Check(chain_->GetBuffer(0, IID_PPV_ARGS(&buffer)));
  presenter_->PresentHdr(source, texture, buffer.Get(), sdr_white_nits_, overlay);
  if (texture) {
    D3D11_TEXTURE2D_DESC desc{}; static_cast<ID3D11Texture2D*>(texture)->GetDesc(&desc);
    if (desc.Format == DXGI_FORMAT_R16G16B16A16_FLOAT) ++hdr_source_frames_;
  }
}

void HdrHost::Commit() { Check(chain_->Present(0,0)); ++presented_frames_; }
HdrDisplayInfo HdrHost::display() const { return QueryHdrDisplay(parent_, presenter_->device()); }
HdrPresentStats HdrHost::stats() const {
  DXGI_FRAME_STATISTICS value{};
  LARGE_INTEGER frequency{};
  if (FAILED(chain_->GetFrameStatistics(&value)) || !QueryPerformanceFrequency(&frequency)) return {};
  return {true, value.PresentCount, value.PresentRefreshCount, value.SyncRefreshCount,
          value.SyncQPCTime.QuadPart, frequency.QuadPart};
}
} // namespace rillight_windows
