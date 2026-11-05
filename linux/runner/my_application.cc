#include "my_application.h"
#include "desktop_host.h"
#include "flutter/generated_plugin_registrant.h"

#include <epoxy/egl.h>
#include <epoxy/gl.h>
#include <string.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif
#ifdef GDK_WINDOWING_WAYLAND
#include <gdk/gdkwayland.h>
#endif

struct _MyApplication {
  GtkApplication parent_instance;
  GtkWindow* window;
  DesktopHost* host;
};
G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Without a GPU (VMs, remote desktops, Xvfb) Mesa's llvmpipe or softpipe rasterizes Flutter's GL output on the
// CPU anyway, with its buffers in system memory. Flutter's own CPU renderer is cheaper there: on Xvfb at 1920x1080
// the window used 166 instead of 246 MB and a quarter of the CPU while repainting. The EGL display is the one
// Flutter's FlOpenGLManager opens next, so it is left initialized.
static bool software_gl() {
  GdkDisplay* display = gdk_display_get_default();
  EGLDisplay egl = EGL_NO_DISPLAY;
#ifdef GDK_WINDOWING_X11
  if (GDK_IS_X11_DISPLAY(display))
    egl = eglGetPlatformDisplayEXT(EGL_PLATFORM_X11_EXT, gdk_x11_display_get_xdisplay(display), nullptr);
#endif
#ifdef GDK_WINDOWING_WAYLAND
  if (GDK_IS_WAYLAND_DISPLAY(display))
    egl = eglGetPlatformDisplayEXT(EGL_PLATFORM_WAYLAND_EXT, gdk_wayland_display_get_wl_display(display), nullptr);
#endif
  if (egl == EGL_NO_DISPLAY || !eglInitialize(egl, nullptr, nullptr)) return false;
  const EGLint config_attributes[] = {EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_NONE};
  EGLConfig config = nullptr;
  EGLint configs = 0;
  if (!eglChooseConfig(egl, config_attributes, &config, 1, &configs) || configs == 0) return false;
  const EGLint context_attributes[] = {EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE};
  EGLContext context = eglCreateContext(egl, config, EGL_NO_CONTEXT, context_attributes);
  if (context == EGL_NO_CONTEXT) return false;
  bool software = false;
  if (eglMakeCurrent(egl, EGL_NO_SURFACE, EGL_NO_SURFACE, context)) {
    const char* renderer = reinterpret_cast<const char*>(glGetString(GL_RENDERER));
    software = renderer && (strncmp(renderer, "llvmpipe", 8) == 0 || strncmp(renderer, "softpipe", 8) == 0);
    eglMakeCurrent(egl, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
  }
  eglDestroyContext(egl, context);
  return software;
}

static void first_frame_cb(FlView* view, gpointer) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

static void my_application_activate(GApplication* application) {
  auto* self = MY_APPLICATION(application);
  if (self->window) { gtk_window_present(self->window); return; }
  self->window = GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(self)));
  gtk_window_set_title(self->window, "Elarni");
  gtk_window_set_default_size(self->window, 800, 600);
  gtk_window_set_icon_name(self->window, APPLICATION_ID);
  g_signal_connect_swapped(self->window, "destroy", G_CALLBACK(g_application_quit), self);
  g_autoptr(FlDartProject) project = fl_dart_project_new();
  // The engine reads the renderer choice when the view creates it; a user's own setting wins. Processes the app
  // starts later must not inherit the choice.
  bool chosen = !g_getenv("FLUTTER_LINUX_RENDERER") && software_gl();
  if (chosen) g_setenv("FLUTTER_LINUX_RENDERER", "software", TRUE);
  FlView* view = fl_view_new(project);
  if (chosen) g_unsetenv("FLUTTER_LINUX_RENDERER");
  GdkRGBA background;
  gdk_rgba_parse(&background, "#202124");
  fl_view_set_background_color(view, &background);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(self->window), GTK_WIDGET(view));
  g_signal_connect(view, "first-frame", G_CALLBACK(first_frame_cb), nullptr);
  gtk_widget_realize(GTK_WIDGET(view));
  fl_register_plugins(FL_PLUGIN_REGISTRY(view));
  self->host = desktop_host_new(GTK_APPLICATION(self), self->window, view);
  gtk_widget_grab_focus(GTK_WIDGET(view));
}

static int my_application_command_line(GApplication* application, GApplicationCommandLine* command) {
  auto* self = MY_APPLICATION(application);
  g_application_activate(application);
  g_auto(GStrv) args = g_application_command_line_get_arguments(command, nullptr);
  // A caller may exec with an empty argv, which leaves no program name to skip.
  desktop_host_links(self->host, args && args[0] ? args + 1 : nullptr);
  return 0;
}

static void my_application_shutdown(GApplication* application) {
  auto* self = MY_APPLICATION(application);
  desktop_host_free(self->host);
  self->host = nullptr;
  self->window = nullptr;
  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->command_line = my_application_command_line;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
}
static void my_application_init(MyApplication*) {}
MyApplication* my_application_new() {
  g_set_prgname(APPLICATION_ID);
  g_set_application_name("Elarni");
  return MY_APPLICATION(g_object_new(my_application_get_type(), "application-id", APPLICATION_ID,
                                    "flags", G_APPLICATION_HANDLES_COMMAND_LINE, nullptr));
}
