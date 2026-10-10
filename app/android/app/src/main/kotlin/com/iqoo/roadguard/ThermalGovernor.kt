package com.iqoo.roadguard

import android.content.Context
import android.os.Build
import android.os.PowerManager

/**
 * Keeps the phone inside a safe thermal envelope while running as hard as it can. It reads the
 * system thermal status and forecast headroom (1.0 = throttling threshold) and sets the minimum
 * time between processed frames. When the phone is cool there is no limit at all.
 */
class ThermalGovernor(context: Context) {
    private val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager

    @Volatile var status = 0
        private set
    @Volatile var headroom = Float.NaN
        private set
    @Volatile var minIntervalMs = 0L
        private set
    @Volatile var paused = false
        private set

    /** 0 = full pipeline, 1 = skip helmet/plate extras, 2 = detection only at low rate. */
    @Volatile var level = 0
        private set

    private var lastPoll = 0L

    fun update(nowMs: Long) {
        if (nowMs - lastPoll < 2000) return
        lastPoll = nowMs
        status = if (Build.VERSION.SDK_INT >= 29) pm.currentThermalStatus else 0
        headroom = if (Build.VERSION.SDK_INT >= 30) pm.getThermalHeadroom(10) else Float.NaN

        val h = if (headroom.isNaN()) 0f else headroom
        paused = status >= PowerManager.THERMAL_STATUS_CRITICAL
        when {
            paused -> { minIntervalMs = 1000; level = 2 }
            status >= PowerManager.THERMAL_STATUS_SEVERE || h >= 0.97f -> { minIntervalMs = 200; level = 2 }
            h >= 0.88f || status >= PowerManager.THERMAL_STATUS_MODERATE -> { minIntervalMs = 100; level = 1 }
            h >= 0.75f -> { minIntervalMs = 66; level = 0 }
            else -> { minIntervalMs = 0; level = 0 }
        }
    }
}
