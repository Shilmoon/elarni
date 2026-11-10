#include "desktop_host.h"

#include <libayatana-appindicator/app-indicator.h>
#include <gst/app/gstappsink.h>
#include <gst/gst.h>
#include <glib/gstdio.h>
#include <fcntl.h>
#include <sys/sysinfo.h>
#include <sys/utsname.h>
#include <unistd.h>
#include <algorithm>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <set>
#include <string>
#include <vector>

struct DesktopHost {
  GtkApplication* app;
  GtkWindow* window;
  FlMethodChannel* desktop;
  FlMethodChannel* platform;
  AppIndicator* indicator = nullptr;
  GtkWidget* menu = nullptr;
  GtkWidget* state = nullptr;
  GtkWidget* connect = nullptr;
  GtkWidget* disconnect = nullptr;
  GDBusConnection* system_bus = nullptr;
  guint sleep_subscription = 0;
  GstElement* camera = nullptr;
  GstElement* frames = nullptr;
  std::string icon;
  std::vector<std::string> links;
};

namespace {
// Whether the runner speaks Russian. As Flutter resolves the app's language from
// the same list, the first English or Russian entry decides, until the app reports
// the language it resolved, which Settings can choose.
int chosen_russian = -1;
bool russian_interface() {
  if (chosen_russian >= 0) return chosen_russian == 1;
  static const bool russian = [] {
    for (const gchar* const* name = g_get_language_names(); *name; ++name) {
      auto is = [&](const char* code) { return strncmp(*name, code, 2) == 0 && ((*name)[2] == '\0' || strchr("_.@", (*name)[2])); };
      if (is("ru") || is("en")) return is("ru");
    }
    return false;
  }();
  return russian;
}
const char* localized(const char* english, const char* russian) { return russian_interface() ? russian : english; }
// The tray actions, in menu order after the state line and its separator.
const char* tray_label(int index) {
  static const char* const labels[][2] = {{"Show Elarni", "Показать Elarni"}, {"Connect", "Подключить"},
      {"Disconnect", "Отключить"}, {"Quit Elarni", "Выйти из Elarni"}};
  return localized(labels[index][0], labels[index][1]);
}
// The Russian form for a count: 0 for one (1, 21), 1 for few (2-4, 22-24), 2 for many.
constexpr int russian_plural_form(int count) {
  return count % 10 == 1 && count % 100 != 11 ? 0
      : count % 10 >= 2 && count % 10 <= 4 && (count % 100 < 12 || count % 100 > 14) ? 1 : 2;
}
static_assert(russian_plural_form(1) == 0 && russian_plural_form(21) == 0 && russian_plural_form(11) == 2 &&
    russian_plural_form(3) == 1 && russian_plural_form(13) == 2 && russian_plural_form(1024) == 1 && russian_plural_form(5) == 2,
    "Russian plural forms");
// The tray line names the tunnel state Dart sends as a code.
const char* tray_state(const char* state) {
  static const std::map<std::string, const char*> russian = {
      {"disconnected", "отключено"}, {"preparing", "подготовка"}, {"prepared", "подготовлено"},
      {"connecting", "подключение"}, {"connected", "подключено"}, {"disconnecting", "отключение"},
      {"reasserting", "восстановление связи"}, {"reconnecting", "переподключение"},
      {"invalid", "требуется настройка"}, {"failed", "ошибка подключения"},
      {"connected, no traffic", "подключено, нет трафика"}};
  const auto found = russian.find(state);
  return russian_interface() && found != russian.end() ? found->second : state;
}
void fail(FlMethodCall* call, const char* code) {
  fl_method_call_respond_error(call, code, nullptr, nullptr, nullptr);
}
void success(FlMethodCall* call, FlValue* value = nullptr) {
  fl_method_call_respond_success(call, value, nullptr);
}
FlValue* field(FlValue* args, const char* name, FlValueType type) {
  if (!args || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) return nullptr;
  auto* value = fl_value_lookup_string(args, name);
  return value && fl_value_get_type(value) == type ? value : nullptr;
}
const char* text_field(FlValue* args, const char* name, size_t limit) {
  auto* value = field(args, name, FL_VALUE_TYPE_STRING);
  if (!value) return nullptr;
  const char* text = fl_value_get_string(value);
  return strlen(text) <= limit ? text : nullptr;
}
void notify(FlMethodChannel* channel, const char* method, FlValue* value) {
  fl_method_channel_invoke_method(channel, method, value, nullptr, nullptr, nullptr);
}
std::string config_path(const char* leaf) {
  return std::string(g_get_user_config_dir()) + "/" + leaf;
}
bool write_private(const std::string& path, const char* text, size_t length) {
  g_autofree char* directory = g_path_get_dirname(path.c_str());
  if (g_mkdir_with_parents(directory, 0700) != 0) return false;
  // GLib's own temporary file is "<name>.XXXXXX", which passes NAME_MAX for a long save name.
  g_autofree char* temporary = g_build_filename(directory, ".elarni-XXXXXX", nullptr);
  const int file = g_mkstemp_full(temporary, O_WRONLY, 0600);
  if (file < 0) return false;
  bool written = true;
  for (size_t done = 0; written && done < length;) {
    const ssize_t count = write(file, text + done, length - done);
    if (count < 0 && errno == EINTR) continue;
    written = count > 0;
    if (written) done += count;
  }
  written = fsync(file) == 0 && written;
  written = close(file) == 0 && written;
  if (written && g_rename(temporary, path.c_str()) == 0) return true;
  g_unlink(temporary);
  return false;
}
std::string executable() {
  g_autofree char* path = g_file_read_link("/proc/self/exe", nullptr);
  std::string result = path ? path : "";
  // An upgrade renames the next release over the running binary; the kernel then
  // reports "<path> (deleted)", while the installed path is what later runs need.
  const std::string deleted = " (deleted)";
  if (result.size() > deleted.size() &&
      result.compare(result.size() - deleted.size(), deleted.size(), deleted) == 0 &&
      !g_file_test(result.c_str(), G_FILE_TEST_EXISTS))
    result.resize(result.size() - deleted.size());
  return result;
}
// What a later login starts. An AppImage runs from a mount that is gone after exit, so
// that is the image file; APPDIR must hold this binary, so an AppImage that merely
// launched Elarni is not taken.
std::string launcher() {
  std::string binary = executable();
  const char* image = g_getenv("APPIMAGE");
  const char* mount = g_getenv("APPDIR");
  if (image && mount && g_path_is_absolute(image) && g_file_test(image, G_FILE_TEST_IS_REGULAR) &&
      g_str_has_prefix(binary.c_str(), (std::string(mount) + "/").c_str()))
    return image;
  return binary;
}
std::string desktop_exec(const std::string& path) {
  std::string quoted = "\"";
  for (char ch : path) {
    if (ch == '"' || ch == '\\' || ch == '`' || ch == '$') quoted += '\\';
    if (ch == '%') quoted += '%';
    quoted += ch;
  }
  return quoted + "\"";
}
FlValue* system_info() {
  auto* value = fl_value_new_map();
  struct utsname name{};
  uname(&name);
  struct sysinfo info{};
  sysinfo(&info);
  fl_value_set_string_take(value, "os", fl_value_new_string("Linux"));
  fl_value_set_string_take(value, "architecture", fl_value_new_string(name.machine));
  fl_value_set_string_take(value, "processorCount", fl_value_new_int(sysconf(_SC_NPROCESSORS_CONF)));
  fl_value_set_string_take(value, "activeProcessorCount", fl_value_new_int(sysconf(_SC_NPROCESSORS_ONLN)));
  fl_value_set_string_take(value, "physicalMemoryBytes", fl_value_new_int(static_cast<int64_t>(info.totalram) * info.mem_unit));
  g_autoptr(GKeyFile) entry = g_key_file_new();
  bool enabled = g_key_file_load_from_file(entry, config_path("autostart/com.elarni.Elarni.desktop").c_str(), G_KEY_FILE_NONE, nullptr)
      && !g_key_file_get_boolean(entry, "Desktop Entry", "Hidden", nullptr);
  // As on Windows, an entry for a moved or replaced copy does not start this one.
  g_autofree char* exec = enabled ? g_key_file_get_string(entry, "Desktop Entry", "Exec", nullptr) : nullptr;
  enabled = exec && desktop_exec(launcher()) == exec;
  fl_value_set_string_take(value, "launchAtLoginStatus", fl_value_new_string(enabled ? "enabled" : "notRegistered"));
  return value;
}
void stop_camera(DesktopHost* host) {
  if (host->camera) gst_element_set_state(host->camera, GST_STATE_NULL);
  if (host->frames) gst_object_unref(host->frames);
  if (host->camera) gst_object_unref(host->camera);
  host->frames = nullptr;
  host->camera = nullptr;
}
void camera_frame(DesktopHost* host, FlMethodCall* call) {
  if (!host->camera) {
    g_autoptr(GError) error = nullptr;
    host->camera = gst_parse_launch(
        "decodebin name=decode ! videoconvert ! videoscale ! video/x-raw,width=640,height=480 "
        "! jpegenc ! appsink name=frames max-buffers=1 drop=true sync=false", &error);
    if (error || !host->camera) { stop_camera(host); fail(call, "camera_unavailable"); return; }
    // autovideosrc falls back to synthetic color bars when no camera opens.
    // Select an actual device, including cameras whose path is not /dev/video0.
    g_autoptr(GstDeviceMonitor) monitor = gst_device_monitor_new();
    g_autoptr(GstCaps) caps = gst_caps_from_string("video/x-raw;image/jpeg");
    gst_device_monitor_add_filter(monitor, "Video/Source", caps);
    GList* devices = gst_device_monitor_get_devices(monitor);
    GstElement* source = nullptr;
    for (GList* item = devices; item && !source; item = item->next) {
      auto* candidate = gst_device_create_element(GST_DEVICE(item->data), "camera");
      if (!candidate) continue;
      if (gst_element_set_state(candidate, GST_STATE_READY) != GST_STATE_CHANGE_FAILURE) source = candidate;
      else { gst_element_set_state(candidate, GST_STATE_NULL); gst_object_unref(candidate); }
    }
    g_list_free_full(devices, gst_object_unref);
    if (!source) { stop_camera(host); fail(call, "camera_unavailable"); return; }
    if (!gst_bin_add(GST_BIN(host->camera), source)) {
      gst_element_set_state(source, GST_STATE_NULL); gst_object_unref(source);
      stop_camera(host); fail(call, "camera_unavailable"); return;
    }
    g_autoptr(GstElement) decoder = gst_bin_get_by_name(GST_BIN(host->camera), "decode");
    if (!decoder || !gst_element_link(source, decoder)) { stop_camera(host); fail(call, "camera_unavailable"); return; }
    host->frames = gst_bin_get_by_name(GST_BIN(host->camera), "frames");
    if (!host->frames || gst_element_set_state(host->camera, GST_STATE_PLAYING) == GST_STATE_CHANGE_FAILURE) {
      stop_camera(host); fail(call, "camera_unavailable"); return;
    }
  }
  GstBus* bus = gst_element_get_bus(host->camera);
  GstMessage* error = gst_bus_pop_filtered(bus, static_cast<GstMessageType>(GST_MESSAGE_ERROR | GST_MESSAGE_EOS));
  gst_object_unref(bus);
  if (error) { gst_message_unref(error); stop_camera(host); fail(call, "camera_unavailable"); return; }
  GstSample* sample = gst_app_sink_try_pull_sample(GST_APP_SINK(host->frames), 0);
  if (!sample) { success(call); return; }
  GstBuffer* buffer = gst_sample_get_buffer(sample);
  GstMapInfo map{};
  if (!buffer || !gst_buffer_map(buffer, &map, GST_MAP_READ)) {
    gst_sample_unref(sample); stop_camera(host); fail(call, "camera_unavailable"); return;
  }
  if (map.size == 0 || map.size > 8 * 1024 * 1024) {
    fail(call, "camera_unavailable");
  } else {
    g_autoptr(FlValue) value = fl_value_new_uint8_list(map.data, map.size);
    success(call, value);
  }
  gst_buffer_unmap(buffer, &map);
  gst_sample_unref(sample);
}
bool version_name(const std::string& name) {
  return !name.empty() && name.find_first_not_of("0123456789.") == std::string::npos && name.find('.') != std::string::npos &&
         name.front() != '.' && name.back() != '.' && name.find("..") == std::string::npos;
}
// The rule for a running or listed executable, and the app's name when the rule is a folder. Snap
// apps run from /snap/<name>/<revision>/, which each refresh replaces, so they match /snap/<name>/.
// Apps that keep each version beside the previous one, such as Claude Code
// (~/.local/share/claude/versions/<version>), match that folder of versions when it holds nothing
// else: the nearest version among the file and its four parents.
std::string application_rule(const std::string& path, std::string& name) {
  if (path.compare(0, 6, "/snap/") == 0) {
    const auto snap = path.find('/', 6);
    const auto revision_end = snap == std::string::npos ? snap : path.find('/', snap + 1);
    if (snap == std::string::npos || snap == 6 || revision_end == std::string::npos) return path;
    auto revision = path.substr(snap + 1, revision_end - snap - 1);
    if (!revision.empty() && revision[0] == 'x') revision.erase(0, 1);
    if (revision.empty() || revision.find_first_not_of("0123456789") != std::string::npos) return path;
    name = path.substr(6, snap - 6);
    return path.substr(0, snap + 1);
  }
  size_t end = path.size();
  for (int level = 0; level < 5 && end != std::string::npos && end > 0; ++level) {
    const auto start = path.rfind('/', end - 1);
    if (start == std::string::npos) return path;
    if (!version_name(path.substr(start + 1, end - start - 1))) { end = start; continue; }
    const auto root = path.substr(0, start);
    // At least two folders deep, so a version never widens to /opt/.
    if (std::count(root.begin(), root.end(), '/') < 2) return path;
    GDir* folder = g_dir_open(root.c_str(), 0, nullptr);
    if (!folder) return path;
    bool versions = true;
    while (const char* entry = g_dir_read_name(folder)) versions = versions && (entry[0] == '.' || version_name(entry));
    g_dir_close(folder);
    if (!versions) return path;
    g_autofree char* base = g_path_get_basename(root.c_str());
    g_autofree char* owner = g_path_get_dirname(root.c_str());
    g_autofree char* owner_name = g_path_get_basename(owner);
    name = strcmp(base, "versions") == 0 ? owner_name : base;
    return root + "/";
  }
  return path;
}
// Running and listed apps get a rule that follows updates; a saved rule is listed as saved.
void add_app(FlValue* list, std::set<std::string>& seen, const char* name, const char* process, GIcon* icon = nullptr,
             bool follow_updates = false) {
  g_autofree char* canonical = process ? realpath(process, nullptr) : nullptr;
  if (!canonical || !*canonical || strlen(canonical) > 1024 || !g_utf8_validate(canonical, -1, nullptr)) return;
  std::string rule_name;
  const std::string rule = follow_updates ? application_rule(canonical, rule_name) : canonical;
  if (!seen.insert(rule).second || seen.size() > 4096) return;
  g_autofree char* base = g_path_get_basename(canonical);
  auto* item = fl_value_new_map();
  fl_value_set_string_take(item, "name", fl_value_new_string(name && *name ? name : !rule_name.empty() ? rule_name.c_str() : base));
  fl_value_set_string_take(item, "process", fl_value_new_string(rule.c_str()));
  process = canonical;
  // Installed desktop entries provide their own artwork. For custom binaries,
  // use the file's native icon; failure simply leaves Flutter's app fallback.
  g_autoptr(GFile) file = g_file_new_for_path(process);
  g_autoptr(GFileInfo) file_info = icon ? nullptr : g_file_query_info(file,
      G_FILE_ATTRIBUTE_STANDARD_ICON, G_FILE_QUERY_INFO_NONE, nullptr, nullptr);
  if (!icon && file_info) icon = g_file_info_get_icon(file_info);
  g_autoptr(GtkIconInfo) icon_info = icon && gdk_screen_get_default() ? gtk_icon_theme_lookup_by_gicon(
      gtk_icon_theme_get_default(), icon, 64, GTK_ICON_LOOKUP_FORCE_SIZE) : nullptr;
  g_autoptr(GdkPixbuf) pixbuf = icon_info ? gtk_icon_info_load_icon(icon_info, nullptr) : nullptr;
  if (pixbuf) {
    g_autofree gchar* png = nullptr;
    gsize length = 0;
    if (gdk_pixbuf_save_to_buffer(pixbuf, &png, &length, "png", nullptr, nullptr) && length <= 65536) {
      fl_value_set_string_take(item, "iconPng", fl_value_new_uint8_list(
          reinterpret_cast<const uint8_t*>(png), length));
    }
  }
  fl_value_append_take(list, item);
}
// Snap, Flatpak, env and script entries name a launcher that is never the
// running process image, so a rule for them would silently match nothing.
// Running instances of those apps are still listed from /proc below.
bool launcher(const char* path) {
  g_autofree char* real = path ? realpath(path, nullptr) : nullptr;
  if (!real) return false;
  g_autofree char* name = g_path_get_basename(real);
  for (const char* known : {"env", "flatpak", "snap"}) if (strcmp(name, known) == 0) return true;
  char head[2] = {};
  FILE* file = fopen(real, "rb");
  if (!file) return false;
  bool script = fread(head, 1, 2, file) == 2 && head[0] == '#' && head[1] == '!';
  fclose(file);
  return script;
}
// A file chosen in the picker must be the image the app runs as.
const char* chosen_application_error(const char* path) {
  if (strlen(path) > 1024 || !g_file_test(path, G_FILE_TEST_IS_REGULAR) || !g_file_test(path, G_FILE_TEST_IS_EXECUTABLE))
    return "invalid_applications";
  return launcher(path) ? "launcher_application" : nullptr;
}
FlValue* applications(FlValue* args) {
  auto* list = fl_value_new_list();
  std::set<std::string> seen;
  GList* apps = g_app_info_get_all();
  for (GList* item = apps; item; item = item->next) {
    auto* app = G_APP_INFO(item->data);
    if (!g_app_info_should_show(app)) continue;
    const char* command = g_app_info_get_executable(app);
    g_autofree char* resolved = command ? g_find_program_in_path(command) : nullptr;
    // "Exec=sh -c ..." and "Exec=firejail app" name a wrapper, not the app.
    g_autofree char* real = resolved ? realpath(resolved, nullptr) : nullptr;
    g_autofree char* base = real ? g_path_get_basename(real) : nullptr;
    bool wrapper = false;
    for (const char* known : {"sh", "bash", "dash", "zsh", "firejail"}) wrapper = wrapper || (base && strcmp(base, known) == 0);
    if (wrapper || launcher(resolved)) continue;
    add_app(list, seen, g_app_info_get_display_name(app), resolved, g_app_info_get_icon(app), true);
  }
  g_list_free_full(apps, g_object_unref);
  g_autoptr(GDir) proc = g_dir_open("/proc", 0, nullptr);
  if (proc) while (const char* pid = g_dir_read_name(proc)) {
    if (strspn(pid, "0123456789") != strlen(pid)) continue;
    std::string path = std::string("/proc/") + pid + "/exe";
    g_autofree char* binary = g_file_read_link(path.c_str(), nullptr);
    if (!binary || !g_file_test(binary, G_FILE_TEST_IS_EXECUTABLE)) continue;
    add_app(list, seen, nullptr, binary, nullptr, true);
  }
  auto* selected = field(args, "processes", FL_VALUE_TYPE_LIST);
  if (selected && fl_value_get_length(selected) <= 256) {
    for (size_t index = 0; index < fl_value_get_length(selected); ++index) {
      auto* value = fl_value_get_list_value(selected, index);
      if (fl_value_get_type(value) != FL_VALUE_TYPE_STRING) continue;
      const char* path = fl_value_get_string(value);
      if (!g_path_is_absolute(path) || strlen(path) > 1024 || !g_utf8_validate(path, -1, nullptr)) continue;
      g_autofree char* name = g_path_get_basename(path);
      // A rule saved for one version, even one an update removed, is offered the rule that
      // follows updates.
      std::string rule_name;
      const auto suggested = application_rule(path, rule_name);
      if (suggested != path && seen.insert(path).second) {
        auto* item = fl_value_new_map();
        fl_value_set_string_take(item, "name", fl_value_new_string(rule_name.empty() ? name : rule_name.c_str()));
        fl_value_set_string_take(item, "process", fl_value_new_string(path));
        fl_value_set_string_take(item, "suggested", fl_value_new_string(suggested.c_str()));
        fl_value_append_take(list, item);
        continue;
      }
      if (!g_file_test(path, G_FILE_TEST_IS_REGULAR) || !g_file_test(path, G_FILE_TEST_IS_EXECUTABLE)) continue;
      add_app(list, seen, name, path);
    }
  }
  return list;
}
void picker(DesktopHost* host, FlMethodCall* call, bool apps) {
  auto* args = fl_method_call_get_args(call);
  bool save_backup = strcmp(fl_method_call_get_name(call), "saveBackup") == 0;
  bool save_evidence = strcmp(fl_method_call_get_name(call), "saveEvidence") == 0;
  bool save_logs = strcmp(fl_method_call_get_name(call), "saveLogs") == 0;
  // The recording ZIP can be large, so Dart copies it to the chosen path.
  bool save_recording = strcmp(fl_method_call_get_name(call), "pickRecordingPath") == 0;
  bool save = save_backup || save_evidence || save_logs || save_recording;
  const char* content = save && !save_recording ? text_field(args, "content", save_backup ? 12 * 1024 * 1024 : save_logs ? 4 * 1024 * 1024 : 512 * 1024) : nullptr;
  if (save && !save_recording && (!content || !*content)) { fail(call, save_backup ? "backup_failed" : "diagnostics_failed"); return; }
  GtkWidget* dialog = gtk_file_chooser_dialog_new(save ? localized("Save Elarni file", "Сохранить файл Elarni")
      : apps ? localized("Select applications", "Выберите приложения") : localized("Import file", "Импорт файла"),
      host->window, save ? GTK_FILE_CHOOSER_ACTION_SAVE : GTK_FILE_CHOOSER_ACTION_OPEN,
      localized("_Cancel", "_Отмена"), GTK_RESPONSE_CANCEL,
      save ? localized("_Save", "_Сохранить") : localized("_Open", "_Открыть"), GTK_RESPONSE_ACCEPT, nullptr);
  gtk_dialog_set_default_response(GTK_DIALOG(dialog), GTK_RESPONSE_ACCEPT);
  auto* chooser = GTK_FILE_CHOOSER(dialog);
  gtk_file_chooser_set_local_only(chooser, TRUE);
  gtk_file_chooser_set_select_multiple(chooser, apps);
  if (save) {
    gtk_file_chooser_set_do_overwrite_confirmation(chooser, TRUE);
    gtk_file_chooser_set_current_name(chooser, save_backup ? "elarni-backup.json" : save_logs ? "elarni-log.txt" : save_recording ? "elarni-recording.zip" : "elarni-diagnostics.json");
  } else if (!apps) {
    auto* image = field(args, "image", FL_VALUE_TYPE_BOOL);
    auto* backup = field(args, "backup", FL_VALUE_TYPE_BOOL);
    auto* filter = gtk_file_filter_new();
    if (image && fl_value_get_bool(image)) {
      gtk_file_filter_set_name(filter, localized("QR images", "Изображения QR"));
      for (const char* mime : {"image/png", "image/jpeg", "image/gif"}) gtk_file_filter_add_mime_type(filter, mime);
    } else {
      gtk_file_filter_set_name(filter, localized("Elarni profiles", "Профили Elarni"));
      gtk_file_filter_add_pattern(filter, "*.json");
      if (!backup || !fl_value_get_bool(backup))
        for (const char* pattern : {"*.yaml", "*.yml", "*.txt", "*.conf"}) gtk_file_filter_add_pattern(filter, pattern);
    }
    gtk_file_chooser_add_filter(chooser, filter);
    auto* all = gtk_file_filter_new();
    gtk_file_filter_set_name(all, localized("All files", "Все файлы"));
    gtk_file_filter_add_pattern(all, "*");
    gtk_file_chooser_add_filter(chooser, all);
  }
  int response = gtk_dialog_run(GTK_DIALOG(dialog));
  g_autoptr(FlValue) result = apps ? fl_value_new_list() : fl_value_new_map();
  const char* error = nullptr;
  if (response == GTK_RESPONSE_ACCEPT) {
    if (apps) {
      GSList* files = gtk_file_chooser_get_filenames(chooser);
      std::set<std::string> seen;
      if (g_slist_length(files) > 256) error = "invalid_applications";
      for (GSList* item = files; item && !error; item = item->next) {
        const char* path = static_cast<char*>(item->data);
        if ((error = chosen_application_error(path))) break;
        add_app(result, seen, nullptr, path, nullptr, true);
      }
      g_slist_free_full(files, g_free);
    } else {
      g_autofree char* path = gtk_file_chooser_get_filename(chooser);
      if (!path) error = "picker_failed";
      else if (save_recording) fl_value_set_string_take(result, "path", fl_value_new_string(path));
      else if (save) {
        if (!write_private(path, content, strlen(content))) error = save_backup ? "backup_failed" : "diagnostics_failed";
      } else fl_value_set_string_take(result, "path", fl_value_new_string(path));
    }
  } else if (save) error = "cancelled";
  gtk_widget_destroy(dialog);
  if (error) fail(call, error); else success(call, result);
}
void tray_action(GtkMenuItem* item, gpointer data) {
  auto* host = static_cast<DesktopHost*>(data);
  if (GTK_WIDGET(item) == host->connect || GTK_WIDGET(item) == host->disconnect) {
    g_autoptr(FlValue) action = fl_value_new_string(GTK_WIDGET(item) == host->connect ? "connect" : "disconnect");
    notify(host->desktop, "action", action);
  } else if (g_object_get_data(G_OBJECT(item), "quit")) {
    // Closing the window sends Dart the exit request, which restores the system proxy.
    gtk_window_close(host->window);
  } else gtk_window_present(host->window);
}
void desktop_call(FlMethodChannel*, FlMethodCall* call, gpointer data) {
  auto* host = static_cast<DesktopHost*>(data);
  const std::string method = fl_method_call_get_name(call);
  auto* args = fl_method_call_get_args(call);
  if (method == "routingApplications") {
    g_autoptr(FlValue) value = applications(args); success(call, value);
  } else if (method == "pickRoutingApplications") picker(host, call, true);
  else if (method == "getPreferences") {
    std::string path = config_path("Elarni/preferences.json");
    GStatBuf file_stat{};
    if (g_stat(path.c_str(), &file_stat) != 0 && errno == ENOENT) {
      g_autoptr(FlValue) empty = fl_value_new_string("{}"); success(call, empty); return;
    }
    g_autofree char* contents = nullptr;
    gsize length = 0;
    if (file_stat.st_size > 32768 || !g_file_get_contents(path.c_str(), &contents, &length, nullptr)
        || length > 32768 || !g_utf8_validate(contents, length, nullptr)) { fail(call, "preferences_failed"); return; }
    g_autoptr(FlValue) value = fl_value_new_string(contents); success(call, value);
  } else if (method == "setPreferences") {
    const char* json = text_field(args, "json", 32768);
    if (!json || !write_private(config_path("Elarni/preferences.json"), json, strlen(json))) fail(call, "preferences_failed");
    else success(call);
  } else if (method == "requestNotifications") {
    g_autoptr(FlValue) value = fl_value_new_bool(true); success(call, value);
  } else if (method == "showExpiryReminder") {
    auto* count = field(args, "count", FL_VALUE_TYPE_INT);
    if (!count || fl_value_get_int(count) < 1 || fl_value_get_int(count) > 1024) { fail(call, "invalid_request"); return; }
    g_autoptr(GNotification) notification = g_notification_new(localized("Elarni subscription expiry", "Срок подписок Elarni"));
    const char* russian[] = {" подписка скоро закончится. Откройте Elarni, чтобы проверить.",
        " подписки скоро закончатся. Откройте Elarni, чтобы проверить.", " подписок скоро закончатся. Откройте Elarni, чтобы проверить."};
    std::string body = std::to_string(fl_value_get_int(count)) +
        localized(" subscriptions expire soon. Open Elarni to review them.", russian[russian_plural_form(fl_value_get_int(count))]);
    g_notification_set_body(notification, body.c_str());
    g_application_send_notification(G_APPLICATION(host->app), "subscription-expiry", notification);
    success(call);
  } else if (method == "setStatus") {
    const char* state = text_field(args, "state", 32);
    if (!state || !*state || strspn(state, "abcdefghijklmnopqrstuvwxyz, ") != strlen(state)) { fail(call, "invalid_request"); return; }
    auto* connect = field(args, "canConnect", FL_VALUE_TYPE_BOOL);
    auto* disconnect = field(args, "canDisconnect", FL_VALUE_TYPE_BOOL);
    gtk_widget_set_sensitive(host->connect, connect && fl_value_get_bool(connect));
    gtk_widget_set_sensitive(host->disconnect, disconnect && fl_value_get_bool(disconnect));
    if (const char* language = text_field(args, "language", 8)) {
      chosen_russian = strcmp(language, "ru") == 0;
      g_autoptr(GList) items = gtk_container_get_children(GTK_CONTAINER(host->menu));
      for (int index = 0; index < 4; ++index)
        gtk_menu_item_set_label(GTK_MENU_ITEM(g_list_nth_data(items, index + 2)), tray_label(index));
    }
    std::string title = std::string("Elarni - ") + tray_state(state);
    app_indicator_set_title(host->indicator, title.c_str());
    app_indicator_set_icon_full(host->indicator, host->icon.c_str(), title.c_str());
    // Most status-icon hosts show neither title; the menu's first line does, as on Windows.
    gtk_menu_item_set_label(GTK_MENU_ITEM(host->state), title.c_str());
    success(call);
  } else fl_method_call_respond_not_implemented(call, nullptr);
}
void platform_call(FlMethodChannel*, FlMethodCall* call, gpointer data) {
  auto* host = static_cast<DesktopHost*>(data);
  const std::string method = fl_method_call_get_name(call);
  auto* args = fl_method_call_get_args(call);
  if (!args || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) { fail(call, "invalid_request"); return; }
  if (method == "takeLinks") {
    g_autoptr(FlValue) result = fl_value_new_map();
    auto* links = fl_value_new_list();
    for (const auto& link : host->links) fl_value_append_take(links, fl_value_new_string(link.c_str()));
    host->links.clear();
    fl_value_set_string_take(result, "links", links); success(call, result);
  } else if (method == "cameraFrame") camera_frame(host, call);
  else if (method == "cameraStop") { stop_camera(host); success(call); }
  else if (method == "pickFile" || method == "saveBackup" || method == "saveEvidence" || method == "saveLogs" || method == "pickRecordingPath") picker(host, call, false);
  else if (method == "systemInfo") { g_autoptr(FlValue) info = system_info(); success(call, info); }
  else if (method == "setLaunchAtLogin") {
    auto* enabled = field(args, "enabled", FL_VALUE_TYPE_BOOL);
    if (!enabled) { fail(call, "invalid_settings"); return; }
    std::string path = config_path("autostart/com.elarni.Elarni.desktop");
    if (fl_value_get_bool(enabled)) {
      std::string binary = launcher();
      if (binary.empty() || binary.find_first_of("\r\n") != std::string::npos) { fail(call, "login_registration_failed"); return; }
      g_autoptr(GKeyFile) entry = g_key_file_new();
      g_key_file_set_string(entry, "Desktop Entry", "Type", "Application");
      g_key_file_set_string(entry, "Desktop Entry", "Name", "Elarni");
      g_key_file_set_string(entry, "Desktop Entry", "Exec", desktop_exec(binary).c_str());
      g_key_file_set_string(entry, "Desktop Entry", "Icon", APPLICATION_ID);
      g_autofree char* contents = g_key_file_to_data(entry, nullptr, nullptr);
      if (!write_private(path, contents, strlen(contents))) { fail(call, "login_registration_failed"); return; }
    } else if (g_unlink(path.c_str()) != 0 && errno != ENOENT) { fail(call, "login_registration_failed"); return; }
    g_autoptr(FlValue) info = system_info(); success(call, info);
  } else if (method == "openURL") {
    const char* url = text_field(args, "url", 16384);
    if (!url || strpbrk(url, "\r\n\t") || !(g_str_has_prefix(url, "http://") || g_str_has_prefix(url, "https://") || g_str_has_prefix(url, "tg://proxy?"))) { fail(call, "invalid_url"); return; }
    if (!gtk_show_uri_on_window(host->window, url, GDK_CURRENT_TIME, nullptr)) fail(call, "open_failed");
    else { g_autoptr(FlValue) result = fl_value_new_map(); success(call, result); }
  } else if (method == "routeTable") {
    // Fixed argv only; the helper never receives a profile or credentials.
    std::string table;
    // Debian keeps ip in /usr/sbin, Arch in /usr/bin, NixOS elsewhere.
    const char* ip = "/usr/sbin/ip";
    for (const char* candidate : {"/usr/sbin/ip", "/usr/bin/ip", "/sbin/ip", "/run/current-system/sw/bin/ip"}) {
      if (g_file_test(candidate, G_FILE_TEST_IS_EXECUTABLE)) { ip = candidate; break; }
    }
    for (const char* family : {"-4", "-6"}) {
      g_autoptr(GSubprocess) process = g_subprocess_new(static_cast<GSubprocessFlags>(G_SUBPROCESS_FLAGS_STDOUT_PIPE | G_SUBPROCESS_FLAGS_STDERR_SILENCE),
          nullptr, ip, family, "route", "show", "table", "all", nullptr);
      g_autofree char* output = nullptr;
      if (!process || !g_subprocess_communicate_utf8(process, nullptr, nullptr, &output, nullptr, nullptr)
          || !g_subprocess_get_successful(process) || !output || strlen(output) + table.size() > 512 * 1024) { fail(call, "diagnostics_failed"); return; }
      table += output;
    }
    g_autoptr(FlValue) result = fl_value_new_map();
    fl_value_set_string_take(result, "table", fl_value_new_string(table.c_str()));
    fl_value_set_string_take(result, "timestamp", fl_value_new_float(g_get_real_time() / 1000000.0));
    success(call, result);
  } else fl_method_call_respond_not_implemented(call, nullptr);
}
void sleep_changed(GDBusConnection*, const gchar*, const gchar*, const gchar*, const gchar*, GVariant* parameters, gpointer data) {
  auto* host = static_cast<DesktopHost*>(data);
  gboolean sleeping = false;
  g_variant_get(parameters, "(b)", &sleeping);
  if (sleeping) stop_camera(host);
  g_autoptr(FlValue) value = fl_value_new_bool(sleeping);
  notify(host->platform, "sleepChanged", value);
}
void quit_action(GSimpleAction*, GVariant*, gpointer data) {
  gtk_window_close(static_cast<DesktopHost*>(data)->window);
}
void settings_action(GSimpleAction*, GVariant*, gpointer data) {
  auto* host = static_cast<DesktopHost*>(data);
  gtk_window_present(host->window);
  g_autoptr(FlValue) action = fl_value_new_string("settings");
  notify(host->desktop, "action", action);
}
}  // namespace

DesktopHost* desktop_host_new(GtkApplication* app, GtkWindow* window, FlView* view) {
  auto* host = new DesktopHost{};
  host->app = app;
  host->window = window;
  gst_init(nullptr, nullptr);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  auto* messenger = fl_engine_get_binary_messenger(fl_view_get_engine(view));
  host->desktop = fl_method_channel_new(messenger, "com.elarni/desktop", FL_METHOD_CODEC(codec));
  host->platform = fl_method_channel_new(messenger, "com.elarni/linux", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(host->desktop, desktop_call, host, nullptr);
  fl_method_channel_set_method_call_handler(host->platform, platform_call, host, nullptr);
  g_autofree char* directory = g_path_get_dirname(executable().c_str());
  host->icon = std::string(directory) + "/data/elarni.png";
  gtk_window_set_icon_from_file(window, host->icon.c_str(), nullptr);
  host->indicator = app_indicator_new(APPLICATION_ID, host->icon.c_str(), APP_INDICATOR_CATEGORY_APPLICATION_STATUS);
  host->menu = gtk_menu_new();
  g_object_ref_sink(host->menu);
  host->state = gtk_menu_item_new_with_label("Elarni");
  gtk_widget_set_sensitive(host->state, FALSE);
  gtk_menu_shell_append(GTK_MENU_SHELL(host->menu), host->state);
  gtk_menu_shell_append(GTK_MENU_SHELL(host->menu), gtk_separator_menu_item_new());
  for (int index = 0; index < 4; ++index) {
    auto* item = gtk_menu_item_new_with_label(tray_label(index));
    gtk_menu_shell_append(GTK_MENU_SHELL(host->menu), item);
    if (index == 1) host->connect = item;
    if (index == 2) host->disconnect = item;
    if (index == 3) g_object_set_data(G_OBJECT(item), "quit", GINT_TO_POINTER(1));
    g_signal_connect(item, "activate", G_CALLBACK(tray_action), host);
  }
  gtk_widget_set_sensitive(host->connect, FALSE);
  gtk_widget_set_sensitive(host->disconnect, FALSE);
  gtk_widget_show_all(host->menu);
  app_indicator_set_menu(host->indicator, GTK_MENU(host->menu));
  app_indicator_set_status(host->indicator, APP_INDICATOR_STATUS_ACTIVE);
  // Ctrl+Q and Ctrl+, as macOS has Quit and Settings in its app menu.
  for (auto entry : {std::make_pair("quit", G_CALLBACK(quit_action)), std::make_pair("preferences", G_CALLBACK(settings_action))}) {
    g_autoptr(GSimpleAction) action = g_simple_action_new(entry.first, nullptr);
    g_signal_connect(action, "activate", entry.second, host);
    g_action_map_add_action(G_ACTION_MAP(app), G_ACTION(action));
  }
  const char* quit[] = {"<Primary>q", nullptr};
  const char* preferences[] = {"<Primary>comma", nullptr};
  gtk_application_set_accels_for_action(app, "app.quit", quit);
  gtk_application_set_accels_for_action(app, "app.preferences", preferences);
  host->system_bus = g_bus_get_sync(G_BUS_TYPE_SYSTEM, nullptr, nullptr);
  if (host->system_bus) host->sleep_subscription = g_dbus_connection_signal_subscribe(host->system_bus,
      "org.freedesktop.login1", "org.freedesktop.login1.Manager", "PrepareForSleep", "/org/freedesktop/login1",
      nullptr, G_DBUS_SIGNAL_FLAGS_NONE, sleep_changed, host, nullptr);
  return host;
}
void desktop_host_links(DesktopHost* host, char** arguments) {
  if (!host) return;
  for (char** item = arguments; item && *item; ++item) {
    size_t length = strlen(*item);
    if (length == 0 || length > 4 * 1024 * 1024 || !g_utf8_validate(*item, length, nullptr)) continue;
    if (host->links.size() == 16) host->links.erase(host->links.begin());
    host->links.emplace_back(*item);
  }
  if (!host->links.empty()) notify(host->platform, "linksAvailable", nullptr);
}
void desktop_host_free(DesktopHost* host) {
  if (!host) return;
  stop_camera(host);
  g_action_map_remove_action(G_ACTION_MAP(host->app), "quit");
  g_action_map_remove_action(G_ACTION_MAP(host->app), "preferences");
  if (host->sleep_subscription) g_dbus_connection_signal_unsubscribe(host->system_bus, host->sleep_subscription);
  g_clear_object(&host->system_bus);
  app_indicator_set_status(host->indicator, APP_INDICATOR_STATUS_PASSIVE);
  g_clear_object(&host->indicator);
  gtk_widget_destroy(host->menu);
  g_clear_object(&host->menu);
  fl_method_channel_set_method_call_handler(host->desktop, nullptr, nullptr, nullptr);
  fl_method_channel_set_method_call_handler(host->platform, nullptr, nullptr, nullptr);
  g_clear_object(&host->desktop);
  g_clear_object(&host->platform);
  delete host;
}
