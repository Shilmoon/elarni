// Native boundary checks: no Flutter engine, registry registration, or VPN.
#include <windows.h>
#include <shellapi.h>
#include <atomic>
#include <cstdio>
#include <stdexcept>
#include <flutter/method_result_functions.h>
#include "../runner/utils.h"

static std::atomic<int> icon_calls{0};
static std::atomic<DWORD> icon_thread{0};
static std::atomic<bool> pause_next_icon{false};
static HANDLE icon_entered, icon_release;
static DWORD_PTR CheckedFileInfo(LPCWSTR, DWORD, SHFILEINFOW*, UINT, UINT) {
  ++icon_calls;
  icon_thread = GetCurrentThreadId();
  if (pause_next_icon.exchange(false)) {
    SetEvent(icon_entered);
    WaitForSingleObject(icon_release, 10000);
  }
  return 0;  // No file or share is ever opened by this fixture.
}
#define SHGetFileInfoW CheckedFileInfo
#include "../runner/routing_applications.cpp"
#undef SHGetFileInfoW

void Require(bool value, const char* message) {
  if (!value) throw std::runtime_error(message);
}

int main() {
  winrt::init_apartment(winrt::apartment_type::single_threaded);
  try {
    using flutter::EncodableValue;
    // The tray speaks the language Flutter resolves: the first English or Russian entry, here Russian.
    ULONG languages = 0;
    Require(SetThreadPreferredUILanguages(MUI_LANGUAGE_NAME, L"uk-UA\0ru-RU\0en-US\0", &languages) && RussianInterface(),
            "the runner did not pick Russian from uk-UA, ru-RU, en-US");
    std::puts("PASS the tray picks its language as Flutter does");
    const auto foreground = GetCurrentThreadId();
    for (const auto* path : {L"\\\\server.invalid\\share\\app.exe", L"//server.invalid/share/app.exe",
                            L"\\\\?\\UNC\\server.invalid\\share\\app.exe", L"\\\\.\\pipe\\fixture",
                            L"Z:\\remote\\app.exe", L"C:\\local\\app.exe"}) {
      const auto app = RoutingApplication(path);
      Require(!app.contains(EncodableValue("iconPng")), "imported path requested file metadata");
      Require(!std::get<std::string>(app.at(EncodableValue("process"))).empty(), "routing string lost");
    }
    Require(icon_calls == 0, "imported paths reached shell metadata");
    std::puts("PASS imported network, device, mapped-drive and local paths never request metadata");
    Require(!LocalApplicationPath(L"\\\\server.invalid\\share\\app.exe") &&
            !LocalApplicationPath(L"\\\\?\\C:\\app.exe") &&
            !LocalApplicationPath(L"//server.invalid/share/app.exe") &&
            !LocalApplicationPath(L"C:app.exe"), "non-local running path accepted");
    std::puts("PASS automatic running-process icon lookup rejects UNC/device/relative paths");

    // Discord's layout: <root>\Update.exe, a <root>\Discord.exe stub that the Start menu
    // shortcut starts, and the real <root>\app-<version>\Discord.exe that each update replaces.
    wchar_t squirrel_temp[MAX_PATH]{};
    Require(GetTempPathW(MAX_PATH, squirrel_temp) > 0, "no temporary directory");
    const auto base = std::wstring(squirrel_temp) + L"elarni-squirrel-check-" + std::to_wstring(GetCurrentProcessId());
    const auto squirrel = base + L"\\Discord", lone = base + L"\\Lone", updater = base + L"\\Updater";
    const std::wstring folders[] = {base, squirrel, squirrel + L"\\app-1.0.9265", lone, lone + L"\\app-1.0", updater};
    const std::wstring files[] = {squirrel + L"\\Update.exe", squirrel + L"\\Discord.exe",
        squirrel + L"\\app-1.0.9265\\Discord.exe", lone + L"\\app-1.0\\Tool.exe",
        updater + L"\\Update.exe", updater + L"\\app-notes.txt"};
    bool created = true;
    for (const auto& folder : folders) created = CreateDirectoryW(folder.c_str(), nullptr) && created;
    for (const auto& file : files) {
      const HANDLE handle = CreateFileW(file.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
      created = handle != INVALID_HANDLE_VALUE && created;
      if (handle != INVALID_HANDLE_VALUE) CloseHandle(handle);
    }
    std::wstring rules[std::size(files)];
    for (size_t index = 0; index < std::size(files); ++index) rules[index] = ExecutableRule(files[index]);
    const auto squirrel_app = RoutingApplication(files[2], false, rules[2]);
    for (const auto& file : files) DeleteFileW(file.c_str());
    for (auto folder = std::rbegin(folders); folder != std::rend(folders); ++folder) RemoveDirectoryW(folder->c_str());
    Require(created, "could not create the Squirrel fixture");
    for (size_t index = 0; index < 3; ++index) {
      if (rules[index] != squirrel + L"\\") std::fwprintf(stderr, L"%ls -> %ls\n", files[index].c_str(), rules[index].c_str());
      Require(rules[index] == squirrel + L"\\", "a Squirrel executable did not match its install folder");
    }
    Require(rules[3] == files[3] && rules[4] == files[4], "a non-Squirrel executable lost its exact path");
    Require(std::get<std::string>(squirrel_app.at(EncodableValue("process"))) == RoutingUTF8((squirrel + L"\\").c_str()),
        "the Squirrel folder rule was not offered");
    const std::wstring remote = L"\\\\server.invalid\\share\\Discord\\app-1.0\\Discord.exe";
    Require(ExecutableRule(remote) == remote, "a network path was resolved");
    std::puts("PASS Squirrel apps such as Discord match their install folder across updates");

    auto lookup = std::make_shared<RoutingApplicationLookup>();
    bool complete = false, failed = false;
    DWORD reply_thread = 0;
    std::string reply_error;
    auto reply = std::make_unique<flutter::MethodResultFunctions<EncodableValue>>(
      [&](const EncodableValue* value) {
        reply_thread = GetCurrentThreadId();
        failed = reply_thread != foreground || value == nullptr;
        complete = true;
      }, [&](const std::string& code, const std::string&, const EncodableValue*) {
        reply_thread = GetCurrentThreadId(); reply_error = code; failed = complete = true;
      },
      [&] { failed = complete = true; });
    lookup->Load({}, std::move(reply));
    Require(!complete, "metadata call blocked for completion on the window thread");
    const auto deadline = GetTickCount64() + 10000;
    while (!complete && GetTickCount64() < deadline) {
      MSG message{};
      while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
        TranslateMessage(&message); DispatchMessageW(&message);
      }
      MsgWaitForMultipleObjects(0, nullptr, FALSE, 10, QS_ALLINPUT);
    }
    if (!complete || failed) std::fprintf(stderr,
        "Lookup completion=%d failed=%d reply_thread=%lu foreground=%lu error=%s icon_calls=%d\n",
        complete, failed, reply_thread, foreground, reply_error.c_str(), icon_calls.load());
    Require(complete && !failed, "lookup did not reply on its original window thread");
    Require(icon_calls > 0 && icon_thread != foreground, "running icons were not checked on a worker");
    lookup->Stop();
    std::puts("PASS metadata work is asynchronous and completion returns to the window thread");

    icon_entered = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    icon_release = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    Require(icon_entered && icon_release, "fixture events unavailable");
    pause_next_icon = true;
    auto closing = std::make_shared<RoutingApplicationLookup>();
    bool replied_after_close = false, released = false, busy_replied = false;
    struct Receipt {
      bool& released;
      explicit Receipt(bool& value) : released(value) {}
      ~Receipt() { released = true; }
    };
    auto receipt = std::make_shared<Receipt>(released);
    auto late = std::make_unique<flutter::MethodResultFunctions<EncodableValue>>(
      [&, receipt](const EncodableValue*) { replied_after_close = true; },
      [&, receipt](const std::string&, const std::string&, const EncodableValue*) { replied_after_close = true; },
      [&, receipt] { replied_after_close = true; });
    receipt.reset();
    closing->Load({}, std::move(late));
    Require(WaitForSingleObject(icon_entered, 10000) == WAIT_OBJECT_0, "worker did not reach pause");
    auto duplicate = std::make_unique<flutter::MethodResultFunctions<EncodableValue>>(
      [&](const EncodableValue*) { failed = true; },
      [&](const std::string& code, const std::string&, const EncodableValue*) { busy_replied = code == "busy"; },
      [&] { failed = true; });
    closing->Load({}, std::move(duplicate));
    Require(busy_replied && !failed, "overlapping lookup was not bounded");
    std::puts("PASS overlapping metadata requests do not start unbounded workers");
    closing->Stop();
    closing.reset();
    SetEvent(icon_release);
    const auto close_deadline = GetTickCount64() + 10000;
    while (!released && GetTickCount64() < close_deadline) {
      MSG message{};
      while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
        TranslateMessage(&message); DispatchMessageW(&message);
      }
      MsgWaitForMultipleObjects(0, nullptr, FALSE, 10, QS_ALLINPUT);
    }
    Require(released && !replied_after_close, "late lookup replied after window shutdown");
    CloseHandle(icon_entered); CloseHandle(icon_release);
    std::puts("PASS closing the window suppresses late replies and releases worker ownership");

    // An export name near the 255-character limit leaves no room to suffix the temporary file's name.
    wchar_t temp[MAX_PATH]{};
    Require(GetTempPathW(MAX_PATH, temp) > 0, "no temporary directory");
    const auto directory = L"\\\\?\\" + std::wstring(temp) + L"elarni-save-check-" + std::to_wstring(GetCurrentProcessId());
    Require(CreateDirectoryW(directory.c_str(), nullptr), "could not create the save directory");
    const auto target = directory + L"\\" + std::wstring(230, L'a') + L".json";
    const bool saved = SaveReplacing(target, "{}") && SaveReplacing(target, "{\"saved\":2}");
    WIN32_FILE_ATTRIBUTE_DATA attributes{};
    const bool replaced = GetFileAttributesExW(target.c_str(), GetFileExInfoStandard, &attributes) && attributes.nFileSizeLow == 11;
    DeleteFileW(target.c_str()); RemoveDirectoryW(directory.c_str());
    Require(saved && replaced, "an export with a long file name was not saved");
    std::puts("PASS an export with a long file name saves and replaces the previous file");
    // Windows paths are case-insensitive, so a Run value written through another casing is still ours.
    Require(IsLaunchCommand(L"\"C:\\Program Files\\Elarni\\elarni.exe\"", L"c:\\program files\\elarni\\Elarni.exe") &&
        !IsLaunchCommand(L"\"C:\\Other\\elarni.exe\"", L"C:\\Program Files\\Elarni\\elarni.exe") &&
        !IsLaunchCommand(L"C:\\Program Files\\Elarni\\elarni.exe", L"C:\\Program Files\\Elarni\\elarni.exe"),
        "launch at login compares the Run value with the wrong case rule");
    std::puts("PASS launch at login matches its Run value in any letter case");
    std::puts("9 native routing metadata checks passed");
  } catch (const std::exception& error) {
    std::fprintf(stderr, "FAIL %s\n", error.what()); return 1;
  } catch (...) { std::fputs("FAIL native routing metadata check\n", stderr); return 1; }
  winrt::uninit_apartment();
}
