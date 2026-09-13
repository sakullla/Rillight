#include "flutter_window.h"

#include <dwmapi.h>
#include <optional>
#include <windowsx.h>

#include "flutter/generated_plugin_registrant.h"
#include "desktop_multi_window/desktop_multi_window_plugin.h"

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
  DesktopMultiWindowSetWindowCreatedCallback([](void *controller) {
    auto *flutter_view_controller =
        reinterpret_cast<flutter::FlutterViewController *>(controller);
    auto *registry = flutter_view_controller->engine();
    RegisterPlugins(registry);
  });
  HWND flutter_view = flutter_controller_->view()->GetNativeWindow();
  SetChildContent(flutter_view);

  flutter_view_hwnd_ = flutter_view;
  g_original_flutter_view_proc = reinterpret_cast<WNDPROC>(SetWindowLongPtr(
      flutter_view, GWLP_WNDPROC, reinterpret_cast<LONG_PTR>(FlutterViewWndProc)));

  // Do not Show on first frame. Dart applies TitleBarStyle.hidden and the
  // intended size while the HWND is still hidden; showing 1280x720 with a
  // caption here, then hiding the bar and resizing, is the shrink-then-grow
  // flash. configureMainWindow / player _configureWindow call Show.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
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

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
