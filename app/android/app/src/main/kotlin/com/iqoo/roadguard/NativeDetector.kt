package com.iqoo.roadguard

import android.content.Context
import android.content.res.AssetManager
import android.graphics.Bitmap
import android.graphics.RectF

data class Detection(val box: RectF, val score: Float, val cls: Int)

data class FrameResult(
    val detections: List<Detection>,
    val frameW: Int,
    val frameH: Int,
    val preMs: Float,
    val inferMs: Float,
    val postMs: Float,
    val maxScore: Float = 0f,
)

/**
 * One YOLOv8 model on ncnn. [useGpu] runs it on the Adreno GPU through Vulkan; otherwise it runs
 * on the CPU (big cores). Several instances can run concurrently on different threads.
 */
class NativeDetector(
    context: Context,
    paramAsset: String,
    binAsset: String,
    private val inputSize: Int,
    numClasses: Int,
    val useGpu: Boolean,
    threads: Int = 4,
    var confThreshold: Float = 0.35f,
    private val allowedClasses: IntArray? = null,
) {
    private var handle: Long = 0
    val info: String
    val ok: Boolean get() = handle != 0L

    private val timings = FloatArray(4)

    init {
        handle = nativeCreate(
            context.assets, paramAsset, binAsset, inputSize, numClasses, useGpu, threads, true,
        )
        info = nativeInfo()
    }

    @Synchronized
    fun detect(frame: Bitmap): FrameResult? {
        val raw = nativeDetect(handle, frame, confThreshold, allowedClasses, timings) ?: return null
        val dets = ArrayList<Detection>(raw.size / 6)
        var i = 0
        while (i + 5 < raw.size) {
            dets.add(Detection(RectF(raw[i], raw[i + 1], raw[i + 2], raw[i + 3]), raw[i + 4], raw[i + 5].toInt()))
            i += 6
        }
        return FrameResult(dets, frame.width, frame.height, timings[0], timings[1], timings[2], timings[3])
    }

    @Synchronized
    fun close() {
        nativeRelease(handle)
        handle = 0
    }

    private external fun nativeCreate(
        assets: AssetManager, param: String, bin: String, inputSize: Int, numClasses: Int,
        useVulkan: Boolean, threads: Int, bigCoresOnly: Boolean,
    ): Long

    private external fun nativeInfo(): String
    private external fun nativeDetect(
        handle: Long, bitmap: Bitmap, conf: Float, allowed: IntArray?, timings: FloatArray,
    ): FloatArray?

    private external fun nativeRelease(handle: Long)

    companion object {
        init {
            System.loadLibrary("roadguard_native")
        }
    }
}
