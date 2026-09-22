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
    // Hybrid PlayerView + Flutter overlays can leave the Impeller OpenGLES
    // surface context unavailable after route teardown and screen lock (12290).
    // Keep the Activity opaque and Impeller enabled, but host Flutter in a
    // TextureView so hybrid composition does not switch its SurfaceView target.
    override fun getRenderMode(): RenderMode = RenderMode.texture

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.rillight/environment")
            .setMethodCallHandler { call, result ->
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
