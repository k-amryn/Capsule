#include "my_application.h"
#include <stdlib.h>
#include <string>

int main(int argc, char** argv) {
  if (getenv("APPIMAGE")) {
    const char* old_path = getenv("PATH");
    if (old_path) {
      std::string new_path = std::string("/tmp/capsule_wrappers:") + old_path;
      setenv("PATH", new_path.c_str(), 1);
    } else {
      setenv("PATH", "/tmp/capsule_wrappers", 1);
    }
  }
  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
