package com.iqoo.roadguard

import android.content.Context
import android.content.Intent
import androidx.core.content.ContextCompat
import app.connectcar.connect.BuildConfig
import org.json.JSONObject
import java.io.File

/** Loads the native library once, on the main thread (see native_detector.cpp for why). */
object NativeRuntime {
    @Volatile
    private var state = 0 // 0 = not tried, 1 = ready, -1 = unavailable

    @Synchronized
    fun ensure(): Boolean {
        if (state == 0) {
            state = try {
                System.loadLibrary("roadguard_native")
                init()
                1
            } catch (_: Throwable) {
                -1
            }
        }
        return state == 1
    }

    private external fun init()
}

/** What the Flutter side (lib/services/roadguard.dart) talks to over the `connect/roadguard` channel. */
object RoadGuardBridge {
    fun available(): Boolean = NativeRuntime.ensure()

    /** True when this build has an OpenRouter key, so the AI second opinion can be offered. */
    fun aiAvailable(): Boolean = BuildConfig.OPENROUTER_API_KEY.isNotBlank()

    fun start(context: Context, demoDir: String? = null, ai: Boolean = false, videos: List<String>? = null): Boolean {
        if (!available()) return false
        val intent = Intent(context, DetectionService::class.java)
        if (demoDir != null) intent.putExtra("demoDir", demoDir)
        if (!videos.isNullOrEmpty()) intent.putStringArrayListExtra("videos", ArrayList(videos))
        intent.putExtra("ai", ai)
        ContextCompat.startForegroundService(context, intent)
        return true
    }

    /** The latest frame with the detections drawn on it, as a JPEG, or null before the first frame. */
    fun preview(): ByteArray? = PreviewRenderer.render()

    fun stop(context: Context) {
        context.stopService(Intent(context, DetectionService::class.java))
    }

    fun status(): Map<String, Any> {
        val p = Hub.pipeline
        val s = p?.stats
        val g = p?.governor
        val b = Hub.base
        return mapOf(
            "running" to DetectionService.running,
            "ready" to (p?.ready == true),
            "info" to (p?.loadInfo ?: ""),
            "fps" to Hub.fps.toDouble(),
            "thermal" to (g?.status ?: 0),
            "headroom" to (g?.headroom?.takeIf { !it.isNaN() }?.toDouble() ?: -1.0),
            "intervalMs" to (g?.minIntervalMs ?: 0L),
            "paused" to (g?.paused ?: false),
            "potholes" to ((s?.potholeEvents ?: 0) - b[0]),
            "violations" to ((s?.violations ?: 0) - b[1]),
            "triple" to ((s?.tripleEvents ?: 0) - b[2]),
            "noHelmet" to ((s?.noHelmetEvents ?: 0) - b[3]),
            "last" to (s?.lastEvent ?: "-"),
            "gps" to (p?.location?.last != null),
            "demo" to Hub.demoActive,
            "videoClip" to (Hub.video?.name ?: ""),
            "videoIndex" to (Hub.video?.index ?: 0),
            "videoCount" to (Hub.video?.count ?: 0),
            "videoDone" to Hub.videoDone,
            "aiOn" to (p?.ai?.enabled == true),
            "aiCalls" to (p?.ai?.calls ?: 0),
            "aiFail" to (p?.ai?.failures ?: 0),
            "aiCost" to (p?.ai?.costUsd ?: 0.0),
            "aiConfirms" to (s?.aiConfirms ?: 0),
            "aiVetoes" to (s?.aiVetoes ?: 0),
        )
    }

    /** Events saved at or after [sinceMs]: type, time, plate text, location and image paths. */
    fun events(context: Context, sinceMs: Long): List<Map<String, Any?>> {
        val root = File(context.getExternalFilesDir(null), "events")
        val log = File(root, "events.jsonl")
        if (!log.exists()) return emptyList()
        val out = ArrayList<Map<String, Any?>>()
        for (ln in log.readLines()) {
            try {
                val j = JSONObject(ln)
                if (j.optLong("timeMs") < sinceMs) continue
                val id = j.getString("id")
                out.add(
                    mapOf(
                        "id" to id,
                        "type" to j.getString("type"),
                        "timeMs" to j.optLong("timeMs"),
                        "imported" to j.optBoolean("imported"),
                        "occurredMs" to (if (j.has("occurredMs")) j.getLong("occurredMs") else null),
                        "clip" to j.optString("clip"),
                        "score" to j.optDouble("score"),
                        "plateText" to j.optString("plateText"),
                        "plateValid" to j.optBoolean("plateValid"),
                        "note" to j.optString("note"),
                        "plateHiRes" to j.optBoolean("plateHiRes"),
                        "vehiclePath" to if (j.optBoolean("vehicleSaved")) File(root, "$id/vehicle_hr.jpg").path else null,
                        "lat" to if (j.has("lat")) j.getDouble("lat") else null,
                        "lon" to if (j.has("lon")) j.getDouble("lon") else null,
                        "framePath" to File(root, "$id/frame.jpg").path,
                        "platePath" to if (j.optBoolean("plateSaved")) File(root, "$id/plate.jpg").path else null,
                    ),
                )
            } catch (_: Throwable) {
            }
        }
        return out
    }
}
