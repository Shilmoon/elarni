#ifndef RUNNER_ROUTING_APPLICATIONS_H_
#define RUNNER_ROUTING_APPLICATIONS_H_

#include <flutter/encodable_value.h>
#include <flutter/method_result.h>
#include <memory>
#include <string>
#include <winrt/base.h>

// Imported match strings get names without accessing their filesystem targets.
// `rule` replaces `path` as the match string; the icon still comes from `path`.
flutter::EncodableMap RoutingApplication(const std::wstring& path, bool running = false,
    const std::wstring& rule = {});
// The match string for a running or chosen local executable. Squirrel apps such as
// Discord run from <root>\app-<version>\, which each update replaces, and start
// through <root>\Update.exe or a stub, so they match their whole <root>\ folder.
std::wstring ExecutableRule(const std::wstring& path);

class RoutingApplicationLookup : public std::enable_shared_from_this<RoutingApplicationLookup> {
 public:
  winrt::fire_and_forget Load(flutter::EncodableList selected,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void Stop() { shutdown_ = true; }
 private:
  // Accessed only on the originating window apartment.
  bool shutdown_ = false;
  bool busy_ = false;
};
#endif
