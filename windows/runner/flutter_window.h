#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/encodable_value.h>

#include <memory>
#include <shellapi.h>

#include "win32_window.h"
#include "camera_capture.h"
#include "routing_applications.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
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
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> platform_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> desktop_channel_;
  NOTIFYICONDATAW tray_{};
  bool tray_added_ = false, can_connect_ = false, can_disconnect_ = false;
  bool headless_ = false;
  // Open file dialogs; Quit waits, or the nested loop destroys their owner.
  int modal_ = 0;
  void AddTray();
  void TrayMenu();
  std::shared_ptr<CameraCapture> camera_;
  std::shared_ptr<RoutingApplicationLookup> routing_applications_;
  std::vector<std::string> pending_links_;
};

// Portable installs have no uninstaller: `elarni.exe --unregister` removes the
// link handlers and launch-at-login entry this app wrote under HKCU.
bool UnregisterProfileLinks();

#endif  // RUNNER_FLUTTER_WINDOW_H_
