package com.iqoo.roadguard

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.InputStream

class MjpegReaderTest {
    /** A stand-in JPEG: the real start and end markers around bytes that cannot contain an end marker. */
    private fun jpeg(tag: Int, size: Int = 300): ByteArray {
        val b = ByteArray(size) { ((it * 7 + tag) and 0x7F).toByte() } // never 0xFF, so no false markers
        b[0] = 0xFF.toByte(); b[1] = 0xD8.toByte(); b[2] = 0xFF.toByte()
        b[size - 2] = 0xFF.toByte(); b[size - 1] = 0xD9.toByte()
        return b
    }

    private fun part(j: ByteArray, withLength: Boolean): ByteArray {
        val head = "--frame\r\nContent-Type: image/jpeg\r\n" + (if (withLength) "Content-Length: ${j.size}\r\n" else "") + "\r\n"
        return head.toByteArray() + j + "\r\n".toByteArray()
    }

    private fun frames(stream: ByteArray, readSize: Int = 4096): List<ByteArray> {
        val out = ArrayList<ByteArray>()
        MjpegReader.readFrames(slow(stream, readSize)) { out.add(it); true }
        return out
    }

    /** Hands the bytes over a few at a time, as a network does. */
    private fun slow(data: ByteArray, max: Int): InputStream = object : InputStream() {
        private val src = ByteArrayInputStream(data)
        override fun read(): Int = src.read()
        override fun read(b: ByteArray, off: Int, len: Int): Int = src.read(b, off, minOf(len, max))
    }

    @Test
    fun framesWithContentLengthComeOutWhole() {
        val a = jpeg(1); val b = jpeg(2, 900); val c = jpeg(3, 50)
        val got = frames(part(a, true) + part(b, true) + part(c, true))
        assertEquals(3, got.size)
        assertArrayEquals(a, got[0]); assertArrayEquals(b, got[1]); assertArrayEquals(c, got[2])
    }

    @Test
    fun framesWithoutContentLengthAreFoundByTheirEndMarker() {
        val a = jpeg(4); val b = jpeg(5, 700)
        val got = frames(part(a, false) + part(b, false) + "--frame--\r\n".toByteArray())
        assertEquals(2, got.size)
        assertArrayEquals(a, got[0]); assertArrayEquals(b, got[1])
    }

    @Test
    fun aStreamWithNoBoundariesAtAllStillWorksFrameAfterFrame() {
        val a = jpeg(6); val b = jpeg(7)
        val got = frames(a + b + jpeg(8))
        assertEquals(2, got.size) // the last frame cannot be told apart from a cut-off one until more arrives
        assertArrayEquals(a, got[0]); assertArrayEquals(b, got[1])
    }

    @Test
    fun oneByteAtATimeGivesTheSameFrames() {
        val a = jpeg(9); val b = jpeg(10, 1200)
        val got = frames(part(a, true) + part(b, false) + part(jpeg(11), true), readSize = 1)
        assertEquals(3, got.size)
        assertArrayEquals(a, got[0]); assertArrayEquals(b, got[1])
    }

    @Test
    fun junkBetweenFramesIsSkipped() {
        val a = jpeg(12); val b = jpeg(13)
        val stream = "HTTP/1.0 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=frame\r\n\r\n".toByteArray() +
            part(a, true) + "garbage".toByteArray() + part(b, true)
        val got = frames(stream, readSize = 13)
        assertEquals(2, got.size)
        assertArrayEquals(a, got[0]); assertArrayEquals(b, got[1])
    }

    @Test
    fun aFrameCutOffByTheEndOfTheStreamIsNotDelivered() {
        val a = jpeg(14, 600)
        val got = frames(part(jpeg(15), true) + part(a, true).copyOf(part(a, true).size - 200))
        assertEquals(1, got.size)
    }

    @Test
    fun theCallerCanStopTheStream() {
        val s = part(jpeg(16), true) + part(jpeg(17), true) + part(jpeg(18), true)
        var seen = 0
        MjpegReader.readFrames(ByteArrayInputStream(s)) { seen++; seen < 2 }
        assertEquals(2, seen)
    }

    @Test
    fun anEmptyOrHeaderOnlyStreamGivesNothing() {
        assertEquals(0, frames(ByteArray(0)).size)
        assertEquals(0, frames("HTTP/1.0 200 OK\r\n\r\n".toByteArray()).size)
    }
}
