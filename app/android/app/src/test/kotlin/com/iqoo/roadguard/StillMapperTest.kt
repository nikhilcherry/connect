package com.iqoo.roadguard

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class StillMapperTest {
    /** Turns a stored image (rows of ids) [deg] degrees clockwise, as Android does to show it upright. */
    private fun rotateCw(g: Array<IntArray>, deg: Int): Array<IntArray> {
        var cur = g
        repeat((deg % 360) / 90) {
            val h = cur.size
            val w = cur[0].size
            val out = Array(w) { IntArray(h) }
            for (y in 0 until h) for (x in 0 until w) out[x][h - 1 - y] = cur[y][x]
            cur = out
        }
        return cur
    }

    @Test
    fun everyPixelInTheMappedRegionBelongsToTheUprightBox() {
        val w = 16
        val h = 12
        val stored = Array(h) { y -> IntArray(w) { x -> y * w + x } } // each pixel carries its own address
        for (rotation in listOf(0, 90, 180, 270)) {
            val upright = rotateCw(stored, rotation)
            val uh = upright.size
            val uw = upright[0].size
            // An upright box: a lopsided one, so a mix-up of axes or directions cannot cancel out.
            val box = NRect(0.1f, 0.2f, 0.45f, 0.9f)
            val s = StillMapper.toStored(box, rotation)
            var checked = 0
            for (uy in 0 until uh) for (ux in 0 until uw) {
                val inBox = (ux + 0.5f) / uw in box.l..box.r && (uy + 0.5f) / uh in box.t..box.b
                val id = upright[uy][ux]
                val sx = (id % w + 0.5f) / w
                val sy = (id / w + 0.5f) / h
                val inMapped = sx in s.l..s.r && sy in s.t..s.b
                assertEquals("rotation $rotation, upright pixel ($ux,$uy)", inBox, inMapped)
                if (inBox) checked++
            }
            assertTrue("rotation $rotation: the box should contain pixels", checked > 0)
        }
    }

    @Test
    fun aPointKeepsItsPlaceWhenNotRotated() {
        assertEquals(0.3f to 0.7f, StillMapper.toStoredPoint(0.3f, 0.7f, 0))
    }

    @Test
    fun anUprightCornerLandsOnTheRightStoredCorner() {
        // Turning the stored image 90 degrees clockwise puts its top-left corner at the upright top-right.
        assertEquals(0f to 0f, StillMapper.toStoredPoint(1f, 0f, 90))
        // ...and 270 degrees puts the stored top-right corner at the upright top-left.
        assertEquals(1f to 0f, StillMapper.toStoredPoint(0f, 0f, 270))
        assertEquals(0f to 0f, StillMapper.toStoredPoint(1f, 1f, 180))
    }

    @Test
    fun theMarginGrowsTheBoxAndStaysInsideTheFrame() {
        val n = StillMapper.expandNormalized(100f, 200f, 300f, 400f, 1000, 800, 0.5f)
        assertEquals(0f, n.l, 1e-6f)      // 100 - 100 = 0
        assertEquals(0.125f, n.t, 1e-6f)  // (200 - 100) / 800
        assertEquals(0.4f, n.r, 1e-6f)    // (300 + 100) / 1000
        assertEquals(0.625f, n.b, 1e-6f)  // (400 + 100) / 800
        val edge = StillMapper.expandNormalized(0f, 0f, 1000f, 800f, 1000, 800, 0.5f)
        assertEquals(NRect(0f, 0f, 1f, 1f), edge)
    }
}
