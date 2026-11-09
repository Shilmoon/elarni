// From the repo root after a Linux Flutter build:
// clang++ -std=c++14 -Wall -Werror -Ilinux/flutter/ephemeral
//   -DAPPLICATION_ID='"com.elarni.Elarni"' test/linux_desktop_host_test.cc
//   -Llinux/flutter/ephemeral -lflutter_linux_gtk
//   $(pkg-config --cflags --libs gtk+-3.0 ayatana-appindicator3-0.1 gstreamer-app-1.0)
//   -o .build/linux-desktop-host-test
// env LD_LIBRARY_PATH=linux/flutter/ephemeral .build/linux-desktop-host-test
// CI runs this after its Linux release build.
#include "../linux/runner/desktop_host.cc"
#include <sys/wait.h>
#include <cassert>

// Runs as the installed copy. dpkg unpacks the next release beside the running
// binary and renames it over the path; /proc/self/exe then reads "<path> (deleted)".
static int autostart_after_upgrade(const std::string& installed) {
  const std::string unpacked = installed + ".dpkg-new";
  if (!g_file_set_contents(unpacked.c_str(), "next release", -1, nullptr) ||
      g_rename(unpacked.c_str(), installed.c_str()) != 0)
    return 2;
  const std::string exec = desktop_exec(executable());
  printf("autostart Exec after upgrade: %s\n", exec.c_str());
  return exec == desktop_exec(installed) ? 0 : 1;
}

int main(int argc, char** argv) {
  if (argc == 2) return autostart_after_upgrade(argv[1]);
  // The tray speaks the language Flutter resolves: the first English or Russian entry, here Russian.
  g_setenv("LANGUAGE", "uk:ru_RU:en", TRUE);
  assert(russian_interface());
  assert(strcmp(tray_state("connected, no traffic"), "подключено, нет трафика") == 0);
  assert(strcmp(tray_state("unknown"), "unknown") == 0);
  // Until the app reports the language it resolved, which Settings can choose.
  chosen_russian = 0;
  assert(!russian_interface() && strcmp(tray_label(1), "Connect") == 0);
  chosen_russian = -1;
  // Private desktop entries and autostart files; GLib reads these once, at first use.
  g_autofree char* home = g_dir_make_tmp("elarni-host-home-XXXXXX", nullptr);
  assert(home);
  const std::string config = std::string(home) + "/config", data = std::string(home) + "/data";
  g_setenv("XDG_CONFIG_HOME", config.c_str(), TRUE);
  g_setenv("XDG_DATA_HOME", data.c_str(), TRUE);
  g_setenv("XDG_DATA_DIRS", data.c_str(), TRUE);
  g_autofree char* directory = g_dir_make_tmp("elarni-app-path-XXXXXX", nullptr);
  assert(directory);
  const std::string binary = std::string(directory) + "/actual-app";
  const std::string alias = std::string(directory) + "/selected-app";
  assert(g_file_set_contents(binary.c_str(), "fixture", -1, nullptr));
  assert(g_chmod(binary.c_str(), 0700) == 0);
  assert(symlink(binary.c_str(), alias.c_str()) == 0);
  g_autoptr(FlValue) apps = fl_value_new_list();
  std::set<std::string> seen;
  add_app(apps, seen, "Selected app", alias.c_str());
  assert(fl_value_get_length(apps) == 1);
  auto* app = fl_value_get_list_value(apps, 0);
  assert(fl_value_get_string(fl_value_lookup_string(app, "process")) == binary);
  add_app(apps, seen, "Running app", binary.c_str());
  assert(fl_value_get_length(apps) == 1);
  assert(g_unlink(binary.c_str()) == 0);
  add_app(apps, seen, "Broken link", alias.c_str());
  assert(fl_value_get_length(apps) == 1);
  assert(g_unlink(alias.c_str()) == 0);

  // Snap apps run from /snap/<name>/<revision>/, which each refresh replaces.
  std::string rule_name;
  assert(application_rule("/snap/firefox/5134/usr/lib/firefox/firefox", rule_name) == "/snap/firefox/" && rule_name == "firefox");
  assert(application_rule("/snap/telegram-desktop/x2/usr/bin/telegram-desktop", rule_name) == "/snap/telegram-desktop/");
  for (const std::string& path : {"/snap/firefox/current/usr/lib/firefox/firefox", "/snap/firefox/5134", "/snap/bin/firefox"})
    assert(application_rule(path, rule_name) == path);
  // Claude Code keeps each version as ~/.local/share/claude/versions/<version> beside the previous one.
  // A version matches its folder of versions only when that folder holds nothing else.
  const std::string versions = std::string(directory) + "/claude/versions", tools = std::string(directory) + "/tools";
  assert(g_mkdir_with_parents(versions.c_str(), 0700) == 0 && g_mkdir_with_parents((tools + "/1.0").c_str(), 0700) == 0 &&
         g_mkdir((tools + "/plugins").c_str(), 0700) == 0);
  for (const std::string& file : {versions + "/2.1.300", versions + "/2.1.314", tools + "/1.0/tool"})
    assert(g_file_set_contents(file.c_str(), "fixture", -1, nullptr) && g_chmod(file.c_str(), 0700) == 0);
  rule_name.clear();
  assert(application_rule(versions + "/2.1.314", rule_name) == versions + "/" && rule_name == "claude");
  assert(application_rule(tools + "/1.0/tool", rule_name) == tools + "/1.0/tool");
  g_autoptr(FlValue) versioned = fl_value_new_list();
  std::set<std::string> versioned_seen;
  add_app(versioned, versioned_seen, nullptr, (versions + "/2.1.300").c_str(), nullptr, true);
  add_app(versioned, versioned_seen, nullptr, (versions + "/2.1.314").c_str(), nullptr, true);
  assert(fl_value_get_length(versioned) == 1);
  auto* claude_code = fl_value_get_list_value(versioned, 0);
  assert(fl_value_get_string(fl_value_lookup_string(claude_code, "process")) == versions + "/");
  assert(strcmp(fl_value_get_string(fl_value_lookup_string(claude_code, "name")), "claude") == 0);
  // A saved rule is listed as saved.
  add_app(versioned, versioned_seen, nullptr, (versions + "/2.1.314").c_str());
  assert(fl_value_get_length(versioned) == 2);
  for (const std::string& file : {versions + "/2.1.300", versions + "/2.1.314", tools + "/1.0/tool"})
    assert(g_unlink(file.c_str()) == 0);
  for (const std::string& folder : {versions, std::string(directory) + "/claude", tools + "/1.0", tools + "/plugins", tools})
    assert(g_rmdir(folder.c_str()) == 0);

  // A save name near NAME_MAX leaves no room to suffix the temporary file's name.
  const std::string exported = std::string(directory) + "/" + std::string(245, 'a') + ".json";
  for (const char* content : {"first", "second"}) {
    assert(write_private(exported, content, strlen(content)));
    g_autofree char* saved = nullptr;
    assert(g_file_get_contents(exported.c_str(), &saved, nullptr, nullptr) && strcmp(saved, content) == 0);
  }
  assert(g_unlink(exported.c_str()) == 0);

  // A launcher chosen in the picker would become a rule for /usr/bin/snap or /bin/sh.
  const std::string script = std::string(directory) + "/wrapper";
  const std::string snap = std::string(directory) + "/snap";
  const std::string firefox = std::string(directory) + "/firefox";
  const std::string native = std::string(directory) + "/native-app";
  assert(g_file_set_contents(script.c_str(), "#!/bin/sh\nexec true\n", -1, nullptr) && g_chmod(script.c_str(), 0700) == 0);
  assert(g_file_set_contents(snap.c_str(), "fixture", -1, nullptr) && g_chmod(snap.c_str(), 0700) == 0);
  assert(g_file_set_contents(native.c_str(), "fixture", -1, nullptr) && g_chmod(native.c_str(), 0700) == 0);
  assert(symlink(snap.c_str(), firefox.c_str()) == 0);
  auto chosen = [](const std::string& path) {
    const char* error = chosen_application_error(path.c_str());
    return std::string(error ? error : "");
  };
  assert(chosen(script) == "launcher_application");
  assert(chosen(firefox) == "launcher_application");
  assert(chosen(native).empty());

  // "Exec=sh -c ..." names the shell, not the app, so that entry is not listed.
  const std::string entries = data + "/applications";
  assert(g_mkdir_with_parents(entries.c_str(), 0700) == 0);
  const std::string wrapped = "[Desktop Entry]\nType=Application\nName=Wrapped fixture\nExec=sh -c \"exec " + native + "\"\n";
  const std::string direct = "[Desktop Entry]\nType=Application\nName=Native fixture\nExec=" + native + "\n";
  assert(g_file_set_contents((entries + "/wrapped.desktop").c_str(), wrapped.c_str(), -1, nullptr));
  assert(g_file_set_contents((entries + "/direct.desktop").c_str(), direct.c_str(), -1, nullptr));
  g_autoptr(FlValue) none = fl_value_new_map();
  g_autoptr(FlValue) listed = applications(none);
  bool wrapped_listed = false, direct_listed = false;
  for (size_t index = 0; index < fl_value_get_length(listed); ++index) {
    const std::string name = fl_value_get_string(fl_value_lookup_string(fl_value_get_list_value(listed, index), "name"));
    wrapped_listed = wrapped_listed || name == "Wrapped fixture";
    direct_listed = direct_listed || name == "Native fixture";
  }
  assert(direct_listed && !wrapped_listed);
  for (const std::string& path : {script, snap, firefox, native, entries + "/wrapped.desktop", entries + "/direct.desktop"})
    assert(g_unlink(path.c_str()) == 0);
  assert(g_rmdir(entries.c_str()) == 0 && g_rmdir(data.c_str()) == 0);
  assert(g_rmdir(directory) == 0);

  // As on Windows, an autostart entry for a moved copy does not start this one.
  const std::string autostart = config_path("autostart/com.elarni.Elarni.desktop");
  auto login = [&](const std::string& exec) {
    g_autoptr(GKeyFile) entry = g_key_file_new();
    g_key_file_set_string(entry, "Desktop Entry", "Type", "Application");
    g_key_file_set_string(entry, "Desktop Entry", "Exec", exec.c_str());
    g_autofree char* contents = g_key_file_to_data(entry, nullptr, nullptr);
    assert(write_private(autostart, contents, strlen(contents)));
    g_autoptr(FlValue) info = system_info();
    return std::string(fl_value_get_string(fl_value_lookup_string(info, "launchAtLoginStatus")));
  };
  assert(login(desktop_exec("/moved/elarni")) == "notRegistered");
  assert(login(desktop_exec(executable())) == "enabled");
  // An AppImage's mount is gone after exit, so login starts the image file. An AppImage
  // that merely launched this copy (its APPDIR does not hold it) is not taken.
  g_autofree char* images = g_dir_make_tmp("elarni-appimage-XXXXXX", nullptr);
  assert(images);
  const std::string appimage = std::string(images) + "/Elarni.AppImage";
  assert(g_file_set_contents(appimage.c_str(), "image", -1, nullptr));
  g_autofree char* mount = g_path_get_dirname(executable().c_str());
  g_setenv("APPIMAGE", appimage.c_str(), TRUE);
  g_setenv("APPDIR", mount, TRUE);
  assert(launcher() == appimage);
  assert(login(desktop_exec(appimage)) == "enabled");
  assert(login(desktop_exec(executable())) == "notRegistered");
  g_setenv("APPDIR", "/tmp/.mount_ElarniOther", TRUE);
  assert(launcher() == executable());
  g_unsetenv("APPIMAGE");
  g_unsetenv("APPDIR");
  assert(g_unlink(appimage.c_str()) == 0 && g_rmdir(images) == 0);
  assert(g_unlink(autostart.c_str()) == 0);
  assert(g_rmdir((config + "/autostart").c_str()) == 0 && g_rmdir(config.c_str()) == 0 && g_rmdir(home) == 0);

  // Enabling autostart after an upgrade, before a restart, still names the installed binary.
  g_autofree char* upgrade = g_dir_make_tmp("elarni-autostart-XXXXXX", nullptr);
  assert(upgrade);
  const std::string installed = std::string(upgrade) + "/elarni";
  g_autofree char* self = g_file_read_link("/proc/self/exe", nullptr);
  g_autofree char* image = nullptr;
  gsize length = 0;
  assert(self && g_file_get_contents(self, &image, &length, nullptr));
  assert(g_file_set_contents(installed.c_str(), image, length, nullptr));
  assert(g_chmod(installed.c_str(), 0755) == 0);
  const pid_t child = fork();
  assert(child >= 0);
  if (child == 0) {
    execl(installed.c_str(), installed.c_str(), installed.c_str(), static_cast<char*>(nullptr));
    _exit(3);
  }
  int status = 0;
  assert(waitpid(child, &status, 0) == child);
  assert(g_unlink(installed.c_str()) == 0);
  assert(g_rmdir(upgrade) == 0);
  assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);
}
