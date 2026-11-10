#ifndef RUNNER_ROUTING_APPLICATIONS_H_
#define RUNNER_ROUTING_APPLICATIONS_H_

#include <flutter/encodable_value.h>
#include <flutter/method_result.h>
#include <memory>
#include <set>
#include <string>
#include <vector>
#include <winrt/base.h>

// Imported match strings get names without accessing their filesystem targets.
// `rule` replaces `path` as the match string; the icon still comes from `path`.
flutter::EncodableMap RoutingApplication(const std::wstring& path, bool running = false,
    const std::wstring& rule = {});
// The match string for a running or chosen local executable. Squirrel apps such as
// Discord run from <root>\app-<version>\, which each update replaces, and start
// through <root>\Update.exe or a stub, so they match their whole <root>\ folder.
std::wstring ExecutableRule(const std::wstring& path);
// For a saved rule that names one version of a local app, the rule that matches every
// version; otherwise empty. Store paths need none: the core matches them by package.
std::wstring UpdateProofRule(const std::wstring& path);
// Running programs by their rules; svchost processes also by the services they run
// ("service:<name>", named by the service's display name).
flutter::EncodableList RunningApplications();
// Apps the shortcuts in folders (searched four levels deep) start, by their executables' rules
// and the shortcuts' names, leaving out uninstallers, setups and rules in seen, which it extends.
flutter::EncodableList ShortcutApplications(const std::vector<std::wstring>& folders, std::set<std::wstring>& seen);
// The Start menu's apps: the shortcuts of this user and of all users.
flutter::EncodableList StartMenuApplications(std::set<std::wstring>& seen);
// Installed Microsoft Store apps by their package family rules (WindowsApps\<name>_<publisher>\).
flutter::EncodableList PackagedApplications(std::set<std::wstring>& seen);

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
