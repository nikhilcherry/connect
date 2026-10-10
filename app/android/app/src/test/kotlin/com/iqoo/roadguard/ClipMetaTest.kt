package com.iqoo.roadguard

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Calendar
import java.util.TimeZone

class ClipMetaTest {
    private val utc = TimeZone.getTimeZone("UTC")
    private val ist = TimeZone.getTimeZone("Asia/Kolkata")

    private fun ms(y: Int, mo: Int, d: Int, h: Int, mi: Int, s: Int, tz: TimeZone = utc): Long =
        Calendar.getInstance(tz).apply { clear(); set(y, mo - 1, d, h, mi, s) }.timeInMillis

    @Test
    fun containerDatesAreReadAsUtc() {
        assertEquals(ms(2023, 10, 1, 13, 38, 50), ClipMeta.parseMetadataDate("20231001T133850.000Z"))
        assertEquals(ms(2023, 10, 1, 13, 38, 50), ClipMeta.parseMetadataDate("2023-10-01T13:38:50Z"))
        assertEquals(ms(2023, 10, 1, 13, 38, 50) + 250, ClipMeta.parseMetadataDate("20231001T133850.25Z"))
    }

    @Test
    fun anUnsetContainerDateIsNotBelieved() {
        assertNull(ClipMeta.parseMetadataDate("19040101T000000.000Z"))
        assertNull(ClipMeta.parseMetadataDate("19700101T000000.000Z"))
        assertNull(ClipMeta.parseMetadataDate(null))
        assertNull(ClipMeta.parseMetadataDate("garbage"))
    }

    @Test
    fun dashcamFileNamesCarryLocalTime() {
        val want = ms(2023, 10, 1, 13, 38, 50, ist)
        assertEquals(want, ClipMeta.fromFileName("2023_1001_133850_001.MP4", ist))
        assertEquals(want, ClipMeta.fromFileName("VID_20231001_133850.mp4", ist))
        assertEquals(want, ClipMeta.fromFileName("20231001-133850-front.mov", ist))
        assertEquals(want, ClipMeta.fromFileName("2023-10-01 13-38-50.mp4", ist))
        assertNull(ClipMeta.fromFileName("191.mp4", ist))
        assertNull(ClipMeta.fromFileName("2023_1301_133850.mp4", ist)) // month 13
    }

    @Test
    fun theContainerLocationIsRead() {
        val p = ClipMeta.parseIso6709("+12.9716+077.5946/")!!
        assertEquals(12.9716, p.lat, 1e-9)
        assertEquals(77.5946, p.lon, 1e-9)
        assertEquals(-33.87, ClipMeta.parseIso6709("-33.8700+151.2100+020.0/")!!.lat, 1e-9)
        assertNull(ClipMeta.parseIso6709("+00.0000+000.0000/")) // an empty fix is not a place
        assertNull(ClipMeta.parseIso6709("+95.0+077.0/"))
        assertNull(ClipMeta.parseIso6709(null))
    }

    @Test
    fun nmeaFixesAreReadWithTheirClock() {
        val log = """
            ${'$'}GPGGA,133850.00,1258.2960,N,07735.6760,E,1,08,0.9,900.0,M,-86.0,M,,*5C
            ${'$'}GPRMC,133850.00,A,1258.2960,N,07735.6760,E,12.3,45.0,011023,,,A*6A
            ${'$'}GPRMC,133851.00,V,,,,,,,011023,,,N*4A
            ${'$'}GNRMC,133900.00,A,1258.3000,N,07735.7000,E,10.0,45.0,011023,,,A*00
        """.trimIndent()
        val pts = ClipMeta.parseNmea(log)
        assertEquals(2, pts.size) // the GGA line and the invalid (V) fix are skipped
        assertEquals(ms(2023, 10, 1, 13, 38, 50), pts[0].timeMs)
        assertEquals(12.0 + 58.2960 / 60.0, pts[0].lat, 1e-6)
        assertEquals(77.0 + 35.6760 / 60.0, pts[0].lon, 1e-6)
    }

    @Test
    fun southAndWestAreNegative() {
        val p = ClipMeta.parseNmea("${'$'}GPRMC,010203,A,3352.2000,S,15112.6000,W,0,0,150324,,,A*00").single()
        assertTrue(p.lat < 0 && p.lon < 0)
    }

    @Test
    fun gpxTrackPointsAreReadInEitherAttributeOrder() {
        val gpx = """
            <gpx><trk><trkseg>
              <trkpt lat="12.9716" lon="77.5946"><time>2023-10-01T13:38:50Z</time></trkpt>
              <trkpt lon="77.5950" lat="12.9720"><time>2023-10-01T13:39:10Z</time></trkpt>
            </trkseg></trk></gpx>
        """.trimIndent()
        val pts = ClipMeta.parseGpx(gpx)
        assertEquals(2, pts.size)
        assertEquals(12.9720, pts[1].lat, 1e-9)
        assertEquals(77.5950, pts[1].lon, 1e-9)
        assertEquals(ms(2023, 10, 1, 13, 39, 10), pts[1].timeMs)
    }

    @Test
    fun theFixNearestTheMomentIsChosen() {
        val a = GpsPoint(ms(2023, 10, 1, 13, 38, 50), 12.0, 77.0)
        val b = GpsPoint(ms(2023, 10, 1, 13, 39, 50), 12.1, 77.1)
        val start = a.timeMs!!
        assertEquals(a, ClipMeta.locationAt(listOf(a, b), start, 10_000))
        assertEquals(b, ClipMeta.locationAt(listOf(a, b), start, 50_000))
    }

    @Test
    fun aLogFromAnotherTripIsNotThisClipsPlace() {
        val old = GpsPoint(ms(2023, 9, 1, 8, 0, 0), 12.0, 77.0)
        assertNull(ClipMeta.locationAt(listOf(old), ms(2023, 10, 1, 13, 38, 50), 0))
    }

    @Test
    fun aSingleUntimedPlaceServesTheWholeClipAndNoPlaceMeansNone() {
        val only = GpsPoint(null, 12.0, 77.0)
        assertEquals(only, ClipMeta.locationAt(listOf(only), null, 30_000))
        assertNull(ClipMeta.locationAt(emptyList(), 123L, 0))
    }

    @Test
    fun theStartComesFromTheGpsLogThenTheContainerThenTheName() {
        val track = listOf(GpsPoint(ms(2023, 10, 1, 13, 38, 50), 12.0, 77.0))
        // A GPS log beside the clip is satellite time: it beats a container date that disagrees with it.
        assertEquals(ms(2023, 10, 1, 13, 38, 50), ClipMeta.startOf("20250325T054311.000Z", "2023_1001_133850.MP4", track, utc))
        assertEquals(ms(2023, 10, 1, 13, 38, 50), ClipMeta.startOf(null, "191.mp4", track, utc))
        // No log: the container date if believable, else the name.
        assertEquals(ms(2023, 10, 2, 9, 0, 0), ClipMeta.startOf("20231002T090000.000Z", "2023_1001_133850.MP4", emptyList(), utc))
        assertEquals(ms(2023, 10, 1, 13, 38, 50), ClipMeta.startOf("19700101T000000.000Z", "2023_1001_133850.MP4", emptyList(), utc))
        assertNull(ClipMeta.startOf(null, "191.mp4", emptyList(), utc))
        // A place with no clock (the container's own location) says nothing about when.
        assertNull(ClipMeta.startOf(null, "191.mp4", listOf(GpsPoint(null, 12.0, 77.0)), utc))
        assertNotNull(track)
    }
}
