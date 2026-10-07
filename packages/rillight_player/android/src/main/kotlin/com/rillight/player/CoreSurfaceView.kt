package com.rillight.player

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.view.Gravity
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import java.nio.ByteBuffer
import kotlin.math.roundToInt

/** Hybrid-composed native layer: HDR decoder buffers never enter an SDR texture. */
internal class CoreSurfaceView(context: Context, private val owner: SurfaceOwner) : FrameLayout(context),
    SurfaceHolder.Callback {
    private val video = SurfaceView(context)
    private val subtitles = SubtitlePlane(context)
    private var widthPx = 0
    private var heightPx = 0
    private var sarNum = 1
    private var sarDen = 1
    private var rotation = 0
    private var fill = false
    private var displayedRect = android.graphics.Rect()

    init {
        setBackgroundColor(Color.BLACK)
        isFocusable = false
        isFocusableInTouchMode = false
        descendantFocusability = ViewGroup.FOCUS_BLOCK_DESCENDANTS
        video.isFocusable = false
        video.isFocusableInTouchMode = false
        video.holder.addCallback(this)
        addView(video, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT, Gravity.CENTER))
        addView(subtitles, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
    }

    fun scale(mode: String?) { fill = mode == "fill"; updateGeometry() }

    fun frame(width: Int, height: Int, numerator: Int, denominator: Int, degrees: Int) {
        if (width == widthPx && height == heightPx && numerator == sarNum &&
            denominator == sarDen && degrees == rotation) return
        widthPx = width; heightPx = height
        sarNum = numerator.takeIf { it > 0 } ?: 1
        sarDen = denominator.takeIf { it > 0 } ?: 1
        rotation = degrees
        updateGeometry()
    }

    fun sourceRect(): android.graphics.Rect {
        val location = IntArray(2); getLocationOnScreen(location)
        return android.graphics.Rect(displayedRect).apply { offset(location[0], location[1]) }
    }
    fun overlay(plane: CoreVideoOverlay) { subtitles.update(plane) }
    fun clearOverlay() { subtitles.clear() }

    private fun updateGeometry() {
        if (width <= 0 || height <= 0 || widthPx <= 0 || heightPx <= 0) return
        val pixelWidth = widthPx.toFloat() * sarNum / sarDen
        val effectiveWidth = if (rotation % 180 == 0) pixelWidth else heightPx.toFloat()
        val effectiveHeight = if (rotation % 180 == 0) heightPx.toFloat() else pixelWidth
        val factor = if (fill) maxOf(width / effectiveWidth, height / effectiveHeight)
                     else minOf(width / effectiveWidth, height / effectiveHeight)
        val visibleWidth = minOf(width.toFloat(), effectiveWidth * factor)
        val visibleHeight = minOf(height.toFloat(), effectiveHeight * factor)
        displayedRect.set(((width - visibleWidth) / 2).roundToInt(), ((height - visibleHeight) / 2).roundToInt(),
            ((width + visibleWidth) / 2).roundToInt(), ((height + visibleHeight) / 2).roundToInt())
        val desiredWidth = (pixelWidth * factor).roundToInt().coerceAtLeast(1)
        val desiredHeight = (heightPx * factor).roundToInt().coerceAtLeast(1)
        val params = video.layoutParams as LayoutParams
        if (params.width != desiredWidth || params.height != desiredHeight) {
            params.width = desiredWidth; params.height = desiredHeight
            video.layoutParams = params
        }
        video.rotation = rotation.toFloat()
        subtitles.destination = RectF((width - desiredWidth) / 2f, (height - desiredHeight) / 2f,
            (width + desiredWidth) / 2f, (height + desiredHeight) / 2f)
        subtitles.rotation = rotation.toFloat()
        subtitles.invalidate()
        val margins = subtitleCropMargins(desiredWidth, desiredHeight, width, height, rotation)
        owner.videoGeometry(mapOf("width" to desiredWidth, "height" to desiredHeight,
            "contentWidth" to effectiveWidth, "contentHeight" to effectiveHeight,
            "visibleWidth" to minOf(width.toFloat(), effectiveWidth * factor),
            "visibleHeight" to minOf(height.toFloat(), effectiveHeight * factor),
            "safeHorizontal" to margins.first,
            "safeVertical" to margins.second,
            "rotation" to rotation, "sarNum" to sarNum, "sarDen" to sarDen,
            "density" to resources.displayMetrics.density))
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        owner.setViewport(w, h)
        updateGeometry()
    }
    override fun surfaceCreated(holder: SurfaceHolder) { owner.setSurface(holder.surface) }
    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) = Unit
    override fun surfaceDestroyed(holder: SurfaceHolder) { owner.setSurface(null); clearOverlay() }

    fun detach(clearOwner: Boolean = true) {
        if (clearOwner) owner.setSurface(null)
        video.holder.removeCallback(this)
        clearOverlay()
    }

    private class SubtitlePlane(context: Context) : View(context) {
        var destination = RectF()
        private val paint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)
        private var bitmap: Bitmap? = null
        private var plane: CoreVideoOverlay? = null
        fun update(next: CoreVideoOverlay) {
            if (next.bytes.isEmpty()) { clear(); return }
            var image = bitmap
            if (image == null || image.width != next.width || image.height != next.height) {
                image = Bitmap.createBitmap(next.width, next.height, Bitmap.Config.ARGB_8888)
                bitmap = image
            }
            image.copyPixelsFromBuffer(ByteBuffer.wrap(next.bytes))
            plane = next
            invalidate()
        }
        // RenderThread may still reference the previous display list. Let its
        // retained bitmap finish naturally instead of recycling under a draw.
        fun clear() { bitmap = null; plane = null; invalidate() }
        override fun onDraw(canvas: Canvas) {
            val p = plane ?: return
            val image = bitmap ?: return
            if (p.videoWidth <= 0 || p.videoHeight <= 0) return
            val sx = destination.width() / p.videoWidth
            val sy = destination.height() / p.videoHeight
            canvas.drawBitmap(image, null, RectF(destination.left + p.x * sx,
                destination.top + p.y * sy, destination.left + (p.x + p.width) * sx,
                destination.top + (p.y + p.height) * sy), paint)
        }
    }
}

internal interface SurfaceOwner {
    fun videoGeometry(value: Map<String, Any>)
    fun setSurface(surface: Surface?)
    fun setViewport(width: Int, height: Int)
}
