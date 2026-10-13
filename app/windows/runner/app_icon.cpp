#include "app_icon.h"

#include <flutter/standard_method_codec.h>

#include <cstdint>
#include <vector>

namespace {

// The smallest image at least |size| pixels wide, or the largest one.
const std::vector<uint8_t>* PickImage(const flutter::EncodableMap& images,
                                      int size) {
  const std::vector<uint8_t>* best = nullptr;
  int best_size = 0;
  for (const auto& [key, value] : images) {
    const auto* pixels = std::get_if<int32_t>(&key);
    const auto* png = std::get_if<std::vector<uint8_t>>(&value);
    if (!pixels || !png) continue;
    bool fits = *pixels >= size;
    bool best_fits = best_size >= size;
    if (!best || (fits && (!best_fits || *pixels < best_size)) ||
        (!fits && !best_fits && *pixels > best_size)) {
      best = png;
      best_size = *pixels;
    }
  }
  return best;
}

HICON CreateIcon(const flutter::EncodableMap& images, int size) {
  const std::vector<uint8_t>* png = PickImage(images, size);
  if (!png) return nullptr;
  // Icon resources may hold PNG data, which Windows decodes and scales.
  return CreateIconFromResourceEx(const_cast<PBYTE>(png->data()),
                                  static_cast<DWORD>(png->size()), TRUE,
                                  0x00030000, size, size, LR_DEFAULTCOLOR);
}

}  // namespace

AppIcon::AppIcon(flutter::BinaryMessenger* messenger, HWND window)
    : window_(window) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "melody/app_icon",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        const auto* images = std::get_if<flutter::EncodableMap>(call.arguments());
        if (call.method_name() != "setImages" || !images) {
          result->NotImplemented();
          return;
        }
        images_ = *images;
        Apply();
        result->Success();
      });
}

AppIcon::~AppIcon() {
  channel_->SetMethodCallHandler(nullptr);
  if (small_) DestroyIcon(small_);
  if (big_) DestroyIcon(big_);
}

void AppIcon::OnDpiChanged() {
  if (!images_.empty()) Apply();
}

void AppIcon::Apply() {
  UINT dpi = GetDpiForWindow(window_);
  HICON small_icon =
      CreateIcon(images_, GetSystemMetricsForDpi(SM_CXSMICON, dpi));
  HICON big_icon = CreateIcon(images_, GetSystemMetricsForDpi(SM_CXICON, dpi));
  if (!small_icon || !big_icon) {
    if (small_icon) DestroyIcon(small_icon);
    if (big_icon) DestroyIcon(big_icon);
    return;
  }
  SendMessage(window_, WM_SETICON, ICON_SMALL,
              reinterpret_cast<LPARAM>(small_icon));
  SendMessage(window_, WM_SETICON, ICON_BIG,
              reinterpret_cast<LPARAM>(big_icon));
  // The window no longer uses the previous pair.
  if (small_) DestroyIcon(small_);
  if (big_) DestroyIcon(big_);
  small_ = small_icon;
  big_ = big_icon;
}
