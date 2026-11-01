#ifndef ELARNI_CAMERA_CAPTURE_H_
#define ELARNI_CAMERA_CAPTURE_H_

#include <flutter/encodable_value.h>
#include <flutter/method_result.h>
#include <memory>
#include <mutex>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Graphics.Imaging.h>
#include <winrt/Windows.Media.Capture.h>
#include <winrt/Windows.Media.Capture.Frames.h>

class CameraCapture : public std::enable_shared_from_this<CameraCapture> {
 public:
  winrt::fire_and_forget Frame(std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  winrt::fire_and_forget Stop(bool shutdown = false);
 private:
  winrt::Windows::Foundation::IAsyncAction CloseAsync();
  winrt::Windows::Media::Capture::MediaCapture camera_{nullptr};
  winrt::Windows::Media::Capture::Frames::MediaFrameReader reader_{nullptr};
  winrt::Windows::Graphics::Imaging::SoftwareBitmap latest_{nullptr};
  winrt::event_token arrived_{};
  std::mutex frame_mutex_;
  uint64_t frame_generation_ = 0;
  uint64_t generation_ = 0;
  bool busy_ = false, shutdown_ = false;
};

#endif
