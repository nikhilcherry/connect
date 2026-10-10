package app.connectcar.connect

import android.Manifest
import android.content.pm.PackageManager
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.view.WindowManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.iqoo.roadguard.RoadGuardBridge
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    // Outputs other than the phone's own speaker. A frame sent by sound is meant for the air
    // around the phone; it must never be turned up into someone's headphones or car stereo.
    private val external = setOf(
        AudioDeviceInfo.TYPE_WIRED_HEADSET, AudioDeviceInfo.TYPE_WIRED_HEADPHONES, AudioDeviceInfo.TYPE_USB_HEADSET,
        AudioDeviceInfo.TYPE_USB_DEVICE, AudioDeviceInfo.TYPE_BLUETOOTH_A2DP, AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
        AudioDeviceInfo.TYPE_BLE_HEADSET, AudioDeviceInfo.TYPE_BLE_SPEAKER, AudioDeviceInfo.TYPE_HEARING_AID,
        AudioDeviceInfo.TYPE_HDMI, AudioDeviceInfo.TYPE_LINE_ANALOG,
    )

    // Drive Mode's road scan (potholes, triple riding, no helmet). Everything runs on the phone.
    private var pendingRoadStart: MethodChannel.Result? = null
    private var pendingRoadDemoDir: String? = null
    private var pendingRoadAi = false

    private fun roadPermissions(): List<String> = buildList {
        add(Manifest.permission.CAMERA)
        add(Manifest.permission.ACCESS_FINE_LOCATION)
        if (Build.VERSION.SDK_INT >= 33) add(Manifest.permission.POST_NOTIFICATIONS)
    }

    private fun startRoadScan(demoDir: String?, ai: Boolean, result: MethodChannel.Result) {
        if (!RoadGuardBridge.available()) {
            result.success(false)
            return
        }
        val missing = roadPermissions().filter { ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED }
        if (missing.isEmpty()) {
            result.success(RoadGuardBridge.start(this, demoDir, ai))
            return
        }
        if (pendingRoadStart != null) {
            result.success(false)
            return
        }
        pendingRoadStart = result
        pendingRoadDemoDir = demoDir
        pendingRoadAi = ai
        ActivityCompat.requestPermissions(this, missing.toTypedArray(), ROAD_PERMISSION_REQUEST)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != ROAD_PERMISSION_REQUEST) return
        val r = pendingRoadStart ?: return
        pendingRoadStart = null
        // Camera is required; location (for map pins) and notifications are optional.
        val cameraOk = ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED
        r.success(cameraOk && RoadGuardBridge.start(this, pendingRoadDemoDir, pendingRoadAi))
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "connect/roadguard").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "available" -> result.success(RoadGuardBridge.available())
                    "start" -> startRoadScan(call.argument<String>("demoDir"), call.argument<Boolean>("ai") == true, result)
                    "aiAvailable" -> result.success(RoadGuardBridge.aiAvailable())
                    "preview" -> result.success(RoadGuardBridge.preview())
                    "stop" -> {
                        RoadGuardBridge.stop(this)
                        result.success(null)
                    }
                    "status" -> result.success(RoadGuardBridge.status())
                    "events" -> result.success(RoadGuardBridge.events(this, (call.arguments as? Number)?.toLong() ?: 0L))
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("roadguard", e.message, null)
            }
        }
        val audio = getSystemService(AudioManager::class.java)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "connect/device").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    // The sound link (lib/services/sound_link.dart) borrows the media volume for the
                    // two seconds a frame lasts and hands it back. Answers with the level to restore,
                    // or null when it changed nothing.
                    "borrowVolume" -> {
                        val max = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
                        val want = Math.round(max * ((call.arguments as? Double) ?: 1.0)).toInt().coerceIn(1, max)
                        val cur = audio.getStreamVolume(AudioManager.STREAM_MUSIC)
                        val attached = audio.getDevices(AudioManager.GET_DEVICES_OUTPUTS).any { it.type in external }
                        if (attached || cur >= want) {
                            result.success(null)
                        } else {
                            audio.setStreamVolume(AudioManager.STREAM_MUSIC, want, 0)
                            result.success(cur)
                        }
                    }
                    "restoreVolume" -> {
                        (call.arguments as? Int)?.let { audio.setStreamVolume(AudioManager.STREAM_MUSIC, it, 0) }
                        result.success(null)
                    }
                    // Witness mode watches through the camera, which stops when the screen sleeps.
                    "keepAwake" -> {
                        if (call.arguments == true) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("device", e.message, null)
            }
        }
    }

    companion object {
        private const val ROAD_PERMISSION_REQUEST = 7710
    }
}
