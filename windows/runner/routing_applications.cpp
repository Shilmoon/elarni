#include "routing_applications.h"
#include <windows.h>
#include <shellapi.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <tlhelp32.h>
#include <wrl/client.h>
#include <wincodec.h>
#include <winrt/Windows.ApplicationModel.h>
#include <winrt/Windows.ApplicationModel.Core.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Management.Deployment.h>
#include <winrt/Windows.Storage.h>
#include <winrt/Windows.Storage.Streams.h>
#include <algorithm>
#include <map>
#include <set>
#include <stdexcept>
#include <vector>

namespace {
std::string RoutingUTF8(const wchar_t* text) {
  return winrt::to_string(std::wstring_view(text));
}

bool LocalApplicationPath(const std::wstring& path) {
  if (path.size() < 3 || !((path[0] >= L'A' && path[0] <= L'Z') ||
      (path[0] >= L'a' && path[0] <= L'z')) || path[1] != L':' ||
      (path[2] != L'\\' && path[2] != L'/')) return false;
  const wchar_t root[] = {path[0], L':', L'\\', L'\0'};
  return GetDriveTypeW(root) == DRIVE_FIXED;
}
}

std::vector<uint8_t> ApplicationIcon(const std::wstring& path) {
  using Microsoft::WRL::ComPtr;
  SHFILEINFOW info{};
  if (!SHGetFileInfoW(path.c_str(), 0, &info, sizeof(info), SHGFI_ICON | SHGFI_LARGEICON)) return {};
  ComPtr<IWICImagingFactory> factory;
  ComPtr<IWICBitmap> bitmap;
  const HRESULT created = CoCreateInstance(CLSID_WICImagingFactory, nullptr,
      CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory));
  const HRESULT converted = SUCCEEDED(created) ? factory->CreateBitmapFromHICON(info.hIcon, &bitmap) : created;
  DestroyIcon(info.hIcon);
  if (FAILED(converted)) return {};
  ComPtr<IStream> stream;
  ComPtr<IWICBitmapEncoder> encoder;
  ComPtr<IWICBitmapFrameEncode> frame;
  UINT width = 0, height = 0;
  WICPixelFormatGUID format = GUID_WICPixelFormat32bppBGRA;
  if (FAILED(CreateStreamOnHGlobal(nullptr, TRUE, &stream)) ||
      FAILED(factory->CreateEncoder(GUID_ContainerFormatPng, nullptr, &encoder)) ||
      FAILED(encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache)) ||
      FAILED(encoder->CreateNewFrame(&frame, nullptr)) ||
      FAILED(frame->Initialize(nullptr)) || FAILED(bitmap->GetSize(&width, &height)) ||
      width == 0 || height == 0 || width > 256 || height > 256 ||
      FAILED(frame->SetSize(width, height)) || FAILED(frame->SetPixelFormat(&format)) ||
      FAILED(frame->WriteSource(bitmap.Get(), nullptr)) || FAILED(frame->Commit()) ||
      FAILED(encoder->Commit())) return {};
  STATSTG stat{};
  HGLOBAL memory = nullptr;
  if (FAILED(stream->Stat(&stat, STATFLAG_NONAME)) || stat.cbSize.QuadPart == 0 ||
      stat.cbSize.QuadPart > 65536 || FAILED(GetHGlobalFromStream(stream.Get(), &memory))) return {};
  const auto* data = static_cast<const uint8_t*>(GlobalLock(memory));
  if (!data) return {};
  std::vector<uint8_t> png(data, data + static_cast<size_t>(stat.cbSize.QuadPart));
  GlobalUnlock(memory);
  return png;
}

namespace {
bool OnlyOf(const std::wstring& text, const wchar_t* allowed) {
  return !text.empty() && text.find_first_not_of(allowed) == std::wstring::npos;
}

std::vector<std::wstring> Split(const std::wstring& text, wchar_t separator) {
  std::vector<std::wstring> parts;
  for (size_t start = 0;;) {
    const auto end = text.find(separator, start);
    parts.push_back(text.substr(start, end == std::wstring::npos ? std::wstring::npos : end - start));
    if (end == std::wstring::npos) return parts;
    start = end + 1;
  }
}

constexpr wchar_t kAlphanumeric[] = L"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
constexpr wchar_t kPackageName[] = L"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-";

// The bounds of the folder directly below a WindowsApps folder in path.
bool PackageFolder(const std::wstring& path, size_t& start, size_t& end) {
  std::wstring lower = path;
  CharLowerBuffW(lower.data(), static_cast<DWORD>(lower.size()));
  constexpr wchar_t parent[] = L"\\windowsapps\\";
  const auto found = lower.find(parent);
  if (found == std::wstring::npos) return false;
  start = found + std::size(parent) - 1;
  end = path.find(L'\\', start);
  return end != std::wstring::npos && end > start;
}

// Microsoft Store apps run from <volume>\WindowsApps\<name>_<version>_<arch>_<resource>_<publisher>\,
// which each update replaces. Vendor/Xray-core/app/router compares that folder, by the same rules, as
// <name>_<publisher>, its package family, so the rule is that family folder.
std::wstring PackageRule(const std::wstring& path) {
  size_t start = 0, end = 0;
  if (!PackageFolder(path, start, end)) return {};
  const auto parts = Split(path.substr(start, end - start), L'_');
  if (parts.size() != 5) return {};
  auto arch = parts[2];
  CharLowerBuffW(arch.data(), static_cast<DWORD>(arch.size()));
  const auto version = Split(parts[1], L'.');
  const wchar_t* arches[] = {L"x86", L"x64", L"arm", L"arm64", L"neutral", L"x86a64"};
  if (!OnlyOf(parts[0], kPackageName) || version.size() != 4 ||
      !std::all_of(version.begin(), version.end(), [](const std::wstring& field) { return OnlyOf(field, L"0123456789"); }) ||
      std::none_of(std::begin(arches), std::end(arches), [&](const wchar_t* known) { return arch == known; }) ||
      parts[4].size() != 13 || !OnlyOf(parts[4], kAlphanumeric)) return {};
  return path.substr(0, start) + parts[0] + L"_" + parts[4] + L"\\";
}

// A family folder rule names its app after the package name without the publisher's prefix:
// 5319275A.WhatsAppDesktop is WhatsAppDesktop.
std::wstring PackageAppName(const std::wstring& rule) {
  size_t start = 0, end = 0;
  if (!PackageFolder(rule, start, end) || end + 1 != rule.size()) return {};
  const auto parts = Split(rule.substr(start, end - start), L'_');
  if (parts.size() != 2 || !OnlyOf(parts[0], kPackageName) || parts[1].size() != 13 ||
      !OnlyOf(parts[1], kAlphanumeric)) return {};
  return parts[0].substr(parts[0].find_last_of(L'.') + 1);
}

// Squirrel apps such as Discord run from <root>\app-<version>\ and start through
// <root>\Update.exe or a stub.
std::wstring SquirrelRule(const std::wstring& path) {
  auto root = path.substr(0, path.find_last_of(L"\\/"));
  const auto parent = root.find_last_of(L"\\/");
  if (parent != std::wstring::npos && _wcsnicmp(root.c_str() + parent + 1, L"app-", 4) == 0) root.resize(parent);
  // A drive root would match every executable on that drive.
  if (root.find_first_of(L"\\/") == std::wstring::npos) return {};
  const auto updater = GetFileAttributesW((root + L"\\Update.exe").c_str());
  if (updater == INVALID_FILE_ATTRIBUTES || (updater & FILE_ATTRIBUTE_DIRECTORY)) return {};
  WIN32_FIND_DATAW found{};
  const HANDLE search = FindFirstFileExW((root + L"\\app-*").c_str(), FindExInfoBasic, &found,
      FindExSearchLimitToDirectories, nullptr, 0);
  if (search == INVALID_HANDLE_VALUE) return {};
  bool versioned = false;
  do versioned = (found.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
  while (!versioned && FindNextFileW(search, &found));
  FindClose(search);
  return versioned ? root + L"\\" : std::wstring{};
}

bool VersionName(const std::wstring& name) {
  return OnlyOf(name, L"0123456789.") && name.find(L'.') != std::wstring::npos && name.front() != L'.' &&
      name.back() != L'.' && name.find(L"..") == std::wstring::npos;
}

// Apps that keep each version in <root>\<version>\ beside the previous one, such as Claude Code
// that the Claude app installs (<root>\<version>\<build>\claude.exe): the nearest version folder
// among the executable's four parents, when everything in <root> is a version.
std::wstring VersionsRule(const std::wstring& path) {
  auto end = path.find_last_of(L"\\/");
  for (int level = 0; level < 4 && end != std::wstring::npos && end > 0; ++level) {
    const auto start = path.find_last_of(L"\\/", end - 1);
    if (start == std::wstring::npos) return {};
    if (!VersionName(path.substr(start + 1, end - start - 1))) { end = start; continue; }
    const auto root = path.substr(0, start);
    // At least two folders below the drive, so a version folder never widens to C:\Tools\.
    if (std::count_if(root.begin(), root.end(), [](wchar_t c) { return c == L'\\' || c == L'/'; }) < 2) return {};
    WIN32_FIND_DATAW found{};
    const HANDLE search = FindFirstFileExW((root + L"\\*").c_str(), FindExInfoBasic, &found,
        FindExSearchNameMatch, nullptr, 0);
    if (search == INVALID_HANDLE_VALUE) return {};
    bool versions = true;
    do {
      const std::wstring name = found.cFileName;
      versions = name.front() == L'.' || VersionName(name);
    } while (versions && FindNextFileW(search, &found));
    FindClose(search);
    return versions ? root + L"\\" : std::wstring{};
  }
  return {};
}
}

std::wstring ExecutableRule(const std::wstring& path) {
  if (!LocalApplicationPath(path)) return path;
  for (const auto rule : {PackageRule, SquirrelRule, VersionsRule}) {
    auto folder = rule(path);
    if (!folder.empty()) return folder;
  }
  return path;
}

std::wstring UpdateProofRule(const std::wstring& path) {
  if (!LocalApplicationPath(path) || !PackageRule(path).empty()) return {};
  const auto rule = ExecutableRule(path);
  return rule == path ? std::wstring{} : rule;
}

flutter::EncodableMap RoutingApplication(const std::wstring& path, bool running, const std::wstring& rule) {
  using flutter::EncodableValue;
  const auto& process = rule.empty() ? path : rule;
  // A folder rule has no file name; Dart names it after the folder, unless it is a Store package.
  auto name = process.substr(process.find_last_of(L"\\/") + 1);
  if (name.empty()) name = PackageAppName(process);
  flutter::EncodableMap app = {{EncodableValue("name"), EncodableValue(RoutingUTF8(name.c_str()))},
      {EncodableValue("process"), EncodableValue(RoutingUTF8(process.c_str()))}};
  auto icon = running && LocalApplicationPath(path) ? ApplicationIcon(path) : std::vector<uint8_t>{};
  if (!icon.empty()) app[EncodableValue("iconPng")] = EncodableValue(std::move(icon));
  return app;
}

namespace {
struct RunningService {
  std::wstring name, display;
};

// The services each process runs. svchost runs most of them, one per process on most PCs; a rule
// for svchost.exe would take every service's connections. Listing needs no administrator.
std::map<DWORD, std::vector<RunningService>> RunningServices() {
  std::map<DWORD, std::vector<RunningService>> services;
  const SC_HANDLE manager = OpenSCManagerW(nullptr, nullptr, SC_MANAGER_ENUMERATE_SERVICE);
  if (!manager) return services;
  std::vector<BYTE> buffer;
  DWORD needed = 0, returned = 0;
  bool listed = false;
  for (int attempt = 0; attempt < 4 && !listed; ++attempt) {
    listed = EnumServicesStatusExW(manager, SC_ENUM_PROCESS_INFO, SERVICE_WIN32, SERVICE_ACTIVE,
        buffer.empty() ? nullptr : buffer.data(), static_cast<DWORD>(buffer.size()), &needed, &returned,
        nullptr, nullptr) != 0;
    if (!listed && GetLastError() != ERROR_MORE_DATA) break;
    if (!listed) buffer.resize(buffer.size() + needed);
  }
  CloseServiceHandle(manager);
  if (!listed || returned == 0) return services;
  const auto* entries = reinterpret_cast<const ENUM_SERVICE_STATUS_PROCESSW*>(buffer.data());
  for (DWORD index = 0; index < returned; ++index) {
    const auto& entry = entries[index];
    if (entry.ServiceStatusProcess.dwProcessId == 0 || !entry.lpServiceName) continue;
    services[entry.ServiceStatusProcess.dwProcessId].push_back(
        {entry.lpServiceName, entry.lpDisplayName && *entry.lpDisplayName ? entry.lpDisplayName : entry.lpServiceName});
  }
  return services;
}

// Vendor/Xray-core/app/router matches "service:<name>" in the process that runs the service.
flutter::EncodableMap ServiceApplication(const RunningService& service) {
  using flutter::EncodableValue;
  return {{EncodableValue("name"), EncodableValue(RoutingUTF8(service.display.c_str()))},
      {EncodableValue("process"), EncodableValue(RoutingUTF8((L"service:" + service.name).c_str()))}};
}
}

flutter::EncodableList RunningApplications() {
  flutter::EncodableList apps;
  const auto services = RunningServices();
  const HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if (snapshot == INVALID_HANDLE_VALUE) throw std::runtime_error("Process list unavailable");
  struct SnapshotOwner {
    HANDLE value;
    ~SnapshotOwner() { CloseHandle(value); }
  } owner{snapshot};
  std::set<std::wstring> seen;
  PROCESSENTRY32W entry{};
  entry.dwSize = sizeof(entry);
  if (Process32FirstW(snapshot, &entry)) do {
    // A service host is listed by the services it runs, also when it cannot be opened.
    const auto hosted = _wcsicmp(entry.szExeFile, L"svchost.exe") == 0 ? services.find(entry.th32ProcessID) : services.end();
    if (hosted != services.end()) {
      for (const auto& service : hosted->second) {
        std::wstring key = L"service:" + service.name;
        CharLowerBuffW(key.data(), static_cast<DWORD>(key.size()));
        if (service.name.size() <= 256 && seen.insert(key).second) apps.emplace_back(ServiceApplication(service));
      }
    }
    const HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, entry.th32ProcessID);
    if (!process) continue;
    wchar_t path[32768]{};
    DWORD size = 32768;
    const bool found = QueryFullProcessImageNameW(process, 0, path, &size) != 0;
    CloseHandle(process);
    if (!found || RoutingUTF8(path).size() > 1024) continue;
    const auto rule = ExecutableRule(path);
    std::wstring key(rule);
    CharLowerBuffW(key.data(), static_cast<DWORD>(key.size()));
    if (seen.insert(key).second) apps.emplace_back(RoutingApplication(path, true, rule));
  } while (Process32NextW(snapshot, &entry));
  return apps;
}

namespace {
std::wstring Lowered(std::wstring text) {
  CharLowerBuffW(text.data(), static_cast<DWORD>(text.size()));
  return text;
}

bool EndsWith(const std::wstring& text, const wchar_t* suffix) {
  const size_t length = wcslen(suffix);
  return text.size() > length && _wcsicmp(text.c_str() + text.size() - length, suffix) == 0;
}

// Uninstallers and setups in the Start menu make no app's connections.
bool InstallerName(const std::wstring& name) {
  const auto lower = Lowered(name);
  for (const wchar_t* word : {L"unins", L"setup", L"installer"}) {
    if (lower.find(word) != std::wstring::npos) return true;
  }
  return false;
}

// The file a shortcut starts, as saved: Resolve could search disks or the network for a moved
// target. An advertised (MSI) shortcut names no file.
std::wstring ShortcutTarget(const std::wstring& shortcut) {
  Microsoft::WRL::ComPtr<IShellLinkW> link;
  Microsoft::WRL::ComPtr<IPersistFile> file;
  wchar_t target[MAX_PATH]{};
  if (FAILED(CoCreateInstance(CLSID_ShellLink, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&link))) ||
      FAILED(link.As(&file)) || FAILED(file->Load(shortcut.c_str(), STGM_READ)) ||
      link->GetPath(target, MAX_PATH, nullptr, 0) != S_OK) return {};
  return target;
}

constexpr size_t kShortcutLimit = 2000;

void FindShortcuts(const std::wstring& folder, int depth, std::vector<std::wstring>& found) {
  WIN32_FIND_DATAW data{};
  const HANDLE search = FindFirstFileExW((folder + L"\\*").c_str(), FindExInfoBasic, &data, FindExSearchNameMatch,
      nullptr, FIND_FIRST_EX_LARGE_FETCH);
  if (search == INVALID_HANDLE_VALUE) return;
  do {
    const std::wstring name = data.cFileName;
    if (name == L"." || name == L".." || (data.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)) continue;
    const auto path = folder + L"\\" + name;
    if (data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
      if (depth < 4) FindShortcuts(path, depth + 1, found);
    } else if (EndsWith(name, L".lnk")) {
      found.push_back(path);
    }
  } while (found.size() < kShortcutLimit && FindNextFileW(search, &data));
  FindClose(search);
}

std::wstring KnownFolder(REFKNOWNFOLDERID id) {
  PWSTR path = nullptr;
  std::wstring folder;
  if (SUCCEEDED(SHGetKnownFolderPath(id, KF_FLAG_DEFAULT, nullptr, &path))) folder = path;
  CoTaskMemFree(path);
  return folder;
}

std::vector<uint8_t> PackageLogo(const winrt::Windows::ApplicationModel::Core::AppListEntry& entry) {
  using namespace winrt::Windows::Storage::Streams;
  const auto stream = entry.DisplayInfo().GetLogo({64, 64}).OpenReadAsync().get();
  if (stream.ContentType() != L"image/png" || stream.Size() == 0 || stream.Size() > 65536) return {};
  DataReader reader(stream);
  const auto size = reader.LoadAsync(static_cast<uint32_t>(stream.Size())).get();
  std::vector<uint8_t> png(size);
  reader.ReadBytes(png);
  return png;
}
}

flutter::EncodableList ShortcutApplications(const std::vector<std::wstring>& folders, std::set<std::wstring>& seen) {
  using flutter::EncodableValue;
  flutter::EncodableList apps;
  std::vector<std::wstring> shortcuts;
  for (const auto& folder : folders) {
    if (!folder.empty() && shortcuts.size() < kShortcutLimit) FindShortcuts(folder, 0, shortcuts);
  }
  for (const auto& shortcut : shortcuts) {
    const auto start = shortcut.find_last_of(L"\\/") + 1;
    const auto name = shortcut.substr(start, shortcut.size() - start - 4);
    const auto target = ShortcutTarget(shortcut);
    if (InstallerName(name) || !EndsWith(target, L".exe") || !LocalApplicationPath(target) ||
        InstallerName(target.substr(target.find_last_of(L"\\/") + 1)) || RoutingUTF8(target.c_str()).size() > 1024) continue;
    const auto attributes = GetFileAttributesW(target.c_str());
    if (attributes == INVALID_FILE_ATTRIBUTES || (attributes & FILE_ATTRIBUTE_DIRECTORY)) continue;
    const auto rule = ExecutableRule(target);
    if (!seen.insert(Lowered(rule)).second) continue;
    auto app = RoutingApplication(target, true, rule);
    app[EncodableValue("name")] = EncodableValue(RoutingUTF8(name.c_str()));  // as the Start menu names it
    apps.emplace_back(std::move(app));
  }
  return apps;
}

flutter::EncodableList StartMenuApplications(std::set<std::wstring>& seen) {
  return ShortcutApplications({KnownFolder(FOLDERID_Programs), KnownFolder(FOLDERID_CommonPrograms)}, seen);
}

flutter::EncodableList PackagedApplications(std::set<std::wstring>& seen) {
  using flutter::EncodableValue;
  using namespace winrt::Windows::ApplicationModel;
  using namespace winrt::Windows::Management::Deployment;
  flutter::EncodableList apps;
  winrt::Windows::Foundation::Collections::IIterable<Package> packages{nullptr};
  try {
    packages = PackageManager().FindPackagesForUserWithPackageTypes(L"", PackageTypes::Main);
  } catch (...) {
    return apps;  // the list keeps its other apps
  }
  for (const auto& package : packages) {
    try {
      if (package.IsFramework() || package.IsResourcePackage() || package.SignatureKind() == PackageSignatureKind::System) continue;
      const auto rule = PackageRule(std::wstring(package.InstalledLocation().Path()) + L"\\");
      if (rule.empty() || RoutingUTF8(rule.c_str()).size() > 1024) continue;
      const auto entries = package.GetAppListEntriesAsync().get();
      if (entries.Size() == 0 || !seen.insert(Lowered(rule)).second) continue;
      std::wstring name(entries.GetAt(0).DisplayInfo().DisplayName());
      if (name.empty()) name = package.DisplayName();
      if (name.empty()) name = PackageAppName(rule);
      flutter::EncodableMap app = {{EncodableValue("name"), EncodableValue(RoutingUTF8(name.c_str()))},
          {EncodableValue("process"), EncodableValue(RoutingUTF8(rule.c_str()))}};
      try {
        auto logo = PackageLogo(entries.GetAt(0));
        if (!logo.empty()) app[EncodableValue("iconPng")] = EncodableValue(std::move(logo));
      } catch (...) {}
      apps.emplace_back(std::move(app));
    } catch (...) {}  // A package being installed or removed is left out.
  }
  return apps;
}

winrt::fire_and_forget RoutingApplicationLookup::Load(flutter::EncodableList selected,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const auto lifetime = shared_from_this();
  if (shutdown_) co_return;
  if (busy_) { result->Error("busy", "Applications are still loading."); co_return; }
  busy_ = true;
  winrt::apartment_context foreground;
  // Keep the MTA alive through the foreground handoff. Unlike CoUninitialize,
  // this cookie can be released on the window thread when the coroutine ends.
  struct Apartment {
    CO_MTA_USAGE_COOKIE cookie = nullptr;
    HRESULT status = CoIncrementMTAUsage(&cookie);
    ~Apartment() { if (SUCCEEDED(status)) CoDecrementMTAUsage(cookie); }
  } apartment;
  if (FAILED(apartment.status)) {
    busy_ = false;
    result->Error("applications_unavailable", "Applications could not be loaded.");
    co_return;
  }
  flutter::EncodableList apps;
  bool failed = false;
  try {
    co_await winrt::resume_background();
    apps = RunningApplications();
    using flutter::EncodableValue;
    std::set<std::wstring> seen;
    for (const auto& app : apps) {
      const auto& map = std::get<flutter::EncodableMap>(app);
      auto key = std::wstring(winrt::to_hstring(std::get<std::string>(map.at(EncodableValue("process")))));
      CharLowerBuffW(key.data(), static_cast<DWORD>(key.size()));
      seen.insert(key);
    }
    // Apps that are not running: the Start menu's, and Microsoft Store apps, which it lists
    // without a shortcut file.
    auto shortcuts = StartMenuApplications(seen);
    auto packaged = PackagedApplications(seen);
    for (auto* installed : {&shortcuts, &packaged}) {
      for (auto& app : *installed) apps.emplace_back(std::move(app));
    }
    for (const auto& value : selected) {
      const auto* path = std::get_if<std::string>(&value);
      if (!path || path->empty() || path->size() > 1024 || path->find('\0') != std::string::npos) continue;
      // A service that is not running is named by Dart.
      if (path->rfind("service:", 0) == 0) continue;
      const auto wide = std::wstring(winrt::to_hstring(*path));
      auto key = wide;
      CharLowerBuffW(key.data(), static_cast<DWORD>(key.size()));
      // A routing match is not permission to access that file. Reuse metadata
      // only for already enumerated processes; all other selections are names.
      // A local rule's folders are read to offer one that survives updates.
      if (!seen.insert(key).second) continue;
      auto app = RoutingApplication(wide);
      const auto suggested = UpdateProofRule(wide);
      if (!suggested.empty()) app[EncodableValue("suggested")] = EncodableValue(RoutingUTF8(suggested.c_str()));
      apps.emplace_back(std::move(app));
    }
  } catch (...) { failed = true; }
  // The result and lookup outlive the window, but no reply may use a destroyed
  // Flutter engine. Shutdown and completion both execute on this apartment.
  try { co_await foreground; } catch (...) { co_return; }
  busy_ = false;
  if (shutdown_) co_return;
  if (failed) result->Error("applications_unavailable", "Applications could not be loaded.");
  else result->Success(flutter::EncodableValue(std::move(apps)));
}
