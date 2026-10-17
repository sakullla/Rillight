package com.rillight.rillight

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.Executors

/** No package replacement or permissions are granted here: Android owns both. */
class UpdateInstaller(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "com.rillight/updates")
    private val worker = Executors.newSingleThreadExecutor()
    private var pending: MethodChannel.Result? = null
    private var disposed = false

    init { channel.setMethodCallHandler(::handle) }

    private fun reply(result: MethodChannel.Result, status: String, failure: String? = null) {
        result.success(mapOf("status" to status, "failure" to failure))
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "capabilities" -> result.success(mapOf("abis" to Build.SUPPORTED_ABIS.toList()))
            "requestInstallPermission" -> {
                if (Build.VERSION.SDK_INT < 26 || activity.packageManager.canRequestPackageInstalls()) {
                    reply(result, "handedOff")
                } else {
                    try {
                        activity.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                            Uri.parse("package:${activity.packageName}")))
                        reply(result, "handedOff")
                    } catch (_: ActivityNotFoundException) {
                        reply(result, "failed", "unavailable")
                    } catch (_: SecurityException) {
                        reply(result, "failed", "permissionDenied")
                    }
                }
            }
            "install" -> install(call, result)
            else -> result.notImplemented()
        }
    }

    private fun install(call: MethodCall, result: MethodChannel.Result) {
        if (pending != null) { reply(result, "failed", "systemFailure"); return }
        val path = call.argument<String>("path")
        val name = call.argument<String>("name")
        val hash = call.argument<String>("sha256")
        val length = call.argument<Number>("length")?.toLong()
        if (path == null || name == null || hash == null || length == null) {
            reply(result, "failed", "invalidFile"); return
        }
        pending = result
        worker.execute {
            var failure: String? = null
            var file: File? = null
            try {
                val root = File(activity.cacheDir, "rillight-updates").canonicalFile
                val candidate = File(path)
                val canonical = candidate.canonicalFile
                val session = canonical.parentFile
                // Allow Android's cache-directory aliases, but not a symlinked
                // package or a canonical path outside this application's cache.
                if (candidate.name != canonical.name ||
                    candidate.parentFile?.canonicalFile != canonical.parentFile || !canonical.isFile ||
                    session == null || session.parentFile != root || !session.name.startsWith("session-") ||
                    canonical.name != name || !name.endsWith(".apk") || length <= 0 ||
                    canonical.length() != length || !Regex("[0-9a-f]{64}").matches(hash) ||
                    sha256(canonical) != hash) {
                    failure = "invalidFile"
                } else if (!compatible(canonical)) {
                    failure = "incompatiblePackage"
                } else {
                    file = canonical
                }
            } catch (_: Exception) { failure = "invalidFile" }
            activity.runOnUiThread {
                if (disposed || pending !== result) return@runOnUiThread
                if (failure != null || file == null) {
                    pending = null
                    reply(result, "failed", failure ?: "invalidFile")
                } else if (Build.VERSION.SDK_INT >= 26 && !activity.packageManager.canRequestPackageInstalls()) {
                    pending = null
                    reply(result, "permissionRequired", "permissionDenied")
                } else {
                    try {
                        val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.updates", file)
                        @Suppress("DEPRECATION")
                        val intent = Intent(Intent.ACTION_INSTALL_PACKAGE).apply {
                            setDataAndType(uri, "application/vnd.android.package-archive")
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            clipData = ClipData.newRawUri("Update package", uri)
                            putExtra(Intent.EXTRA_RETURN_RESULT, true)
                        }
                        // The callback distinguishes cancellation/failure. Even RESULT_OK
                        // is only a completed system handoff, never an app success banner.
                        @Suppress("DEPRECATION")
                        activity.startActivityForResult(intent, INSTALL_REQUEST)
                    } catch (_: ActivityNotFoundException) {
                        pending = null; reply(result, "failed", "unavailable")
                    } catch (_: SecurityException) {
                        pending = null; reply(result, "failed", "permissionDenied")
                    } catch (_: Exception) {
                        pending = null; reply(result, "failed", "systemFailure")
                    }
                }
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun compatible(file: File): Boolean {
        val pm = activity.packageManager
        val flags = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES
        val archive = pm.getPackageArchiveInfo(file.path, flags) ?: return false
        val current = pm.getPackageInfo(activity.packageName, flags)
        if (archive.packageName != activity.packageName ||
            (archive.applicationInfo?.minSdkVersion ?: Int.MAX_VALUE) > Build.VERSION.SDK_INT ||
            version(archive) <= version(current)) return false
        if (Build.VERSION.SDK_INT >= 28) {
            val installed = current.signingInfo ?: return false
            val incoming = archive.signingInfo ?: return false
            val old = installed.apkContentsSigners.toSet()
            val next = incoming.apkContentsSigners.toSet()
            if (old.isEmpty() || next.isEmpty()) return false
            if (installed.hasMultipleSigners() || incoming.hasMultipleSigners()) return old == next
            // Allow forward signing-key rotation proven by APK signing lineage.
            return incoming.signingCertificateHistory?.toSet()?.containsAll(old) == true
        }
        val old = current.signatures?.toSet() ?: return false
        return old.isNotEmpty() && old == archive.signatures?.toSet()
    }

    @Suppress("DEPRECATION")
    private fun version(info: PackageInfo): Long =
        if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()

    private fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it.toInt() and 0xff) }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != INSTALL_REQUEST) return false
        val result = pending ?: return true
        pending = null
        val installResult = data?.getIntExtra("android.intent.extra.INSTALL_RESULT", 0) ?: 0
        when {
            // PackageManager's legacy install result values accompany this
            // Activity API. Most failures (e.g. storage/I/O) are system failures,
            // not an assertion that the package has an incompatible identity.
            installResult == -115 -> reply(result, "cancelled") // INSTALL_FAILED_ABORTED
            installResult == -111 -> reply(result, "failed", "permissionDenied") // USER_RESTRICTED
            installResult in setOf(-2, -7, -9, -12, -14, -16, -17, -25, -26) ->
                reply(result, "failed", "incompatiblePackage")
            installResult < 0 -> reply(result, "failed", "systemFailure")
            resultCode == Activity.RESULT_OK -> reply(result, "handedOff")
            resultCode == Activity.RESULT_CANCELED -> reply(result, "cancelled")
            else -> reply(result, "failed", "systemFailure")
        }
        return true
    }

    fun dispose() {
        disposed = true
        channel.setMethodCallHandler(null)
        pending?.let { reply(it, "cancelled") }
        pending = null
        worker.shutdownNow()
    }

    companion object { private const val INSTALL_REQUEST = 0x5249 }
}
