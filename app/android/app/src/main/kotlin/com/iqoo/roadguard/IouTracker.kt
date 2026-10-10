package com.iqoo.roadguard

import android.graphics.RectF

/** One tracked vehicle plus the per-vehicle evidence counters used by the violation rules. */
class Track(val id: Int, var box: RectF) {
    var missed = 0
    var observations = 0
    var tripleHits = 0
    var noHelmetHits = 0
    var riderCount = 0
    var firedTriple = false
    var firedNoHelmet = false
    var lastHelmetCheck = 0

    /** AI second opinion: 0 not asked, 1 asked, 2 answered, 3 failed or timed out. */
    @Volatile var aiState = 0
    @Volatile var aiVerdict: AiVerdict? = null
    var aiAskedAtMs = 0L
    var aiCounted = false

    /** The frame and box the AI was asked about, so the evidence shows that moment, not a later one. */
    @Volatile var askFrame: android.graphics.Bitmap? = null
    @Volatile var askBox: RectF? = null
}

/** Greedy IoU tracker. Good enough for slow-moving two-wheeler traffic at 15-30 Hz. */
class IouTracker(private val maxMissed: Int = 12, private val minIou: Float = 0.25f) {
    private val tracks = ArrayList<Track>()
    private var nextId = 1

    /** Returns, for each input box, the track it was assigned to (new tracks are created). */
    fun update(boxes: List<RectF>): List<Track> {
        val assigned = arrayOfNulls<Track>(boxes.size)
        val used = HashSet<Int>()
        val pairs = ArrayList<Triple<Float, Int, Int>>()
        for ((ti, t) in tracks.withIndex()) {
            for ((bi, b) in boxes.withIndex()) {
                val v = iou(t.box, b)
                if (v >= minIou) pairs.add(Triple(v, ti, bi))
            }
        }
        pairs.sortByDescending { it.first }
        val usedTracks = HashSet<Int>()
        for ((_, ti, bi) in pairs) {
            if (ti in usedTracks || bi in used) continue
            usedTracks.add(ti)
            used.add(bi)
            val t = tracks[ti]
            t.box = boxes[bi]
            t.missed = 0
            t.observations++
            assigned[bi] = t
        }
        for ((ti, t) in tracks.withIndex()) if (ti !in usedTracks) t.missed++
        tracks.removeAll { it.missed > maxMissed }
        for ((bi, b) in boxes.withIndex()) {
            if (assigned[bi] == null) {
                val t = Track(nextId++, b).also { it.observations = 1 }
                tracks.add(t)
                assigned[bi] = t
            }
        }
        return assigned.map { it!! }
    }

    companion object {
        fun iou(a: RectF, b: RectF): Float {
            val ix = maxOf(0f, minOf(a.right, b.right) - maxOf(a.left, b.left))
            val iy = maxOf(0f, minOf(a.bottom, b.bottom) - maxOf(a.top, b.top))
            val inter = ix * iy
            val union = a.width() * a.height() + b.width() * b.height() - inter
            return if (union <= 0f) 0f else inter / union
        }
    }
}
