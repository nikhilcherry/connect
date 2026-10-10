package com.iqoo.roadguard

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import java.io.ByteArrayOutputStream

/**
 * Draws the latest camera frame with what the models found on it, as a small JPEG for the Drive
 * Mode screen. Only runs when the screen asks (a few times a second), so it costs nothing otherwise.
 */
object PreviewRenderer {
    fun render(maxWidth: Int = 640): ByteArray? {
        val frame = Hub.lastFrame ?: return null
        val o = Hub.overlay
        val k = minOf(1f, maxWidth.toFloat() / frame.width)
        val w = maxOf(1, (frame.width * k).toInt())
        val h = maxOf(1, (frame.height * k).toInt())
        val out = Bitmap.createScaledBitmap(frame, w, h, true).copy(Bitmap.Config.ARGB_8888, true)
        val canvas = Canvas(out)

        fun paint(color: Int, width: Float) = Paint().apply {
            this.color = color
            style = Paint.Style.STROKE
            strokeWidth = width
        }
        val pothole = paint(Color.RED, 4f)
        val person = paint(Color.CYAN, 1.5f)
        val bike = paint(Color.YELLOW, 2.5f)
        val car = paint(Color.WHITE, 1.5f)
        val severe = paint(Color.rgb(255, 120, 0), 5f)
        val mild = paint(Color.rgb(255, 200, 0), 3f)
        val text = Paint().apply {
            color = Color.WHITE
            textSize = 22f
            setShadowLayer(3f, 0f, 0f, Color.BLACK)
        }

        if (o != null && o.frameW == frame.width && o.frameH == frame.height) {
            fun r(b: RectF) = RectF(b.left * k, b.top * k, b.right * k, b.bottom * k)
            for (d in o.vehicles) {
                val p = when (d.cls) {
                    Pipeline.PERSON -> person
                    Pipeline.MOTORCYCLE, Pipeline.BICYCLE -> bike
                    else -> car
                }
                canvas.drawRect(r(d.box), p)
            }
            for (d in o.potholes) {
                val b = r(d.box)
                canvas.drawRect(b, pothole)
                canvas.drawText("pothole %.2f".format(d.score), b.left, maxOf(22f, b.top - 6f), text)
            }
            for (f in o.flags) {
                val b = r(f.box)
                canvas.drawRect(b, if (f.severe) severe else mild)
                canvas.drawText(f.label, b.left, maxOf(22f, b.top - 6f), text)
            }
        }
        val bytes = ByteArrayOutputStream(40_000)
        out.compress(Bitmap.CompressFormat.JPEG, 72, bytes)
        out.recycle()
        return bytes.toByteArray()
    }
}
