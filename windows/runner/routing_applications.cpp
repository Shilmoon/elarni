#include "routing_applications.h"
#include <windows.h>
#include <shellapi.h>
#include <tlhelp32.h>
#include <wrl/client.h>
#include <wincodec.h>
#include <set>
#include <stdexcept>

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

std::wstring ExecutableRule(const std::wstring& path) {
  if (!LocalApplicationPath(path)) return path;
  auto root = path.substr(0, path.find_last_of(L"\\/"));
  const auto parent = root.find_last_of(L"\\/");
  if (parent != std::wstring::npos && _wcsnicmp(root.c_str() + parent + 1, L"app-", 4) == 0) root.resize(parent);
  // A drive root would match every executable on that drive.
  if (root.find_first_of(L"\\/") == std::wstring::npos) return path;
  const auto updater = GetFileAttributesW((root + L"\\Update.exe").c_str());
  if (updater == INVALID_FILE_ATTRIBUTES || (updater & FILE_ATTRIBUTE_DIRECTORY)) return path;
  WIN32_FIND_DATAW found{};
  const HANDLE search = FindFirstFileExW((root + L"\\app-*").c_str(), FindExInfoBasic, &found,
      FindExSearchLimitToDirectories, nullptr, 0);
  if (search == INVALID_HANDLE_VALUE) return path;
  bool versioned = false;
  do versioned = (found.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
  while (!versioned && FindNextFileW(search, &found));
  FindClose(search);
  return versioned ? root + L"\\" : path;
}

flutter::EncodableMap RoutingApplication(const std::wstring& path, bool running, const std::wstring& rule) {
  using flutter::EncodableValue;
  const auto& process = rule.empty() ? path : rule;
  // A folder rule has no file name; Dart names it after the folder.
  const auto name = process.substr(process.find_last_of(L"\\/") + 1);
  flutter::EncodableMap app = {{EncodableValue("name"), EncodableValue(RoutingUTF8(name.c_str()))},
      {EncodableValue("process"), EncodableValue(RoutingUTF8(process.c_str()))}};
  auto icon = running && LocalApplicationPath(path) ? ApplicationIcon(path) : std::vector<uint8_t>{};
  if (!icon.empty()) app[EncodableValue("iconPng")] = EncodableValue(std::move(icon));
  return app;
}

flutter::EncodableList RunningApplications() {
  flutter::EncodableList apps;
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
    for (const auto& value : selected) {
      const auto* path = std::get_if<std::string>(&value);
      if (!path || path->empty() || path->size() > 1024 || path->find('\0') != std::string::npos) continue;
      const auto wide = std::wstring(winrt::to_hstring(*path));
      auto key = wide;
      CharLowerBuffW(key.data(), static_cast<DWORD>(key.size()));
      // A routing match is not permission to access that file. Reuse metadata
      // only for already enumerated processes; all other selections are names.
      if (seen.insert(key).second) apps.emplace_back(RoutingApplication(wide));
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
