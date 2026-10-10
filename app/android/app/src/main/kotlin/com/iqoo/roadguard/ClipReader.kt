package com.iqoo.roadguard

import android.content.Context
import android.database.Cursor
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.util.Log
import java.io.File

/** A video to scan: where to read it, and the name it is known by (a dashcam's file name carries its clock). */
class ClipSource(val uri: Uri, val name: String)

/** When and where a clip was recorded, never where the phone is now. */
class ClipInfo(val name: String, val startMs: Long?, val points: List<GpsPoint>) {
    fun locationAt(offsetMs: Long): GpsPoint? = ClipMeta.locationAt(points, startMs, offsetMs)
}

object ClipReader {
    private val SIDECAR_EXT = setOf("gpx", "nmea", "nma", "log", "txt", "gps")
    private const val MAX_SIDECAR_BYTES = 8L * 1024 * 1024

    /** Turns the strings Flutter hands over (content URIs or file paths) into sources. */
    fun sources(context: Context, entries: List<String>): List<ClipSource> = entries.map { e ->
        val uri = if (e.startsWith("content://") || e.startsWith("file://")) Uri.parse(e) else Uri.fromFile(File(e))
        ClipSource(uri, displayName(context, uri))
    }

    fun displayName(context: Context, uri: Uri): String {
        if (uri.scheme == "content") {
            try {
                context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c: Cursor ->
                    if (c.moveToFirst()) c.getString(0)?.let { return it }
                }
            } catch (_: Throwable) {
            }
        }
        return uri.lastPathSegment?.substringAfterLast('/') ?: "clip"
    }

    fun setDataSource(context: Context, mmr: MediaMetadataRetriever, src: ClipSource) {
        if (src.uri.scheme == "file") mmr.setDataSource(src.uri.path) else mmr.setDataSource(context, src.uri)
    }

    /** Reads the clip's own recording time and place: container metadata, then a GPS log beside it. */
    fun read(context: Context, mmr: MediaMetadataRetriever, src: ClipSource): ClipInfo {
        val points = ArrayList<GpsPoint>()
        ClipMeta.parseIso6709(mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_LOCATION))?.let { points.add(it) }
        sidecarText(context, src)?.let { points.addAll(ClipMeta.parseTrack(it)) }
        val start = ClipMeta.startOf(mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DATE), src.name, points)
        Log.i("RoadGuard", "clip ${src.name}: start=${start ?: "unknown"} gpsPoints=${points.size}")
        return ClipInfo(src.name, start, points)
    }

    /** A GPS log with the clip's own name, in the same folder (only found for clips picked from a folder). */
    private fun sidecarText(context: Context, src: ClipSource): String? {
        try {
            val base = src.name.substringBeforeLast('.')
            if (src.uri.scheme == "file") {
                val dir = File(src.uri.path!!).parentFile ?: return null
                val f = dir.listFiles { x -> x.nameWithoutExtension == base && x.extension.lowercase() in SIDECAR_EXT }?.firstOrNull()
                return f?.takeIf { it.length() <= MAX_SIDECAR_BYTES }?.readText()
            }
            if (!DocumentsContract.isDocumentUri(context, src.uri) || !DocumentsContract.isTreeUri(src.uri)) return null
            val docId = DocumentsContract.getDocumentId(src.uri)
            val parentId = if (docId.contains('/')) docId.substringBeforeLast('/') else docId.substringBefore(':') + ":"
            val treeUri = DocumentsContract.buildTreeDocumentUri(src.uri.authority!!, DocumentsContract.getTreeDocumentId(src.uri))
            val children = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, parentId)
            context.contentResolver.query(
                children,
                arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME, DocumentsContract.Document.COLUMN_SIZE),
                null, null, null,
            )?.use { c ->
                while (c.moveToNext()) {
                    val n = c.getString(1) ?: continue
                    if (n.substringBeforeLast('.') == base && n.substringAfterLast('.', "").lowercase() in SIDECAR_EXT && c.getLong(2) <= MAX_SIDECAR_BYTES) {
                        val u = DocumentsContract.buildDocumentUriUsingTree(treeUri, c.getString(0))
                        return context.contentResolver.openInputStream(u)?.use { it.readBytes().toString(Charsets.UTF_8) }
                    }
                }
            }
        } catch (t: Throwable) {
            Log.w("RoadGuard", "no GPS log for ${src.name}: $t")
        }
        return null
    }
}
