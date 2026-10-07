package com.rillight.player

import android.content.Context
import android.content.res.AssetManager
import android.system.Os
import java.io.File
import java.io.IOException

/** Copies pinned enhancement weights out of the APK so the core can open them. */
internal object EnhancementFiles {
    private val required = listOf(
        "rife-v4.6/flownet.param" to 16749L,
        "rife-v4.6/flownet.bin" to 10614320L,
        "realesr-general-x4v3.param" to 5019L,
        "realesr-general-x4v3.bin" to 2435272L,
        "shaders/anime4k/Anime4K_Restore_CNN_M.glsl" to 36191L,
        "shaders/anime4k/Anime4K_Restore_CNN_VL.glsl" to 144948L,
        "shaders/anime4k/Anime4K_Upscale_CNN_x2_M.glsl" to 37985L,
        "shaders/anime4k/Anime4K_Upscale_CNN_x2_VL.glsl" to 147712L,
    )

    fun install(context: Context) {
        val destination = File(context.filesDir, "enhancement")
        if (!weightsMatch(destination)) {
            try {
                copyTree(context.assets, "enhancement", destination)
            } catch (_: IOException) {
                // Missing packaged weights leave enhancement inactive.
            }
        }
        if (weightsMatch(destination))
            Os.setenv("RILLIGHT_ENHANCEMENT_DIR", destination.absolutePath, true)
    }

    private fun weightsMatch(root: File): Boolean {
        return required.all { (relative, bytes) ->
            val file = File(root, relative)
            file.isFile && file.length() == bytes
        }
    }

    private fun copyTree(assets: AssetManager, assetPath: String, dest: File) {
        val children = assets.list(assetPath) ?: throw IOException(assetPath)
        if (children.isEmpty()) {
            dest.parentFile?.mkdirs()
            val partial = File(dest.parentFile, dest.name + ".partial")
            assets.open(assetPath).use { input ->
                partial.outputStream().use { output -> input.copyTo(output) }
            }
            if (dest.exists() && !dest.delete())
                throw IOException(dest.path)
            if (!partial.renameTo(dest)) throw IOException(dest.path)
            return
        }
        if (!dest.isDirectory && !dest.mkdirs()) throw IOException(dest.path)
        for (child in children)
            copyTree(assets, "$assetPath/$child", File(dest, child))
    }
}
