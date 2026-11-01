#include "camera_capture.h"
#include <cstdlib>
#include <limits>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Media.MediaProperties.h>
#include <winrt/Windows.Storage.Streams.h>

winrt::fire_and_forget CameraCapture::Frame(
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const auto lifetime = shared_from_this();
  if (shutdown_) co_return;
  if (busy_) { result->Error("busy", "The camera is busy."); co_return; }
  busy_ = true;
  const auto generation = generation_;
  bool failed = false;
  winrt::Windows::Graphics::Imaging::SoftwareBitmap bitmap{nullptr};
  try {
    using namespace winrt::Windows::Media::Capture;
    using namespace winrt::Windows::Media::Capture::Frames;
    using namespace winrt::Windows::Media::MediaProperties;
    using namespace winrt::Windows::Graphics::Imaging;
    using namespace winrt::Windows::Storage::Streams;
    if (!camera_) {
      camera_ = MediaCapture();
      MediaCaptureInitializationSettings settings;
      settings.StreamingCaptureMode(StreamingCaptureMode::Video);
      settings.MemoryPreference(MediaCaptureMemoryPreference::Cpu);
      co_await camera_.InitializeAsync(settings);
      if (generation != generation_) throw winrt::hresult_canceled();
      MediaFrameSource source{nullptr};
      for (const auto& entry : camera_.FrameSources()) {
        const auto info = entry.Value().Info();
        if (info.SourceKind() == MediaFrameSourceKind::Color &&
            (info.MediaStreamType() == MediaStreamType::VideoPreview ||
             info.MediaStreamType() == MediaStreamType::VideoRecord)) {
          source = entry.Value();
          if (info.MediaStreamType() == MediaStreamType::VideoPreview) break;
        }
      }
      if (!source) throw winrt::hresult_invalid_argument();
      MediaFrameFormat preferred{nullptr};
      uint64_t best = std::numeric_limits<uint64_t>::max();
      for (const auto& format : source.SupportedFormats()) {
        const auto video = format.VideoFormat();
        const auto rate = format.FrameRate();
        if (!video || rate.Denominator() == 0 || video.Width() == 0 || video.Height() == 0) continue;
        const auto fps = static_cast<double>(rate.Numerator()) / rate.Denominator();
        if (fps < 15 || video.Width() > 1920 || video.Height() > 1080) continue;
        const auto score = static_cast<uint64_t>(std::abs(static_cast<int>(video.Width()) - 640)) +
            std::abs(static_cast<int>(video.Height()) - 480) + (fps < 30 ? 10000 : 0);
        if (score < best) { best = score; preferred = format; }
      }
      if (preferred) co_await source.SetFormatAsync(preferred);
      if (generation != generation_) throw winrt::hresult_canceled();
      reader_ = co_await camera_.CreateFrameReaderAsync(source, MediaEncodingSubtypes::Bgra8(), BitmapSize{640, 480});
      if (generation != generation_) throw winrt::hresult_canceled();
      reader_.AcquisitionMode(MediaFrameReaderAcquisitionMode::Realtime);
      { std::lock_guard lock(frame_mutex_); frame_generation_ = generation; }
      const auto weak = weak_from_this();
      arrived_ = reader_.FrameArrived([weak, generation](const MediaFrameReader& sender, const auto&) {
        try {
          auto frame = sender.TryAcquireLatestFrame();
          if (!frame) return;
          auto video = frame.VideoMediaFrame();
          auto next = video ? video.SoftwareBitmap() : SoftwareBitmap{nullptr};
          frame.Close();
          if (!next) return;
          if (const auto self = weak.lock()) {
            std::lock_guard lock(self->frame_mutex_);
            if (generation == self->frame_generation_) std::swap(next, self->latest_);
          }
          if (next) next.Close();
        } catch (...) { /* A stopped source can race its last frame callback. */ }
      });
      if (co_await reader_.StartAsync() != MediaFrameReaderStartStatus::Success) throw winrt::hresult_invalid_argument();
    }
    if (generation != generation_) throw winrt::hresult_canceled();
    { std::lock_guard lock(frame_mutex_); std::swap(bitmap, latest_); }
    if (bitmap) {
      InMemoryRandomAccessStream stream;
      auto encoder = co_await BitmapEncoder::CreateAsync(BitmapEncoder::JpegEncoderId(), stream);
      encoder.SetSoftwareBitmap(bitmap);
      co_await encoder.FlushAsync();
      bitmap.Close(); bitmap = nullptr;
      if (stream.Size() == 0 || stream.Size() > 8 * 1024 * 1024) throw winrt::hresult_invalid_argument();
      DataReader input(stream.GetInputStreamAt(0));
      const auto size = static_cast<uint32_t>(stream.Size());
      if (co_await input.LoadAsync(size) != size) throw winrt::hresult_invalid_argument();
      std::vector<uint8_t> bytes(size);
      input.ReadBytes(bytes);
      input.Close(); stream.Close();
      if (!shutdown_ && generation == generation_) result->Success(flutter::EncodableValue(bytes));
      else if (!shutdown_) result->Error("cancelled", "Camera scanning was cancelled.");
    } else if (!shutdown_) {
      // Streaming continues while the UI waits for the next fresh video frame.
      result->Success();
    }
  } catch (...) {
    failed = true;
    try { if (bitmap) bitmap.Close(); } catch (...) {}
    if (!shutdown_) result->Error(generation == generation_ ? "camera_unavailable" : "cancelled",
        "The camera could not provide a frame.");
  }
  if (failed && generation == generation_) ++generation_;
  if (generation != generation_) co_await CloseAsync();
  busy_ = false;
}

winrt::Windows::Foundation::IAsyncAction CameraCapture::CloseAsync() {
  {
    std::lock_guard lock(frame_mutex_);
    ++frame_generation_;
    try { if (latest_) latest_.Close(); } catch (...) {}
    latest_ = nullptr;
  }
  if (reader_) {
    try { reader_.FrameArrived(arrived_); } catch (...) {}
    try { co_await reader_.StopAsync(); } catch (...) {}
    try { reader_.Close(); } catch (...) {}
    reader_ = nullptr;
  }
  try { if (camera_) camera_.Close(); } catch (...) {}
  camera_ = nullptr;
}

winrt::fire_and_forget CameraCapture::Stop(bool shutdown) {
  const auto lifetime = shared_from_this();
  ++generation_;
  shutdown_ = shutdown_ || shutdown;
  { std::lock_guard lock(frame_mutex_); frame_generation_ = generation_; }
  // The current initialization/encode owns teardown until its await completes.
  if (busy_) co_return;
  busy_ = true;
  co_await CloseAsync();
  busy_ = false;
}
