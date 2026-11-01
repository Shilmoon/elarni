#ifndef RUNNER_UTILS_H_
#define RUNNER_UTILS_H_

#include <string>
#include <vector>

// Creates a console for the process, and redirects stdout and stderr to
// it for both the runner and the Flutter library.
void CreateAndAttachConsole();

// Takes a null-terminated wchar_t* encoded in UTF-16 and returns a std::string
// encoded in UTF-8. Returns an empty std::string on failure.
std::string Utf8FromUtf16(const wchar_t* utf16_string);

// Gets the command line arguments passed in as a std::vector<std::string>,
// encoded in UTF-8. Returns an empty std::vector<std::string> on failure.
std::vector<std::string> GetCommandLineArguments();

// Writes content to a file beside target, then moves it over target, so a failed
// write leaves the previous file whole. Returns false on failure.
bool SaveReplacing(const std::wstring& target, const std::string& content);

// Reports whether a Run-key command launches app, a path compared without case.
bool IsLaunchCommand(const std::wstring& command, const std::wstring& app);

// Whether the runner speaks Russian. As Flutter resolves the app's language, the
// first English or Russian entry of the preferred UI languages decides, until the
// app reports the language it resolved, which Settings can choose.
bool RussianInterface();
void SetRussianInterface(bool russian);

inline const wchar_t* Localized(const wchar_t* english, const wchar_t* russian) {
  return RussianInterface() ? russian : english;
}

// The Russian form for a count: 0 for one (1, 21), 1 for few (2-4, 22-24), 2 for many.
constexpr int RussianPluralForm(int count) {
  return count % 10 == 1 && count % 100 != 11 ? 0
      : count % 10 >= 2 && count % 10 <= 4 && (count % 100 < 12 || count % 100 > 14) ? 1 : 2;
}
static_assert(RussianPluralForm(1) == 0 && RussianPluralForm(21) == 0 && RussianPluralForm(11) == 2 &&
    RussianPluralForm(3) == 1 && RussianPluralForm(13) == 2 && RussianPluralForm(1024) == 1 && RussianPluralForm(5) == 2,
    "Russian plural forms");

#endif  // RUNNER_UTILS_H_
