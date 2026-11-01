#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <winrt/base.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  winrt::init_apartment(winrt::apartment_type::single_threaded);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  if (command_line_arguments.size() == 1 && command_line_arguments[0] == "--unregister") {
    const bool removed = UnregisterProfileLinks();
    winrt::uninit_apartment();
    return removed ? EXIT_SUCCESS : EXIT_FAILURE;
  }

  // Forward links only to this executable's existing desktop window.
  for (HWND existing = FindWindowExW(nullptr, nullptr, kWindowClassName, L"Elarni");
       existing;
       existing = FindWindowExW(nullptr, existing, kWindowClassName, L"Elarni")) {
    DWORD pid = 0;
    GetWindowThreadProcessId(existing, &pid);
    const HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    wchar_t target[32768]{}, current[32768]{};
    DWORD size = 32768;
    const bool own = process && QueryFullProcessImageNameW(process, 0, target, &size) &&
        GetModuleFileNameW(nullptr, current, 32768) && _wcsicmp(target, current) == 0;
    if (process) CloseHandle(process);
    if (own) {
      wchar_t headless[2]{};
      const bool daemon = GetEnvironmentVariableW(L"ELARNI_HEADLESS", headless, 2) == 1 && headless[0] == L'1';
      if (daemon || GetPropW(existing, L"ElarniHeadless")) {
        // A double-click must not fail silently while elarni-cli owns the app.
        if (!daemon)
          MessageBoxW(nullptr, Localized(L"Elarni is running in the background for elarni-cli. Run \"elarni-cli shutdown\", then open Elarni again.",
              L"Elarni работает в фоне для elarni-cli. Выполните \"elarni-cli shutdown\", затем снова откройте Elarni."),
              L"Elarni", MB_OK | MB_ICONINFORMATION);
        winrt::uninit_apartment();
        return EXIT_FAILURE;
      }
      for (const auto& argument : command_line_arguments) {
        if (argument.empty()) continue;
        COPYDATASTRUCT data{0x52564c31, static_cast<DWORD>(argument.size() + 1), const_cast<char*>(argument.c_str())};
        DWORD_PTR result = 0;
        if (argument.size() >= 4 * 1024 * 1024 ||
            !SendMessageTimeoutW(existing, WM_COPYDATA, 0, reinterpret_cast<LPARAM>(&data), SMTO_ABORTIFHUNG, 3000, &result) || !result) {
          // The running window refused the link or did not answer; say so rather than drop it.
          MessageBoxW(nullptr, Localized(L"Elarni could not open this link in its running window. Wait until Elarni responds, then open the link again.",
              L"Elarni не удалось открыть эту ссылку в запущенном окне. Дождитесь ответа Elarni и откройте ссылку снова."),
              L"Elarni", MB_OK | MB_ICONWARNING);
          winrt::uninit_apartment();
          return EXIT_FAILURE;
        }
      }
      ShowWindow(existing, SW_RESTORE);
      SetForegroundWindow(existing);
      winrt::uninit_apartment();
      return EXIT_SUCCESS;
    }
  }

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(800, 600);
  if (!window.Create(L"Elarni", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  winrt::uninit_apartment();
  return EXIT_SUCCESS;
}
