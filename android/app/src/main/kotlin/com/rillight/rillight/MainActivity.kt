package com.rillight.rillight

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.android.RenderMode
import android.app.UiModeManager
import android.content.Context
import android.content.pm.PackageManager
import android.content.res.Configuration
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun onUserLeaveHint() {
        com.rillight.player.RillightCorePlayerPlugin.userLeave(this)
        super.onUserLeaveHint()
    }
    override fun onPictureInPictureModeChanged(active: Boolean, configuration: Configuration) {
        com.rillight.player.RillightCorePlayerPlugin.pipMode(this, active)
        super.onPictureInPictureModeChanged(active, configuration)
    }
    override fun onPictureInPictureUiStateChanged(state: android.app.PictureInPictureUiState) {
        super.onPictureInPictureUiStateChanged(state)
        if (android.os.Build.VERSION.SDK_INT >= 35 && state.isTransitioningToPip)
            com.rillight.player.RillightCorePlayerPlugin.pipTransition(this)
    }
    // The owned core's platform view and Flutter overlays share an Activity.
    // Keep Flutter in a TextureView across route teardown and screen lock so
    // surface transitions do not switch the Activity's rendering target.
    override fun getRenderMode(): RenderMode = RenderMode.texture

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.rillight/environment")
            .setMethodCallHandler { call, result ->
                if (call.method == "nightMode") {
                    // 外观「跟随系统」需要区分「明确浅色」与「无偏好」:
                    // 引擎把 NIGHT_UNDEFINED 也上报为浅色,这里给原始 NIGHT 掩码。
                    try {
                        val night = resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK
                        result.success(
                            when (night) {
                                Configuration.UI_MODE_NIGHT_YES -> "yes"
                                Configuration.UI_MODE_NIGHT_NO -> "no"
                                else -> "undefined"
                            }
                        )
                    } catch (_: Exception) {
                        result.error("appearance_detection", "Unable to read night mode", null)
                    }
                    return@setMethodCallHandler
                }
                if (call.method != "isTelevision") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                try {
                    val mode = getSystemService(Context.UI_MODE_SERVICE) as UiModeManager
                    result.success(
                        mode.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION ||
                            packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK)
                    )
                } catch (_: Exception) {
                    result.error("device_detection", "Unable to identify device type", null)
                }
            }
    }
}
