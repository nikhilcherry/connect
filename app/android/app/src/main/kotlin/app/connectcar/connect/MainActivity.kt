package app.connectcar.connect

import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.view.WindowManager
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

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
}
