package com.iqoo.roadguard

import java.io.ByteArrayOutputStream
import java.io.InputStream

/**
 * Pulls JPEG frames out of an MJPEG-over-HTTP stream (multipart/x-mixed-replace), the live preview most Wi-Fi
 * dashcams and phone-as-camera apps serve. Pure, so it is unit-tested with awkward reads.
 *
 * Each frame is found by its JPEG start (FF D8 FF). Its end is the part's Content-Length when the header is
 * there, otherwise the JPEG end marker (FF D9) that is followed by the next boundary or the next frame.
 */
object MjpegReader {
    const val MAX_FRAME = 6 * 1024 * 1024
    private const val HEADER_WINDOW = 400
    private val LENGTH = "content-length:".toByteArray(Charsets.US_ASCII)
    private const val CR: Byte = 0x0D
    private const val LF: Byte = 0x0A
    private const val FF: Byte = 0xFF.toByte()
    private const val DASH: Byte = 0x2D

    /**
     * Reads frames until the stream ends, [onFrame] returns false, or it fails. [onFrame] gets a fresh array each time.
     * Returns how many frames it delivered.
     */
    fun readFrames(input: InputStream, onFrame: (ByteArray) -> Boolean): Int {
        val buf = ByteArrayOutputStream(256 * 1024)
        val chunk = ByteArray(32 * 1024)
        var delivered = 0
        while (true) {
            val n = input.read(chunk)
            if (n < 0) break
            buf.write(chunk, 0, n)
            val data = buf.toByteArray()
            var pos = 0
            // Take every whole frame in what has arrived so far.
            while (true) {
                val soi = indexOfSoi(data, pos)
                if (soi < 0) {
                    pos = maxOf(pos, data.size - HEADER_WINDOW) // keep the part header that precedes the next frame
                    break
                }
                val end = frameEnd(data, soi)
                if (end < 0) {
                    pos = maxOf(pos, soi - HEADER_WINDOW)
                    break
                }
                if (!onFrame(data.copyOfRange(soi, end))) return delivered + 1
                delivered++
                pos = end
            }
            buf.reset()
            if (pos < data.size) buf.write(data, pos, data.size - pos)
            if (buf.size() > MAX_FRAME) buf.reset() // a runaway: no frame this big, start again
        }
        return delivered
    }

    private fun indexOfSoi(d: ByteArray, from: Int): Int {
        var i = maxOf(0, from)
        while (i + 2 < d.size) {
            if (d[i] == FF && d[i + 1] == 0xD8.toByte() && d[i + 2] == FF) return i
            i++
        }
        return -1
    }

    /** Exclusive end of the frame starting at [soi], or -1 when it has not all arrived yet. */
    private fun frameEnd(d: ByteArray, soi: Int): Int {
        val len = lengthBefore(d, soi)
        if (len in 4..MAX_FRAME) return if (soi + len <= d.size) soi + len else -1
        var i = soi + 2
        while (i + 1 < d.size) {
            if (d[i] == FF && d[i + 1] == 0xD9.toByte()) {
                var j = i + 2
                while (j < d.size && (d[j] == CR || d[j] == LF)) j++
                if (j + 1 >= d.size) return -1 // cannot tell what follows yet
                val dash = d[j] == DASH && d[j + 1] == DASH
                val next = d[j] == FF && d[j + 1] == 0xD8.toByte()
                if (dash || next) return i + 2
            }
            i++
        }
        return -1
    }

    private fun blankLineEndsAt(d: ByteArray, end: Int): Int = when {
        end >= 4 && d[end - 4] == CR && d[end - 3] == LF && d[end - 2] == CR && d[end - 1] == LF -> 4
        end >= 2 && d[end - 2] == LF && d[end - 1] == LF -> 2
        else -> 0
    }

    /**
     * The Content-Length in this part's own header, or -1. The header block ends with a blank line right before the
     * frame, and begins after the previous frame or the previous blank line, so a neighbour's header is never read.
     */
    private fun lengthBefore(d: ByteArray, soi: Int): Int {
        val blank = blankLineEndsAt(d, soi)
        if (blank == 0) return -1
        val end = soi - blank
        val limit = maxOf(0, end - HEADER_WINDOW)
        var i = end
        while (i > limit) {
            if (d[i] == FF) break // the end of the previous frame
            if (blankLineEndsAt(d, i + 1) != 0) break // the end of an earlier header block
            i--
        }
        var p = i
        while (p + LENGTH.size <= end) {
            var ok = true
            for (k in LENGTH.indices) {
                if ((d[p + k].toInt() or 0x20).toByte() != LENGTH[k]) { ok = false; break }
            }
            if (ok) {
                var j = p + LENGTH.size
                while (j < end && d[j] == ' '.code.toByte()) j++
                var v = 0
                var digits = 0
                while (j < end && d[j] in '0'.code.toByte()..'9'.code.toByte() && digits < 9) {
                    v = v * 10 + (d[j] - '0'.code.toByte())
                    j++
                    digits++
                }
                return if (digits > 0) v else -1
            }
            p++
        }
        return -1
    }
}
