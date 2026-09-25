package com.rillight.player

import android.content.Context
import android.graphics.Matrix
import android.graphics.SurfaceTexture
import android.view.Surface
import android.view.TextureView
import android.view.ViewGroup
import android.widget.FrameLayout

/** Stable TextureView: Flutter keeps this mounted through loading transitions. */
internal class CoreSurfaceView(context: Context, private val owner: SurfaceOwner) : FrameLayout(context),
    TextureView.SurfaceTextureListener {
    private val texture = TextureView(context)
    private var surface: Surface? = null
    private var widthPx = 0
    private var heightPx = 0
    private var sarNum = 1
    private var sarDen = 1
    private var rotation = 0
    private var fill = false

    init {
        isFocusable = false
        isFocusableInTouchMode = false
        descendantFocusability = ViewGroup.FOCUS_BLOCK_DESCENDANTS
        texture.isFocusable = false
        texture.isFocusableInTouchMode = false
        texture.surfaceTextureListener = this
        addView(texture, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
    }

    fun scale(mode: String?) { fill = mode == "fill"; updateTransform() }

    fun frame(width: Int, height: Int, numerator: Int, denominator: Int, degrees: Int) {
        if (width == widthPx && height == heightPx && numerator == sarNum &&
            denominator == sarDen && degrees == rotation) return
        widthPx = width; heightPx = height
        sarNum = numerator.takeIf { it > 0 } ?: 1
        sarDen = denominator.takeIf { it > 0 } ?: 1
        rotation = degrees
        updateTransform()
    }

    private fun updateTransform() {
        val vw = texture.width.toFloat()
        val vh = texture.height.toFloat()
        if (vw <= 0 || vh <= 0 || widthPx <= 0 || heightPx <= 0) return
        val pixelWidth = widthPx.toFloat() * sarNum / sarDen
        val effectiveWidth = if (rotation % 180 == 0) pixelWidth else heightPx.toFloat()
        val effectiveHeight = if (rotation % 180 == 0) heightPx.toFloat() else pixelWidth
        val factor = if (fill) maxOf(vw / effectiveWidth, vh / effectiveHeight)
                     else minOf(vw / effectiveWidth, vh / effectiveHeight)
        val desiredWidth = pixelWidth * factor
        val desiredHeight = heightPx * factor
        val matrix = Matrix()
        // TextureView's default mapping stretches the buffer to the view.
        matrix.setScale(desiredWidth / vw, desiredHeight / vh, vw / 2f, vh / 2f)
        if (rotation != 0) matrix.postRotate(rotation.toFloat(), vw / 2f, vh / 2f)
        texture.setTransform(matrix)
    }

    override fun onSurfaceTextureAvailable(source: SurfaceTexture, width: Int, height: Int) {
        surface = Surface(source).also(owner::setSurface)
        updateTransform()
    }
    override fun onSurfaceTextureSizeChanged(source: SurfaceTexture, width: Int, height: Int) {
        updateTransform()
    }
    override fun onSurfaceTextureDestroyed(source: SurfaceTexture): Boolean {
        if (surface != null) owner.setSurface(null)
        surface?.release(); surface = null
        return true
    }
    override fun onSurfaceTextureUpdated(source: SurfaceTexture) = Unit

    fun detach(clearOwner: Boolean = true) {
        // A retired PlatformView may be disposed after its replacement mounted.
        if (clearOwner) owner.setSurface(null)
        surface?.release(); surface = null
        texture.surfaceTextureListener = null
    }
}

internal interface SurfaceOwner { fun setSurface(surface: Surface?) }
