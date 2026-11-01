#include "utils.h"

#include <flutter_windows.h>
#include <io.h>
#include <objbase.h>
#include <stdio.h>
#include <windows.h>

#include <iostream>

void CreateAndAttachConsole() {
  if (::AllocConsole()) {
    FILE *unused;
    if (freopen_s(&unused, "CONOUT$", "w", stdout)) {
      _dup2(_fileno(stdout), 1);
    }
    if (freopen_s(&unused, "CONOUT$", "w", stderr)) {
      _dup2(_fileno(stdout), 2);
    }
    std::ios::sync_with_stdio();
    FlutterDesktopResyncOutputStreams();
  }
}

bool SaveReplacing(const std::wstring& target, const std::string& content) {
  GUID unique{};
  wchar_t suffix[40]{};
  if (FAILED(CoCreateGuid(&unique)) || !StringFromGUID2(unique, suffix, 40)) return false;
  // The \\?\ form lifts MAX_PATH so a long target still saves.
  const std::wstring extended = target.rfind(L"\\\\", 0) != 0 ? L"\\\\?\\" + target
      : target.rfind(L"\\\\?\\", 0) == 0 ? target : L"\\\\?\\UNC\\" + target.substr(2);
  // A name of its own: suffixing a long file name would pass the 255-character limit.
  const auto temporary = extended.substr(0, extended.find_last_of(L'\\') + 1) + suffix + L".tmp";
  const auto file = CreateFileW(temporary.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
  DWORD written = 0;
  bool saved = file != INVALID_HANDLE_VALUE && WriteFile(file, content.data(), static_cast<DWORD>(content.size()), &written, nullptr) && written == content.size() && FlushFileBuffers(file);
  if (file != INVALID_HANDLE_VALUE) CloseHandle(file);
  if (saved) saved = MoveFileExW(temporary.c_str(), extended.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) != 0;
  if (!saved) DeleteFileW(temporary.c_str());
  return saved;
}

std::vector<std::string> GetCommandLineArguments() {
  // Convert the UTF-16 command line arguments to UTF-8 for the Engine to use.
  int argc;
  wchar_t** argv = ::CommandLineToArgvW(::GetCommandLineW(), &argc);
  if (argv == nullptr) {
    return std::vector<std::string>();
  }

  std::vector<std::string> command_line_arguments;

  // Skip the first argument as it's the binary name.
  for (int i = 1; i < argc; i++) {
    command_line_arguments.push_back(Utf8FromUtf16(argv[i]));
  }

  ::LocalFree(argv);

  return command_line_arguments;
}

std::string Utf8FromUtf16(const wchar_t* utf16_string) {
  if (utf16_string == nullptr) {
    return std::string();
  }
  // First, find the length of the string with a safe upper bound (CWE-126).
  // UNICODE_STRING_MAX_CHARS (32767) is the maximum length of a UNICODE_STRING.
  int input_length = static_cast<int>(wcsnlen(utf16_string, UNICODE_STRING_MAX_CHARS));
  // Now use that bounded length to determine the required buffer size.
  // When an explicit length is passed, WideCharToMultiByte does not include
  // the null terminator in its returned size.
  int target_length = ::WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, utf16_string,
      input_length, nullptr, 0, nullptr, nullptr);
  std::string utf8_string;
  if (target_length == 0 || static_cast<size_t>(target_length) > utf8_string.max_size()) {
    return utf8_string;
  }
  utf8_string.resize(target_length);
  int converted_length = ::WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, utf16_string,
      input_length, utf8_string.data(), target_length, nullptr, nullptr);
  if (converted_length == 0) {
    return std::string();
  }
  return utf8_string;
}

bool IsLaunchCommand(const std::wstring& command, const std::wstring& app) {
  return _wcsicmp(command.c_str(), (L"\"" + app + L"\"").c_str()) == 0;
}

static int chosen_russian = -1;

void SetRussianInterface(bool russian) { chosen_russian = russian ? 1 : 0; }

bool RussianInterface() {
  if (chosen_russian >= 0) return chosen_russian == 1;
  // The flags and order the Flutter engine reads the languages with.
  static const bool russian = [] {
    const DWORD flags = MUI_LANGUAGE_NAME | MUI_UI_FALLBACK;
    ULONG count = 0, size = 0;
    if (!GetThreadPreferredUILanguages(flags, &count, nullptr, &size) || size == 0) return false;
    std::wstring names(size, L'\0');
    if (!GetThreadPreferredUILanguages(flags, &count, names.data(), &size)) return false;
    for (const wchar_t* name = names.c_str(); *name; name += wcslen(name) + 1) {
      const auto is = [name](const wchar_t* code) { return _wcsnicmp(name, code, 2) == 0 && (name[2] == L'\0' || name[2] == L'-'); };
      if (is(L"ru") || is(L"en")) return is(L"ru");
    }
    return false;
  }();
  return russian;
}
