package com.iqoo.roadguard

import android.util.Base64
import app.connectcar.connect.BuildConfig
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

/** What the AI said about one cropped vehicle. */
class AiVerdict(val people: Int, val helmets: List<Boolean>, val confidence: Double) {
    /** At least one person visibly without a helmet. */
    val anyBareHead: Boolean get() = helmets.any { !it }
}

/**
 * Second opinion on a suspect vehicle: sends ONE tight crop of that vehicle to a vision model on
 * OpenRouter and gets back how many people are on it and who wears a helmet. Opt-in only (the app
 * otherwise keeps everything on the phone), rate-limited and capped per drive so a stuck loop can
 * never run up a bill. If the key is missing, the phone is offline or the cap is hit, the caller
 * simply keeps using the on-device rules.
 *
 * The key comes from BuildConfig (set from android/local.properties, which is git-ignored). A key
 * inside an APK can be extracted, so for anything beyond a demo put it behind a server (e.g. a
 * Supabase edge function) and cap the key's spend in the OpenRouter dashboard.
 */
class AiVerifier(private val apiKey: String = BuildConfig.OPENROUTER_API_KEY) {
    val available: Boolean get() = apiKey.isNotBlank()

    @Volatile var enabled = false

    private val callCount = AtomicInteger(0)
    private val failureCount = AtomicInteger(0)
    private val costMicro = AtomicLong(0) // millionths of a US dollar
    private val lastCallMs = AtomicLong(0)
    private val exec = Executors.newFixedThreadPool(2)

    val calls: Int get() = callCount.get()
    val failures: Int get() = failureCount.get()
    val costUsd: Double get() = costMicro.get() / 1_000_000.0

    var maxCallsPerDrive = 150
    var minGapMs = 1200L
    var model = "google/gemini-2.5-flash-lite"

    /** Queues one check. False means "not now" (disabled, capped, or too soon after the last one). */
    fun submit(jpeg: ByteArray, done: (AiVerdict?) -> Unit): Boolean {
        if (!enabled || !available || callCount.get() >= maxCallsPerDrive) return false
        val now = System.currentTimeMillis()
        val prev = lastCallMs.get()
        if (now - prev < minGapMs || !lastCallMs.compareAndSet(prev, now)) return false
        callCount.incrementAndGet()
        exec.execute {
            val v = try {
                request(jpeg)
            } catch (_: Throwable) {
                null
            }
            if (v == null) failureCount.incrementAndGet()
            done(v)
        }
        return true
    }

    fun close() = exec.shutdown()

    private fun request(jpeg: ByteArray): AiVerdict? {
        val image = "data:image/jpeg;base64," + Base64.encodeToString(jpeg, Base64.NO_WRAP)
        val body = JSONObject()
            .put("model", model)
            .put("temperature", 0)
            .put("max_tokens", 300)
            .put("usage", JSONObject().put("include", true))
            .put(
                "messages",
                JSONArray().put(
                    JSONObject().put("role", "user").put(
                        "content",
                        JSONArray()
                            .put(JSONObject().put("type", "text").put("text", PROMPT))
                            .put(JSONObject().put("type", "image_url").put("image_url", JSONObject().put("url", image))),
                    ),
                ),
            )
        val c = URL(URL_CHAT).openConnection() as HttpURLConnection
        try {
            c.requestMethod = "POST"
            c.connectTimeout = 8000
            c.readTimeout = 15000
            c.doOutput = true
            c.setRequestProperty("Authorization", "Bearer $apiKey")
            c.setRequestProperty("Content-Type", "application/json")
            c.setRequestProperty("X-Title", "Connect Drive Mode")
            c.outputStream.use { it.write(body.toString().toByteArray()) }
            if (c.responseCode !in 200..299) return null
            val resp = JSONObject(c.inputStream.bufferedReader().readText())
            resp.optJSONObject("usage")?.let { u ->
                // OpenRouter reports the real cost in credits (USD); fall back to a token estimate.
                val cost = if (u.has("cost")) u.optDouble("cost") else
                    u.optInt("prompt_tokens") * 0.10 / 1e6 + u.optInt("completion_tokens") * 0.40 / 1e6
                costMicro.addAndGet((cost * 1_000_000).toLong())
            }
            val text = resp.getJSONArray("choices").getJSONObject(0).getJSONObject("message").optString("content")
            val j = JSONObject(text.substring(text.indexOf('{'), text.lastIndexOf('}') + 1))
            if (!j.optBoolean("two_wheeler", true)) return AiVerdict(0, emptyList(), j.optDouble("confidence", 0.0))
            val hs = j.optJSONArray("helmets")
            val helmets = (0 until (hs?.length() ?: 0)).map { hs!!.optBoolean(it, true) }
            return AiVerdict(j.optInt("people", helmets.size), helmets, j.optDouble("confidence", 0.0))
        } finally {
            c.disconnect()
        }
    }

    companion object {
        const val URL_CHAT = "https://openrouter.ai/api/v1/chat/completions"
        const val PROMPT = "This is a cropped photo of a two-wheeler from a road camera. Count ONLY the people who are sitting on " +
            "the vehicle (rider, passengers, children). Do NOT count pedestrians or anyone standing next to it, and ignore other " +
            "vehicles in the background. For each person on the vehicle say whether they wear a helmet. If the vehicle is too small " +
            "or blurry to tell, set confidence below 0.5. Reply with ONLY this JSON: " +
            "{\"two_wheeler\": true|false, \"people\": <int>, \"helmets\": [true|false, ...one per person...], \"confidence\": <0..1>}"
    }
}
