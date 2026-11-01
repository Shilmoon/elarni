#pragma once

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

// Owned by the application, on GTK's main thread.
struct DesktopHost;
DesktopHost* desktop_host_new(GtkApplication* app, GtkWindow* window, FlView* view);
void desktop_host_links(DesktopHost* host, char** arguments);
void desktop_host_free(DesktopHost* host);
