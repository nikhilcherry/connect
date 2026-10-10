package com.iqoo.roadguard

import kotlin.math.max
import kotlin.math.min

/** A rectangle with every side as a fraction (0..1) of the image's width or height. */
data class NRect(val l: Float, val t: Float, val r: Float, val b: Float)

/**
 * Maps a vehicle's box from the upright analysis frame into the full-resolution still.
 *
 * The analysis frame has been turned upright and the still is a JPEG stored in sensor orientation,
 * which must be turned [rotation] degrees clockwise to be upright. Both cover the same view (both are
 * 4:3), so a place in one is the same fraction of the way across the other. Pure maths, no Android,
 * so it is unit-tested.
 */
object StillMapper {
    /** Grows an upright box by [margin] of its own size on every side, clamped to the frame. */
    fun expandNormalized(l: Float, t: Float, r: Float, b: Float, frameW: Int, frameH: Int, margin: Float): NRect {
        val w = r - l
        val h = b - t
        return NRect(
            ((l - margin * w) / frameW).coerceIn(0f, 1f),
            ((t - margin * h) / frameH).coerceIn(0f, 1f),
            ((r + margin * w) / frameW).coerceIn(0f, 1f),
            ((b + margin * h) / frameH).coerceIn(0f, 1f),
        )
    }

    /** Where an upright (u, v) point lies in the stored JPEG, both as fractions. */
    fun toStoredPoint(u: Float, v: Float, rotation: Int): Pair<Float, Float> = when (((rotation % 360) + 360) % 360) {
        90 -> v to (1f - u)
        180 -> (1f - u) to (1f - v)
        270 -> (1f - v) to u
        else -> u to v
    }

    /** An upright rectangle's place in the stored (unrotated) JPEG. */
    fun toStored(n: NRect, rotation: Int): NRect {
        val (x1, y1) = toStoredPoint(n.l, n.t, rotation)
        val (x2, y2) = toStoredPoint(n.r, n.b, rotation)
        return NRect(min(x1, x2), min(y1, y2), max(x1, x2), max(y1, y2))
    }
}
