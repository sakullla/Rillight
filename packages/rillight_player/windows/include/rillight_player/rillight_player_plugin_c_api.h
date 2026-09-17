#ifndef RILLIGHT_PLAYER_PLUGIN_C_API_H_
#define RILLIGHT_PLAYER_PLUGIN_C_API_H_
#include <flutter_plugin_registrar.h>
#ifdef FLUTTER_PLUGIN_IMPL
#define RILLIGHT_EXPORT __declspec(dllexport)
#else
#define RILLIGHT_EXPORT __declspec(dllimport)
#endif
#ifdef __cplusplus
extern "C" {
#endif
RILLIGHT_EXPORT void RillightPlayerPluginCApiRegisterWithRegistrar(FlutterDesktopPluginRegistrarRef registrar);
#ifdef __cplusplus
}
#endif
#endif
