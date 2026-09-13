#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>

#include <memory>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  // |native_caption_buttons| is false for the player process, which draws its
  // own close control and must not swallow clicks as HTMAXBUTTON/HTCLOSE.
  explicit FlutterWindow(const flutter::DartProject& project,
                         bool native_caption_buttons = true);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // Flutter view HWND whose WndProc is subclassed so caption-button
  // WM_NCHITTEST can fall through to the top-level window (HTMAXBUTTON).
  HWND flutter_view_hwnd_ = nullptr;

  bool native_caption_buttons_ = true;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
