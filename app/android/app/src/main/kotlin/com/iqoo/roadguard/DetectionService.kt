package com.iqoo.roadguard

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.PowerManager
import android.util.Log
import java.io.File
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.lifecycle.LifecycleService

/**
 * Runs the road scan while Drive Mode is on: camera + on-device models, with the screen on or off.
 * Started from Drive Mode (RoadGuardBridge.start) and stopped when Drive Mode ends.
 */
class DetectionService : LifecycleService() {
    private var runner: CameraRunner? = null
    private var demo: DemoRunner? = null
    private var video: VideoRunner? = null
    private var stream: StreamRunner? = null
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        super.onStartCommand(intent, flags, startId)
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }
        if (intent?.action == ACTION_TEST_CAPTURE) {
            Log.i("RoadGuard", "test capture started=${Hub.pipeline?.testHiRes() == true}")
            return START_NOT_STICKY
        }
        getSystemService(NotificationManager::class.java)
            .createNotificationChannel(NotificationChannel(CHANNEL, "Drive Mode road scan", NotificationManager.IMPORTANCE_LOW))
        val launch = packageManager.getLaunchIntentForPackage(packageName)
        val open = PendingIntent.getActivity(this, 0, launch, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val notification: Notification = NotificationCompat.Builder(this, CHANNEL)
            .setContentTitle("Drive Mode is scanning the road")
            .setContentText("Potholes and violations are detected on this phone only")
            .setSmallIcon(android.R.drawable.ic_menu_camera)
            .setContentIntent(open)
            .setOngoing(true)
            .build()
        ServiceCompat.startForeground(
            this, NOTIFICATION_ID, notification,
            ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA or ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION,
        )
        Hub.start(this)
        Hub.beginSession()
        Hub.pipeline?.ai?.enabled = intent?.getBooleanExtra("ai", false) == true
        val demoDir = intent?.getStringExtra("demoDir")
        val videos = intent?.getStringArrayListExtra("videos")
        val streamUrl = intent?.getStringExtra("stream")
        if (!streamUrl.isNullOrBlank()) {
            // A live dashcam stream, in place of the camera.
            if (stream == null) stream = StreamRunner(streamUrl)
        } else if (!videos.isNullOrEmpty()) {
            // Video clips the person picked, scanned in place of the camera.
            if (video == null) video = VideoRunner(this, ClipReader.sources(this, videos))
        } else if (demoDir != null) {
            // Test feed (lab build only): frames from a folder instead of the camera.
            if (demo == null) demo = DemoRunner(File(demoDir))
        } else if (runner == null) {
            runner = CameraRunner(this).also { it.start(this, null) }
        }
        val pm = getSystemService(POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "connect:roadscan").apply { acquire(4 * 60 * 60 * 1000L) }
        running = true
        // A killed camera service must not silently restart without the user in the car.
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        running = false
        runner?.stop()
        runner = null
        demo?.stop()
        demo = null
        video?.stop()
        video = null
        stream?.stop()
        stream = null
        wakeLock?.let { if (it.isHeld) it.release() }
        Hub.stop()
        super.onDestroy()
    }

    companion object {
        const val CHANNEL = "roadscan"
        const val NOTIFICATION_ID = 4107
        const val ACTION_STOP = "com.iqoo.roadguard.STOP"
        const val ACTION_TEST_CAPTURE = "com.iqoo.roadguard.TEST_CAPTURE"

        @Volatile
        var running = false
    }
}
