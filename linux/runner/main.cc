#include "my_application.h"

#ifdef GDK_WINDOWING_X11
#include <X11/Xlib.h>
#endif

int main(int argc, char** argv) {
#ifdef GDK_WINDOWING_X11
  // GTK, Flutter and the mpv render worker access Xlib concurrently. This must
  // precede GTK opening the display, not run later during plugin registration.
  if (!XInitThreads()) {
    g_printerr("Unable to initialize Xlib thread support\n");
    return 1;
  }
#endif
  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
