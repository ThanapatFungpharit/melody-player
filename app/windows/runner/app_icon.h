#ifndef RUNNER_APP_ICON_H_
#define RUNNER_APP_ICON_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>

// Shows the icon Dart draws for the saved accent color on the window and its
// taskbar button. The executable's own icon, used by shortcuts, stays as built.
class AppIcon {
 public:
  AppIcon(flutter::BinaryMessenger* messenger, HWND window);
  ~AppIcon();

  AppIcon(const AppIcon&) = delete;
  AppIcon& operator=(const AppIcon&) = delete;

  // Picks the closest images again for the window's new DPI.
  void OnDpiChanged();

 private:
  void Apply();

  HWND window_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  // PNG images by pixel size, as last sent by Dart.
  flutter::EncodableMap images_;
  HICON small_ = nullptr;
  HICON big_ = nullptr;
};

#endif  // RUNNER_APP_ICON_H_
