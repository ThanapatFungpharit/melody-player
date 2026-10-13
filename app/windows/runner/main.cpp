#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter_windows.h>
#include <windows.h>

#include <algorithm>
#include <cwchar>
#include <optional>

#include "flutter_window.h"
#include "utils.h"

namespace {

// MELODY_WINDOW_SIZE=390x844 sizes the window's content in logical pixels,
// such as a phone's screen, while developing (see tools/dev/env.py).
std::optional<Win32Window::Size> RequestedContentSize() {
  wchar_t value[32];
  DWORD length = ::GetEnvironmentVariableW(L"MELODY_WINDOW_SIZE", value, 32);
  unsigned int width = 0;
  unsigned int height = 0;
  if (length > 0 && length < 32 &&
      swscanf_s(value, L"%ux%u", &width, &height) == 2 && width > 0 &&
      height > 0) {
    return Win32Window::Size(width, height);
  }
  return std::nullopt;
}

// Win32Window sizes the whole window, frame included; this grows it so the
// content area alone has |size|, as on the device being previewed. A window
// taller than the screen is cut to fit, so the bottom navigation stays
// reachable above the taskbar.
void FitContent(HWND window, const Win32Window::Size& size) {
  RECT frame;
  RECT content;
  ::GetWindowRect(window, &frame);
  ::GetClientRect(window, &content);
  double scale = FlutterDesktopGetDpiForHWND(window) / 96.0;
  int width = static_cast<int>(size.width * scale) +
              (frame.right - frame.left) - content.right;
  int height = static_cast<int>(size.height * scale) +
               (frame.bottom - frame.top) - content.bottom;
  int top = frame.top;
  MONITORINFO monitor{sizeof(MONITORINFO)};
  if (::GetMonitorInfo(::MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST),
                       &monitor)) {
    const RECT& work = monitor.rcWork;
    if (top + height > work.bottom) {
      top = work.top;
      height = std::min(height, static_cast<int>(work.bottom - work.top));
    }
  }
  ::SetWindowPos(window, nullptr, frame.left, top, width, height,
                 SWP_NOZORDER | SWP_NOACTIVATE);
}

}  // namespace

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

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1540, 960);
  std::optional<Win32Window::Size> content = RequestedContentSize();
  if (!window.Create(L"Melody", origin, content.value_or(size))) {
    return EXIT_FAILURE;
  }
  if (content) {
    FitContent(window.GetHandle(), *content);
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
