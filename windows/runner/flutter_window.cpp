#include <winsock2.h>
#include <ws2tcpip.h>
#include <iphlpapi.h>
#include "flutter_window.h"

#include <map>
#include <optional>
#include <flutter/standard_method_codec.h>
#include <shobjidl.h>
#include <shellapi.h>
#include <wrl/client.h>
#include <chrono>
#include <set>
#include <sstream>
#include <stdexcept>
#include "utils.h"
#include "resource.h"

#include "flutter/generated_plugin_registrant.h"

namespace {
const UINT kTaskbarCreated = RegisterWindowMessageW(L"TaskbarCreated");
constexpr UINT kTrayMessage = WM_APP + 17;
// The tray line names the tunnel state Dart sends as a code.
std::wstring TrayState(const std::string& state) {
  static const std::map<std::string, const wchar_t*> russian = {
      {"disconnected", L"отключено"}, {"preparing", L"подготовка"}, {"prepared", L"подготовлено"},
      {"connecting", L"подключение"}, {"connected", L"подключено"}, {"disconnecting", L"отключение"},
      {"reasserting", L"восстановление связи"}, {"reconnecting", L"переподключение"},
      {"invalid", L"требуется настройка"}, {"failed", L"ошибка подключения"},
      {"connected, no traffic", L"подключено, нет трафика"}};
  const auto found = russian.find(state);
  return RussianInterface() && found != russian.end() ? std::wstring(found->second) : std::wstring(winrt::to_hstring(state));
}
std::wstring AppPath() {
  std::wstring path(32768, L'\0');
  const DWORD size = GetModuleFileNameW(nullptr, path.data(), static_cast<DWORD>(path.size()));
  if (size == 0 || size >= path.size()) return {};
  path.resize(size);
  return path;
}

bool RegistryText(const std::wstring& path, const wchar_t* name, const std::wstring& value) {
  HKEY key = nullptr;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, path.c_str(), 0, nullptr, 0, KEY_SET_VALUE, nullptr, &key, nullptr) != ERROR_SUCCESS) return false;
  const auto status = RegSetValueExW(key, name, 0, REG_SZ, reinterpret_cast<const BYTE*>(value.c_str()),
      static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t)));
  RegCloseKey(key);
  return status == ERROR_SUCCESS;
}

constexpr const wchar_t* kSchemes[] = {L"elarni", L"happ", L"incy", L"vless", L"vmess", L"trojan", L"ss", L"socks", L"socks5", L"hy2", L"hysteria2", L"tuic", L"vpn", L"wireguard"};

// A scheme stays Elarni's only while it keeps the marker and still opens
// elarni.exe: an app that rewrote the command kept the marker but owns the scheme.
bool OwnsScheme(HKEY root, const std::wstring& path) {
  wchar_t owner[64]{};
  DWORD size = sizeof(owner);
  if (RegGetValueW(root, path.c_str(), L"ElarniOwner", RRF_RT_REG_SZ, nullptr, owner, &size) != ERROR_SUCCESS ||
      std::wstring(owner) != L"com.elarni.windows") return false;
  std::wstring command(32768, L'\0');
  size = static_cast<DWORD>(command.size() * sizeof(wchar_t));
  if (RegGetValueW(root, (path + L"\\shell\\open\\command").c_str(), nullptr, RRF_RT_REG_SZ, nullptr, command.data(), &size) != ERROR_SUCCESS)
    return false;
  // Elarni writes "<folder>\elarni.exe" "%1"; the folder changes when the app moves.
  const auto end = command.find(L'"', 1);
  if (command[0] != L'"' || end == std::wstring::npos) return false;
  const auto program = command.substr(1, end - 1);
  const auto name = program.substr(program.find_last_of(L"\\/") + 1);
  return CompareStringOrdinal(name.c_str(), -1, L"elarni.exe", -1, TRUE) == CSTR_EQUAL;
}

void RegisterProfileLinks() {
  const auto path = AppPath();
  if (path.empty()) return;
  const auto command = L"\"" + path + L"\" \"%1\"";
  const std::wstring capabilities = L"Software\\Elarni\\Capabilities";
  RegistryText(capabilities, L"ApplicationName", L"Elarni");
  RegistryText(capabilities, L"ApplicationDescription", L"Import proxy profiles and routing links");
  RegistryText(L"Software\\RegisteredApplications", L"Elarni", capabilities);
  for (const auto* scheme : kSchemes) {
    const auto program = std::wstring(L"Elarni.") + scheme;
    const auto own = L"Software\\Classes\\" + program;
    RegistryText(own, nullptr, L"Elarni profile link");
    RegistryText(own, L"URL Protocol", L"");
    RegistryText(own + L"\\shell\\open\\command", nullptr, command);
    RegistryText(capabilities + L"\\URLAssociations", scheme, program);
    HKEY existing = nullptr;
    const auto status = RegOpenKeyExW(HKEY_CLASSES_ROOT, scheme, 0, KEY_READ, &existing);
    if (status == ERROR_SUCCESS) RegCloseKey(existing);
    // Refresh our own handler after a move/update, preserving other defaults.
    if (status != ERROR_FILE_NOT_FOUND && !OwnsScheme(HKEY_CLASSES_ROOT, scheme)) continue;
    const auto direct = std::wstring(L"Software\\Classes\\") + scheme;
    RegistryText(direct, nullptr, L"URL:Elarni profile");
    RegistryText(direct, L"URL Protocol", L"");
    RegistryText(direct, L"ElarniOwner", L"com.elarni.windows");
    RegistryText(direct + L"\\shell\\open\\command", nullptr, command);
  }
}

flutter::EncodableMap SystemInfo() {
  using flutter::EncodableValue;
  SYSTEM_INFO info{};
  GetNativeSystemInfo(&info);
  MEMORYSTATUSEX memory{};
  memory.dwLength = sizeof(memory);
  GlobalMemoryStatusEx(&memory);
  wchar_t login[32768]{};
  DWORD bytes = sizeof(login);
  const auto status = RegGetValueW(HKEY_CURRENT_USER,
      L"Software\\Microsoft\\Windows\\CurrentVersion\\Run", L"Elarni",
      RRF_RT_REG_SZ, nullptr, login, &bytes);
  const bool enabled = status == ERROR_SUCCESS && IsLaunchCommand(login, AppPath());
  return {{EncodableValue("os"), EncodableValue("Windows")},
      {EncodableValue("architecture"), EncodableValue("x86_64")},
      {EncodableValue("processorCount"), EncodableValue(static_cast<int32_t>(info.dwNumberOfProcessors))},
      {EncodableValue("activeProcessorCount"), EncodableValue(static_cast<int32_t>(GetActiveProcessorCount(ALL_PROCESSOR_GROUPS)))},
      {EncodableValue("physicalMemoryBytes"), EncodableValue(static_cast<int64_t>(memory.ullTotalPhys))},
      {EncodableValue("launchAtLoginStatus"), EncodableValue(enabled ? "enabled" : "notRegistered")}};
}


}

bool UnregisterProfileLinks() {
  bool removed = true;
  const auto check = [&removed](LSTATUS status) {
    removed &= status == ERROR_SUCCESS || status == ERROR_FILE_NOT_FOUND;
  };
  check(RegDeleteKeyValueW(HKEY_CURRENT_USER, L"Software\\RegisteredApplications", L"Elarni"));
  check(RegDeleteKeyValueW(HKEY_CURRENT_USER, L"Software\\Microsoft\\Windows\\CurrentVersion\\Run", L"Elarni"));
  // Software\Elarni also holds preferences, which an uninstall preserves.
  check(RegDeleteTreeW(HKEY_CURRENT_USER, L"Software\\Elarni\\Capabilities"));
  for (const auto* scheme : kSchemes) {
    check(RegDeleteTreeW(HKEY_CURRENT_USER, (std::wstring(L"Software\\Classes\\Elarni.") + scheme).c_str()));
    // Remove only scheme handlers Elarni claimed; another app's default stays.
    const auto direct = std::wstring(L"Software\\Classes\\") + scheme;
    if (OwnsScheme(HKEY_CURRENT_USER, direct)) check(RegDeleteTreeW(HKEY_CURRENT_USER, direct.c_str()));
  }
  return removed;
}

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }
  camera_ = std::make_shared<CameraCapture>();
  routing_applications_ = std::make_shared<RoutingApplicationLookup>();
  wchar_t headless[2]{};
  headless_ = GetEnvironmentVariableW(L"ELARNI_HEADLESS", headless, 2) == 1 && headless[0] == L'1';
  if (headless_) SetPropW(GetHandle(), L"ElarniHeadless", GetHandle());

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  RegisterProfileLinks();
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  desktop_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "com.elarni/desktop",
      &flutter::StandardMethodCodec::GetInstance());
  desktop_channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    using flutter::EncodableMap;
    using flutter::EncodableValue;
    try {
      if (call.method_name() == "routingApplications") {
        const auto* arguments = call.arguments() ? std::get_if<EncodableMap>(call.arguments()) : nullptr;
        const auto* selected = arguments && arguments->contains(EncodableValue("processes"))
            ? std::get_if<flutter::EncodableList>(&arguments->at(EncodableValue("processes"))) : nullptr;
        routing_applications_->Load(selected && selected->size() <= 256 ? *selected : flutter::EncodableList{},
            std::move(result));
        return;
      }
      if (call.method_name() == "pickRoutingApplications") {
        Microsoft::WRL::ComPtr<IFileOpenDialog> dialog;
        auto status = CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dialog));
        if (SUCCEEDED(status)) status = dialog->SetOptions(FOS_FORCEFILESYSTEM | FOS_FILEMUSTEXIST | FOS_PATHMUSTEXIST | FOS_ALLOWMULTISELECT);
        const COMDLG_FILTERSPEC type = {Localized(L"Applications", L"Приложения"), L"*.exe"};
        if (SUCCEEDED(status)) status = dialog->SetFileTypes(1, &type);
        if (SUCCEEDED(status)) status = dialog->SetTitle(Localized(L"Choose application executables", L"Выберите исполняемые файлы приложений"));
        if (SUCCEEDED(status)) { ++modal_; status = dialog->Show(GetHandle()); --modal_; }
        flutter::EncodableList apps;
        if (status == HRESULT_FROM_WIN32(ERROR_CANCELLED)) { result->Success(EncodableValue(apps)); return; }
        Microsoft::WRL::ComPtr<IShellItemArray> items;
        if (SUCCEEDED(status)) status = dialog->GetResults(&items);
        DWORD count = 0;
        if (SUCCEEDED(status)) status = items->GetCount(&count);
        if (FAILED(status) || count > 256) { result->Error("picker_failed", "Select up to 256 executable files."); return; }
        for (DWORD index = 0; index < count; ++index) {
          Microsoft::WRL::ComPtr<IShellItem> item;
          status = items->GetItemAt(index, &item);
          PWSTR path = nullptr;
          if (SUCCEEDED(status)) status = item->GetDisplayName(SIGDN_FILESYSPATH, &path);
          if (FAILED(status)) { result->Error("picker_failed", "The executable path is unavailable."); return; }
          const std::wstring value(path);
          CoTaskMemFree(path);
          if (value.size() < 4 || _wcsicmp(value.c_str() + value.size() - 4, L".exe") != 0 || Utf8FromUtf16(value.c_str()).size() > 1024) {
            result->Error("invalid_applications", "Select executable files with paths of at most 1024 bytes."); return;
          }
          apps.emplace_back(RoutingApplication(value, false, ExecutableRule(value)));
        }
        result->Success(EncodableValue(apps)); return;
      }
      if (call.method_name() == "getPreferences") {
        wchar_t json[32769]{};
        DWORD bytes = sizeof(json);
        const auto status = RegGetValueW(HKEY_CURRENT_USER, L"Software\\Elarni", L"DesktopPreferencesV1",
            RRF_RT_REG_SZ, nullptr, json, &bytes);
        if (status == ERROR_FILE_NOT_FOUND) { result->Success(EncodableValue("{}")); return; }
        if (status != ERROR_SUCCESS) { result->Error("preferences_failed", "Desktop preferences could not be read."); return; }
        result->Success(EncodableValue(winrt::to_string(json))); return;
      }
      if (call.method_name() == "requestNotifications") { result->Success(EncodableValue(true)); return; }
      const auto* args = call.arguments() ? std::get_if<EncodableMap>(call.arguments()) : nullptr;
      if (!args) { result->Error("invalid_request", "Invalid desktop operation."); return; }
      if (call.method_name() == "setPreferences") {
        const auto entry = args->find(EncodableValue("json"));
        const auto* json = entry == args->end() ? nullptr : std::get_if<std::string>(&entry->second);
        if (!json || json->size() > 32768 || !RegistryText(L"Software\\Elarni", L"DesktopPreferencesV1", std::wstring(winrt::to_hstring(*json)))) {
          result->Error("preferences_failed", "Desktop preferences could not be saved."); return;
        }
        result->Success(); return;
      }
      if (call.method_name() == "showExpiryReminder") {
        const auto entry = args->find(EncodableValue("count"));
        const auto* count = entry == args->end() ? nullptr : std::get_if<int32_t>(&entry->second);
        if (!count || *count < 1 || *count > 1024) { result->Error("invalid_request", "Invalid reminder."); return; }
        if (!tray_added_) AddTray();
        auto notification = tray_;
        notification.uFlags = NIF_INFO;
        notification.dwInfoFlags = NIIF_INFO;
        wcscpy_s(notification.szInfoTitle, Localized(L"Subscription expires soon", L"Подписка скоро закончится"));
        const wchar_t* russian[] = {L" подписка заканчивается в ближайшие три дня. Откройте Elarni, чтобы узнать подробности.",
            L" подписки заканчиваются в ближайшие три дня. Откройте Elarni, чтобы узнать подробности.",
            L" подписок заканчиваются в ближайшие три дня. Откройте Elarni, чтобы узнать подробности."};
        const auto body = std::to_wstring(*count) +
            Localized(L" subscription(s) expire within three days. Open Elarni for details.", russian[RussianPluralForm(*count)]);
        wcsncpy_s(notification.szInfo, body.c_str(), _TRUNCATE);
        if (!Shell_NotifyIconW(NIM_MODIFY, &notification)) { result->Error("notifications_failed", "Notification unavailable."); return; }
        result->Success(); return;
      }
      if (call.method_name() == "setStatus") {
        const auto entry = args->find(EncodableValue("state"));
        const auto* state = entry == args->end() ? nullptr : std::get_if<std::string>(&entry->second);
        if (!state || state->size() > 32 || state->find_first_not_of("abcdefghijklmnopqrstuvwxyz, ") != std::string::npos) {
          result->Error("invalid_request", "Invalid desktop status."); return;
        }
        auto flag = [&](const char* key) {
          const auto item = args->find(EncodableValue(key));
          const auto* value = item == args->end() ? nullptr : std::get_if<bool>(&item->second);
          return value && *value;
        };
        can_connect_ = flag("canConnect"); can_disconnect_ = flag("canDisconnect");
        const auto language = args->find(EncodableValue("language"));
        if (const auto* code = language == args->end() ? nullptr : std::get_if<std::string>(&language->second)) {
          SetRussianInterface(*code == "ru");
        }
        const auto label = L"Elarni - " + TrayState(*state);
        wcsncpy_s(tray_.szTip, label.c_str(), _TRUNCATE);
        if (!tray_added_) AddTray();
        else Shell_NotifyIconW(NIM_MODIFY, &tray_);
        result->Success(); return;
      }
      result->NotImplemented();
    } catch (...) { result->Error("desktop_failed", "The desktop operation failed."); }
  });
  tray_.cbSize = sizeof(tray_); tray_.hWnd = GetHandle(); tray_.uID = 1;
  tray_.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP;
  tray_.uCallbackMessage = kTrayMessage;
  tray_.hIcon = LoadIconW(GetModuleHandleW(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON));
  wcscpy_s(tray_.szTip, L"Elarni");
  AddTray();

  platform_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "com.elarni/windows",
      &flutter::StandardMethodCodec::GetInstance());
  platform_channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    using flutter::EncodableMap;
    using flutter::EncodableValue;
    const auto* args = call.arguments() ? std::get_if<EncodableMap>(call.arguments()) : nullptr;
    if (!args) { result->Error("invalid_request", "Invalid Windows operation."); return; }
    if (call.method_name() == "takeLinks") {
      flutter::EncodableList links;
      for (const auto& link : pending_links_) links.emplace_back(link);
      pending_links_.clear();
      result->Success(EncodableValue(EncodableMap{{EncodableValue("links"), EncodableValue(links)}})); return;
    }
    if (call.method_name() == "cameraFrame") {
      camera_->Frame(std::move(result)); return;
    }
    if (call.method_name() == "cameraStop") {
      camera_->Stop(); result->Success(); return;
    }
    if (call.method_name() == "saveEvidence" || call.method_name() == "saveBackup" || call.method_name() == "saveLogs" || call.method_name() == "pickRecordingPath") {
      const bool backup = call.method_name() == "saveBackup";
      const bool logs = call.method_name() == "saveLogs";
      // The recording ZIP can be large, so Dart copies it to the chosen path.
      const bool recording = call.method_name() == "pickRecordingPath";
      const auto error = backup ? "backup_failed" : recording ? "recording_failed" : "diagnostics_failed";
      const auto entry = args->find(EncodableValue("content"));
      const auto* content = entry == args->end() ? nullptr : std::get_if<std::string>(&entry->second);
      if (!recording && (!content || content->empty() || content->size() > (backup ? 12 * 1024 * 1024 : logs ? 4 * 1024 * 1024 : 512 * 1024))) { result->Error(error, "Invalid export."); return; }
      Microsoft::WRL::ComPtr<IFileSaveDialog> dialog;
      auto status = CoCreateInstance(CLSID_FileSaveDialog, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dialog));
      if (SUCCEEDED(status)) status = dialog->SetOptions(FOS_FORCEFILESYSTEM | FOS_OVERWRITEPROMPT | FOS_PATHMUSTEXIST);
      if (SUCCEEDED(status)) status = dialog->SetFileName(backup ? L"Elarni-backup.json" : logs ? L"Elarni-log.txt" : recording ? L"Elarni-recording.zip" : L"Elarni-diagnostics.json");
      if (SUCCEEDED(status)) status = dialog->SetDefaultExtension(logs ? L"txt" : recording ? L"zip" : L"json");
      if (SUCCEEDED(status)) { ++modal_; status = dialog->Show(GetHandle()); --modal_; }
      if (status == HRESULT_FROM_WIN32(ERROR_CANCELLED)) { result->Error("cancelled", "Export was cancelled."); return; }
      Microsoft::WRL::ComPtr<IShellItem> item;
      if (SUCCEEDED(status)) status = dialog->GetResult(&item);
      PWSTR path = nullptr;
      if (SUCCEEDED(status)) status = item->GetDisplayName(SIGDN_FILESYSPATH, &path);
      if (FAILED(status)) { result->Error(error, "The export path is unavailable."); return; }
      const std::wstring target(path);
      CoTaskMemFree(path);
      if (recording) { result->Success(EncodableValue(EncodableMap{{EncodableValue("path"), EncodableValue(Utf8FromUtf16(target.c_str()))}})); return; }
      if (!SaveReplacing(target, *content)) { result->Error(error, "The file could not be saved."); return; }
      result->Success(EncodableValue(EncodableMap{})); return;
    }
    if (call.method_name() == "systemInfo" || call.method_name() == "setLaunchAtLogin") {
      if (call.method_name() == "setLaunchAtLogin") {
        const auto entry = args->find(EncodableValue("enabled"));
        const auto* enabled = entry == args->end() ? nullptr : std::get_if<bool>(&entry->second);
        if (!enabled || AppPath().empty()) { result->Error("invalid_settings", "Invalid login setting."); return; }
        HKEY key = nullptr;
        auto status = RegCreateKeyExW(HKEY_CURRENT_USER,
            L"Software\\Microsoft\\Windows\\CurrentVersion\\Run", 0, nullptr, 0,
            KEY_SET_VALUE, nullptr, &key, nullptr);
        if (status == ERROR_SUCCESS) {
          const std::wstring command = L"\"" + AppPath() + L"\"";
          status = *enabled ? RegSetValueExW(key, L"Elarni", 0, REG_SZ,
              reinterpret_cast<const BYTE*>(command.c_str()), static_cast<DWORD>((command.size() + 1) * sizeof(wchar_t)))
              : RegDeleteValueW(key, L"Elarni");
          RegCloseKey(key);
          if (!*enabled && status == ERROR_FILE_NOT_FOUND) status = ERROR_SUCCESS;
        }
        if (status != ERROR_SUCCESS) { result->Error("login_registration_failed", "Windows could not update launch at login."); return; }
      }
      result->Success(EncodableValue(SystemInfo())); return;
    }
    if (call.method_name() == "routeTable") {
      MIB_IPFORWARD_TABLE2* table = nullptr;
      if (GetIpForwardTable2(AF_UNSPEC, &table) != NO_ERROR) {
        result->Error("diagnostics_failed", "Windows routes are unavailable."); return;
      }
      std::ostringstream text;
      text << "Destination\tGateway\tInterface\tMetric\n";
      const auto addressText = [](const SOCKADDR_INET& address) {
        char value[INET6_ADDRSTRLEN]{};
        const void* bytes = address.si_family == AF_INET
            ? static_cast<const void*>(&address.Ipv4.sin_addr)
            : static_cast<const void*>(&address.Ipv6.sin6_addr);
        InetNtopA(address.si_family, bytes, value, sizeof(value));
        return std::string(value);
      };
      for (ULONG i = 0; i < table->NumEntries && text.tellp() <= 512 * 1024; ++i) {
        const auto& row = table->Table[i];
        text << addressText(row.DestinationPrefix.Prefix) << '/' << static_cast<unsigned>(row.DestinationPrefix.PrefixLength)
            << '\t' << addressText(row.NextHop) << '\t' << row.InterfaceIndex << '\t' << row.Metric << '\n';
      }
      FreeMibTable(table);
      if (text.tellp() > 512 * 1024) { result->Error("diagnostics_failed", "Windows route table exceeds the display limit."); return; }
      const auto timestamp = std::chrono::duration<double>(std::chrono::system_clock::now().time_since_epoch()).count();
      result->Success(EncodableValue(EncodableMap{{EncodableValue("table"), EncodableValue(text.str())},
          {EncodableValue("timestamp"), EncodableValue(timestamp)}})); return;
    }
    if (call.method_name() == "pickFile") {
      const auto entry = args->find(EncodableValue("image"));
      const bool image = entry != args->end() && std::get_if<bool>(&entry->second) && std::get<bool>(entry->second);
      const auto backup_entry = args->find(EncodableValue("backup"));
      const bool backup = backup_entry != args->end() && std::get_if<bool>(&backup_entry->second) && std::get<bool>(backup_entry->second);
      Microsoft::WRL::ComPtr<IFileOpenDialog> dialog;
      HRESULT status = CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dialog));
      if (SUCCEEDED(status)) status = dialog->SetOptions(FOS_FORCEFILESYSTEM | FOS_FILEMUSTEXIST | FOS_PATHMUSTEXIST);
      const COMDLG_FILTERSPEC types[] = {{image ? Localized(L"QR images", L"Изображения QR")
          : backup ? Localized(L"Elarni backups", L"Резервные копии Elarni") : Localized(L"Profile files", L"Файлы профилей"),
          image ? L"*.png;*.jpg;*.jpeg;*.gif" : backup ? L"*.json" : L"*.json;*.yaml;*.yml;*.txt;*.conf"},
          {Localized(L"All files", L"Все файлы"), L"*.*"}};
      if (SUCCEEDED(status)) status = dialog->SetFileTypes(2, types);
      if (SUCCEEDED(status)) { ++modal_; status = dialog->Show(GetHandle()); --modal_; }
      if (status == HRESULT_FROM_WIN32(ERROR_CANCELLED)) { result->Success(EncodableValue(EncodableMap{})); return; }
      Microsoft::WRL::ComPtr<IShellItem> item;
      if (SUCCEEDED(status)) status = dialog->GetResult(&item);
      PWSTR path = nullptr;
      if (SUCCEEDED(status)) status = item->GetDisplayName(SIGDN_FILESYSPATH, &path);
      if (FAILED(status)) { result->Error("picker_failed", "The file could not be selected."); return; }
      const auto utf8 = Utf8FromUtf16(path);
      CoTaskMemFree(path);
      result->Success(EncodableValue(EncodableMap{{EncodableValue("path"), EncodableValue(utf8)}}));
      return;
    }
    if (call.method_name() == "openURL") {
      const auto entry = args->find(EncodableValue("url"));
      const auto* url = entry == args->end() ? nullptr : std::get_if<std::string>(&entry->second);
      if (!url || url->size() > 16384 || (url->rfind("https://", 0) != 0 && url->rfind("http://", 0) != 0 && url->rfind("tg://proxy?", 0) != 0) ||
          url->find_first_of("\r\n\t\0", 0, 4) != std::string::npos) {
        result->Error("invalid_url", "Invalid provider link."); return;
      }
      const int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, url->c_str(), -1, nullptr, 0);
      if (count == 0) { result->Error("invalid_url", "Invalid provider link."); return; }
      std::wstring wide(static_cast<size_t>(count), L'\0');
      MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, url->c_str(), -1, wide.data(), count);
      if (reinterpret_cast<INT_PTR>(ShellExecuteW(GetHandle(), L"open", wide.c_str(), nullptr, nullptr, SW_SHOWNORMAL)) <= 32) {
        result->Error("open_failed", "The provider link could not be opened."); return;
      }
      result->Success(EncodableValue(EncodableMap{})); return;
    }
    result->NotImplemented();
  });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    if (!headless_) this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (routing_applications_) routing_applications_->Stop();
  if (camera_) camera_->Stop(true);
  if (tray_added_) Shell_NotifyIconW(NIM_DELETE, &tray_);
  tray_added_ = false;
  desktop_channel_ = nullptr;
  platform_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == kTaskbarCreated && desktop_channel_) { tray_added_ = false; AddTray(); return 0; }
  if (message == kTrayMessage) {
    const auto event = LOWORD(lparam);
    if (event == WM_CONTEXTMENU || event == NIN_SELECT || event == NIN_KEYSELECT) TrayMenu();
    return 0;
  }
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_POWERBROADCAST:
      if (platform_channel_ && (wparam == PBT_APMSUSPEND || wparam == PBT_APMRESUMEAUTOMATIC || wparam == PBT_APMRESUMESUSPEND)) {
        platform_channel_->InvokeMethod("sleepChanged", std::make_unique<flutter::EncodableValue>(wparam == PBT_APMSUSPEND));
      }
      return TRUE;
    case WM_COPYDATA: {
      const auto* data = reinterpret_cast<const COPYDATASTRUCT*>(lparam);
      if (!data || data->dwData != 0x52564c31 || !data->lpData || data->cbData < 2 || data->cbData > 4 * 1024 * 1024 || pending_links_.size() >= 16) return FALSE;
      const auto* text = static_cast<const char*>(data->lpData);
      if (text[data->cbData - 1] != '\0' || memchr(text, '\0', data->cbData - 1)) return FALSE;
      pending_links_.emplace_back(text, data->cbData - 1);
      if (platform_channel_) platform_channel_->InvokeMethod("linksAvailable", nullptr);
      ShowWindow(hwnd, SW_RESTORE);
      SetForegroundWindow(hwnd);
      return TRUE;
    }
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

void FlutterWindow::AddTray() {
  if (headless_) return;
  tray_added_ = Shell_NotifyIconW(NIM_ADD, &tray_) != FALSE;
  if (tray_added_) { tray_.uVersion = NOTIFYICON_VERSION_4; Shell_NotifyIconW(NIM_SETVERSION, &tray_); }
}

void FlutterWindow::TrayMenu() {
  const auto menu = CreatePopupMenu();
  if (!menu) return;
  AppendMenuW(menu, MF_STRING | MF_GRAYED, 0, tray_.szTip);
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, 1, Localized(L"Show Elarni", L"Показать Elarni"));
  AppendMenuW(menu, MF_STRING | (can_connect_ ? MF_ENABLED : MF_GRAYED), 2, Localized(L"Connect", L"Подключить"));
  AppendMenuW(menu, MF_STRING | (can_disconnect_ ? MF_ENABLED : MF_GRAYED), 3, Localized(L"Disconnect", L"Отключить"));
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING | (modal_ ? MF_GRAYED : MF_ENABLED), 4, Localized(L"Quit Elarni", L"Выйти из Elarni"));
  POINT point{}; GetCursorPos(&point); SetForegroundWindow(GetHandle());
  const auto action = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON, point.x, point.y, 0, GetHandle(), nullptr);
  DestroyMenu(menu); PostMessageW(GetHandle(), WM_NULL, 0, 0);
  if (action == 1) { ShowWindow(GetHandle(), SW_RESTORE); SetForegroundWindow(GetHandle()); }
  if ((action == 2 || action == 3) && desktop_channel_) {
    desktop_channel_->InvokeMethod("action", std::make_unique<flutter::EncodableValue>(action == 2 ? "connect" : "disconnect"));
  }
  if (action == 4) PostMessageW(GetHandle(), WM_CLOSE, 0, 0);
}
