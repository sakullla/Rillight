#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();
  const bool is_player = !command_line_arguments.empty() &&
                         command_line_arguments[0] == "player";

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project, /*native_caption_buttons=*/!is_player);

  RECT work{};
  SystemParametersInfo(SPI_GETWORKAREA, 0, &work, 0);
  const UINT dpi = GetDpiForSystem();
  const double scale = dpi == 0 ? 1.0 : dpi / 96.0;
  const int work_w = static_cast<int>((work.right - work.left) / scale);
  const int work_h = static_cast<int>((work.bottom - work.top) / scale);
  // Match lib/app/window_geometry.dart. Browse caps at 1440x810; the
  // standalone player is a popup and caps at 1280x720.
  const int kMaxDefaultW = is_player ? 1280 : 1440;
  const int kMaxDefaultH = is_player ? 720 : 810;
  const int kMinW = is_player ? 800 : 960;
  const int kMinH = is_player ? 450 : 540;
  double fraction = 0.90;
  if (work_w >= 2560) {
    fraction = 0.55;
  } else if (work_w >= 1920) {
    fraction = 0.70;
  } else if (work_w >= 1440) {
    fraction = 0.78;
  }
  int width = static_cast<int>(work_w * fraction);
  if (width > kMaxDefaultW) {
    width = kMaxDefaultW;
  }
  int height = static_cast<int>(width * 9.0 / 16.0);
  int max_h = static_cast<int>(work_h * fraction);
  if (max_h > kMaxDefaultH) {
    max_h = kMaxDefaultH;
  }
  if (height > max_h) {
    height = max_h;
    width = static_cast<int>(height * 16.0 / 9.0);
  }
  if (width > work_w) {
    width = work_w;
  }
  if (height > work_h) {
    height = work_h;
  }
  if (width < kMinW) {
    width = work_w < kMinW ? work_w : kMinW;
  }
  if (height < kMinH) {
    height = work_h < kMinH ? work_h : kMinH;
  }
  const int origin_x =
      static_cast<int>(work.left / scale) + (work_w - width) / 2;
  const int origin_y =
      static_cast<int>(work.top / scale) + (work_h - height) / 2;

  Win32Window::Point origin(origin_x > 0 ? origin_x : 10,
                            origin_y > 0 ? origin_y : 10);
  Win32Window::Size size(width, height);
  if (!window.Create(L"\u706F\u5DDD Rillight", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
