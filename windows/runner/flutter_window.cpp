#include "flutter_window.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <dwmapi.h>
#include <optional>
#include <windowsx.h>

#include "flutter/generated_plugin_registrant.h"

#ifndef DWMWA_BORDER_COLOR
#define DWMWA_BORDER_COLOR 34
#endif
#ifndef DWMWA_CAPTION_COLOR
#define DWMWA_CAPTION_COLOR 35
#endif
#ifndef DWMWA_TEXT_COLOR
#define DWMWA_TEXT_COLOR 36
#endif
#ifndef DWMWA_COLOR_NONE
#define DWMWA_COLOR_NONE 0xFFFFFFFE
#endif

namespace {

// Matches window_manager kWindowCaptionHeight and WindowCaption button width.
constexpr int kCaptionHeightDip = 32;
constexpr int kCaptionButtonWidthDip = 46;
constexpr int kCaptionButtonCount = 3;

WNDPROC g_original_flutter_view_proc = nullptr;
bool g_intercept_caption_clicks = true;

int ScaleDip(HWND hwnd, int dip) {
  const int dpi = static_cast<int>(GetDpiForWindow(hwnd));
  return MulDiv(dip, dpi == 0 ? 96 : dpi, 96);
}

bool IsCaptionButtonHit(LRESULT hit) {
  return hit == HTMINBUTTON || hit == HTMAXBUTTON || hit == HTCLOSE;
}

void PostCaptionCommand(HWND hwnd, LRESULT hit) {
  if (hit == HTMINBUTTON) {
    PostMessage(hwnd, WM_SYSCOMMAND, SC_MINIMIZE, 0);
  } else if (hit == HTMAXBUTTON) {
    PostMessage(hwnd, WM_SYSCOMMAND,
                IsZoomed(hwnd) ? SC_RESTORE : SC_MAXIMIZE, 0);
  } else if (hit == HTCLOSE) {
    PostMessage(hwnd, WM_SYSCOMMAND, SC_CLOSE, 0);
  }
}

// Native caption buttons in the extended client area. Returning HTMAXBUTTON
// from the top-level window is what lets Windows 11 Snap Layouts attach.
LRESULT CaptionButtonHitTest(HWND hwnd, LPARAM lparam) {
  POINT pt{GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
  if (!ScreenToClient(hwnd, &pt)) {
    return 0;
  }

  RECT client{};
  if (!GetClientRect(hwnd, &client)) {
    return 0;
  }

  const int caption_height = ScaleDip(hwnd, kCaptionHeightDip);
  const int button_width = ScaleDip(hwnd, kCaptionButtonWidthDip);
  const int strip_width = button_width * kCaptionButtonCount;
  if (pt.y < 0 || pt.y >= caption_height || pt.x < client.right - strip_width ||
      pt.x >= client.right) {
    return 0;
  }

  const int offset_from_right = client.right - pt.x;
  if (offset_from_right <= button_width) {
    return HTCLOSE;
  }
  if (offset_from_right <= button_width * 2) {
    return HTMAXBUTTON;
  }
  return HTMINBUTTON;
}

int ChannelInt(const flutter::EncodableMap& map, const char* key) {
  const auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) {
    return -1;
  }
  const std::optional<int64_t> value = it->second.TryGetLongValue();
  if (!value.has_value() || *value < 0 || *value > 255) {
    return -1;
  }
  return static_cast<int>(*value);
}

bool ChannelColor(const flutter::EncodableMap& map,
                  const char* red_key,
                  const char* green_key,
                  const char* blue_key,
                  COLORREF* out) {
  const int red = ChannelInt(map, red_key);
  const int green = ChannelInt(map, green_key);
  const int blue = ChannelInt(map, blue_key);
  if (red < 0 || green < 0 || blue < 0) {
    return false;
  }
  *out = RGB(red, green, blue);
  return true;
}

LRESULT CALLBACK FlutterViewWndProc(HWND hwnd,
                                    UINT message,
                                    WPARAM wparam,
                                    LPARAM lparam) {
  if (!g_intercept_caption_clicks) {
    return CallWindowProc(g_original_flutter_view_proc, hwnd, message, wparam,
                          lparam);
  }
  HWND root = GetAncestor(hwnd, GA_ROOT);
  if (message == WM_NCHITTEST) {
    if (root && CaptionButtonHitTest(root, lparam) != 0) {
      // Let the top-level window report HTMAXBUTTON/HTCLOSE/HTMINBUTTON.
      return HTTRANSPARENT;
    }
  }
  // Hidden title bar: the Flutter child often sees these as client clicks.
  // Run the caption command here if NCLBUTTONDOWN never reaches the parent.
  if (root && (message == WM_LBUTTONDOWN || message == WM_LBUTTONDBLCLK)) {
    POINT pt{GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
    if (ClientToScreen(hwnd, &pt)) {
      const LRESULT hit =
          CaptionButtonHitTest(root, MAKELPARAM(pt.x, pt.y));
      if (IsCaptionButtonHit(hit)) {
        PostCaptionCommand(root, hit);
        return 0;
      }
    }
  }
  return CallWindowProc(g_original_flutter_view_proc, hwnd, message, wparam,
                        lparam);
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project,
                             bool native_caption_buttons)
    : project_(project), native_caption_buttons_(native_caption_buttons) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }
  g_intercept_caption_clicks = native_caption_buttons_;

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  if (native_caption_buttons_) {
    caption_channel_ =
        std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
            flutter_controller_->engine()->messenger(), "com.rillight/window",
            &flutter::StandardMethodCodec::GetInstance());
    caption_channel_->SetMethodCallHandler(
        [this](const flutter::MethodCall<flutter::EncodableValue>& call,
               std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                   result) {
          if (call.method_name() != "setCaptionColors") {
            result->NotImplemented();
            return;
          }
          const auto* args_value = call.arguments();
          if (args_value == nullptr ||
              !std::holds_alternative<flutter::EncodableMap>(*args_value)) {
            result->Error("bad_args", "setCaptionColors expects a map");
            return;
          }
          const auto& args = std::get<flutter::EncodableMap>(*args_value);
          const auto dark_it = args.find(flutter::EncodableValue("dark"));
          if (dark_it == args.end() ||
              !std::holds_alternative<bool>(dark_it->second)) {
            result->Error("bad_args", "dark must be a bool");
            return;
          }
          COLORREF border = 0;
          COLORREF symbol = 0;
          if (!ChannelColor(args, "captionRed", "captionGreen", "captionBlue",
                            &border) ||
              !ChannelColor(args, "symbolRed", "symbolGreen", "symbolBlue",
                            &symbol)) {
            result->Error("bad_args", "caption and symbol colors are 0-255");
            return;
          }
          caption_dark_ = std::get<bool>(dark_it->second);
          caption_border_ = border;
          caption_symbol_ = symbol;
          caption_colors_set_ = true;
          ApplyCaptionChrome();
          result->Success();
        });
    // Title-bar style is applied later from Dart and can restore the default
    // white plate. Clear it now, then again once the theme colors arrive.
    SuppressCaptionPlate();
  }
  HWND flutter_view = flutter_controller_->view()->GetNativeWindow();
  SetChildContent(flutter_view);

  flutter_view_hwnd_ = flutter_view;
  g_original_flutter_view_proc = reinterpret_cast<WNDPROC>(SetWindowLongPtr(
      flutter_view, GWLP_WNDPROC, reinterpret_cast<LONG_PTR>(FlutterViewWndProc)));

  // Dart prepares the title bar and size before requesting Show. That request
  // can precede Flutter's first rasterized frame: keep the window hidden until
  // both conditions hold, without showing the initial native geometry.
  flutter_controller_->engine()->SetNextFrameCallback([this]() {
    first_frame_ready_ = true;
    if (show_requested_) {
      show_requested_ = false;
      Show();
    }
  });
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::SuppressCaptionPlate() noexcept {
  const HWND hwnd = GetHandle();
  if (!hwnd || !native_caption_buttons_) {
    return;
  }
  // HTMINBUTTON/HTMAXBUTTON/HTCLOSE make Windows 11 paint an opaque caption
  // plate over the client area. Matching the page color still hides the
  // Flutter glyphs, so the plate must not be rendered.
  const COLORREF caption = DWMWA_COLOR_NONE;
  DwmSetWindowAttribute(hwnd, DWMWA_CAPTION_COLOR, &caption, sizeof(caption));
}

void FlutterWindow::ApplyCaptionChrome() noexcept {
  const HWND hwnd = GetHandle();
  if (!hwnd || !native_caption_buttons_ || !caption_colors_set_) {
    return;
  }
  const BOOL dark = caption_dark_ ? TRUE : FALSE;
  DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, &dark,
                        sizeof(dark));
  SuppressCaptionPlate();
  DwmSetWindowAttribute(hwnd, DWMWA_TEXT_COLOR, &caption_symbol_,
                        sizeof(caption_symbol_));
  DwmSetWindowAttribute(hwnd, DWMWA_BORDER_COLOR, &caption_border_,
                        sizeof(caption_border_));
}

void FlutterWindow::OnDestroy() {
  if (caption_channel_) {
    caption_channel_->SetMethodCallHandler(nullptr);
    caption_channel_.reset();
  }
  if (flutter_view_hwnd_ && g_original_flutter_view_proc) {
    auto current = reinterpret_cast<WNDPROC>(
        GetWindowLongPtr(flutter_view_hwnd_, GWLP_WNDPROC));
    if (current == FlutterViewWndProc) {
      SetWindowLongPtr(flutter_view_hwnd_, GWLP_WNDPROC,
                       reinterpret_cast<LONG_PTR>(g_original_flutter_view_proc));
    }
  }
  flutter_view_hwnd_ = nullptr;
  g_original_flutter_view_proc = nullptr;

  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == WM_WINDOWPOSCHANGING && !first_frame_ready_) {
    auto* position = reinterpret_cast<WINDOWPOS*>(lparam);
    if (position->flags & SWP_SHOWWINDOW) {
      position->flags &= ~SWP_SHOWWINDOW;
      show_requested_ = true;
    }
  }
  if (native_caption_buttons_) {
    if (message == WM_NCHITTEST) {
      LRESULT dwm_hit = 0;
      if (DwmDefWindowProc(hwnd, message, wparam, lparam, &dwm_hit) &&
          IsCaptionButtonHit(dwm_hit)) {
        return dwm_hit;
      }
      LRESULT caption_hit = CaptionButtonHitTest(hwnd, lparam);
      if (caption_hit != 0) {
        return caption_hit;
      }
    } else if (message == WM_NCMOUSEMOVE || message == WM_NCMOUSELEAVE) {
      LRESULT dwm_hit = 0;
      if (DwmDefWindowProc(hwnd, message, wparam, lparam, &dwm_hit)) {
        return dwm_hit;
      }
    } else if (message == WM_NCLBUTTONDOWN || message == WM_NCLBUTTONDBLCLK) {
      if (IsCaptionButtonHit(static_cast<LRESULT>(wparam))) {
        PostCaptionCommand(hwnd, static_cast<LRESULT>(wparam));
        return 0;
      }
    }
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  const LRESULT handled =
      Win32Window::MessageHandler(hwnd, message, wparam, lparam);
  // UpdateTheme follows the system app theme and can put a white plate or
  // white symbols back over a light page. Re-apply the app's own colors.
  if (native_caption_buttons_ &&
      (message == WM_DWMCOLORIZATIONCOLORCHANGED || message == WM_ACTIVATE)) {
    if (caption_colors_set_) {
      ApplyCaptionChrome();
    } else if (message == WM_DWMCOLORIZATIONCOLORCHANGED) {
      SuppressCaptionPlate();
    }
  }
  return handled;
}
