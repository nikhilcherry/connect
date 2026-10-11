package com.iqoo.roadguard

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.Base64
import android.util.Log
import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.net.URI
import kotlin.concurrent.thread

/** The state of a live dashcam stream, for the progress line in the app. */
class StreamProgress(val host: String, val state: String) // state: connecting | live | lost

/** A parsed `http://[user:pass@]host[:port]/path` address. */
class StreamTarget(val host: String, val port: Int, val path: String, val auth: String?) {
    companion object {
        /** Null when the address is not a plain http address. */
        fun parse(url: String): StreamTarget? = try {
            val u = URI(url.trim())
            if (u.scheme?.lowercase() != "http" || u.host.isNullOrBlank()) null
            else StreamTarget(
                u.host, if (u.port > 0) u.port else 80,
                (u.rawPath.takeUnless { it.isNullOrEmpty() } ?: "/") + (u.rawQuery?.let { "?$it" } ?: ""),
                u.rawUserInfo?.let { "Basic " + Base64.encodeToString(it.toByteArray(), Base64.NO_WRAP) },
            )
        } catch (_: Exception) {
            null
        }
    }
}

/**
 * Runs the road scan on a live dashcam stream (MJPEG over HTTP) in place of the phone's own camera. The
 * request is made over a plain socket: Android's cleartext rules apply to its HTTP clients, and a dashcam on its
 * own Wi-Fi speaks plain HTTP. The phone is in the car, so events take the phone's place and the time they are
 * seen, exactly as with the camera. If the stream drops, it reconnects until stopped.
 */
class StreamRunner(private val url: String) {
    @Volatile
    private var running = true

    @Volatile
    private var latest: ByteArray? = null

    @Volatile
    private var socketRef: Socket? = null

    private val target = StreamTarget.parse(url)
    private val lock = Object()

    init {
        Hub.stream = StreamProgress(target?.host ?: url, "connecting")
    }

    /** Reads frames off the network as fast as they come, keeping only the newest, so latency never builds up. */
    private val reader = thread(name = "stream-reader") {
        val t = target
        if (t == null) {
            Log.w("RoadGuard", "stream: not a plain http address: $url")
            Hub.stream = StreamProgress(url, "lost")
            return@thread
        }
        var delay = 1000L
        while (running) {
            var socket: Socket? = null
            try {
                Hub.stream = StreamProgress(t.host, "connecting")
                socket = Socket()
                socketRef = socket
                socket.connect(InetSocketAddress(t.host, t.port), 5000)
                socket.soTimeout = 8000
                socket.getOutputStream().apply {
                    val req = "GET ${t.path} HTTP/1.0\r\nHost: ${t.host}:${t.port}\r\nUser-Agent: connect-dashcam\r\nAccept: */*\r\n" +
                        (t.auth?.let { "Authorization: $it\r\n" } ?: "") + "Connection: close\r\n\r\n"
                    write(req.toByteArray())
                    flush()
                }
                val input: InputStream = BufferedInputStream(socket.getInputStream(), 64 * 1024)
                val head = readHead(input)
                val status = head.lineSequence().firstOrNull().orEmpty()
                if (!status.contains(" 200")) throw IllegalStateException("dashcam answered: $status")
                if (head.contains("chunked", ignoreCase = true)) throw IllegalStateException("chunked streams are not supported")
                Log.i("RoadGuard", "stream: connected to ${t.host}:${t.port}")
                delay = 1000L
                val n = MjpegReader.readFrames(input) { jpeg ->
                    if (Hub.stream?.state != "live") Hub.stream = StreamProgress(t.host, "live")
                    synchronized(lock) { latest = jpeg }
                    running
                }
                Log.i("RoadGuard", "stream ended after $n frames")
            } catch (e: Throwable) {
                if (running) Log.w("RoadGuard", "stream: $e")
            } finally {
                try { socket?.close() } catch (_: Throwable) {}
            }
            if (running) {
                Hub.stream = StreamProgress(t.host, "lost")
                try { Thread.sleep(delay) } catch (_: InterruptedException) {}
                delay = minOf(delay * 2, 8000L)
            }
        }
    }

    /** Takes the newest frame, when there is one, and runs the pipeline on it. */
    private val worker = thread(name = "stream-runner") {
        val pipeline = Hub.pipeline
        while (running && pipeline != null && !pipeline.ready) Thread.sleep(200)
        if (pipeline == null) return@thread
        var windowStart = System.nanoTime()
        var frames = 0
        while (running) {
            val jpeg = synchronized(lock) { latest.also { latest = null } }
            if (jpeg == null) {
                Thread.sleep(15)
                continue
            }
            val t0 = System.nanoTime()
            val bmp = decode(jpeg) ?: continue
            Hub.overlay = pipeline.process(bmp, System.currentTimeMillis())
            Hub.lastFrame = bmp
            frames++
            val now = System.nanoTime()
            if (now - windowStart >= 1_000_000_000L) {
                Hub.fps = frames * 1e9f / (now - windowStart)
                pipeline.governor.update(System.currentTimeMillis())
                val st = pipeline.stats
                Log.i(
                    "RoadGuard",
                    "stream fps=%.1f violations=%d | bikes=%d persons=%d bikeFrames=%d maxRiders=%d helmetChecks=%d helmet=%d noHelmet=%d ai[calls=%d]".format(
                        Hub.fps, st.violations, st.rawBikes, st.rawPersons, st.bikeFrames, st.maxRiders,
                        st.helmetChecks, st.helmetSeen, st.noHelmetSeen, pipeline.ai.calls,
                    ),
                )
                frames = 0
                windowStart = now
            }
            // Never faster than the models can use, and the thermal governor decides when to ease off.
            val spent = (now - t0) / 1_000_000
            if (spent < 50) Thread.sleep(50 - spent)
        }
    }

    /** At most 1280 px on the long side: the models look at 640 and the phone has plenty to do. */
    private fun decode(jpeg: ByteArray): Bitmap? {
        val opts = BitmapFactory.Options().apply { inPreferredConfig = Bitmap.Config.ARGB_8888 }
        val src = try {
            BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size, opts)
        } catch (_: Throwable) {
            null
        } ?: return null
        val k = minOf(1f, 1280f / maxOf(src.width, src.height))
        val scaled = if (k < 1f) Bitmap.createScaledBitmap(src, (src.width * k).toInt(), (src.height * k).toInt(), true) else src
        return if (scaled.isMutable) scaled else scaled.copy(Bitmap.Config.ARGB_8888, true)
    }

    private fun readHead(input: InputStream): String {
        val out = ByteArrayOutputStream()
        var last4 = 0
        while (out.size() < 16 * 1024) {
            val b = input.read()
            if (b < 0) break
            out.write(b)
            last4 = (last4 shl 8) or b
            if (last4 == 0x0D0A0D0A) break
        }
        return out.toString(Charsets.ISO_8859_1.name())
    }

    fun stop() {
        running = false
        Hub.stream = null
        try { socketRef?.close() } catch (_: Throwable) {} // unblocks a read that is waiting on the network
        try { reader.interrupt() } catch (_: Throwable) {}
        worker.join(3000)
        reader.join(1500)
    }
}
