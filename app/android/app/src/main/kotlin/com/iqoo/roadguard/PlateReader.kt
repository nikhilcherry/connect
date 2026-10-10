package com.iqoo.roadguard

import android.graphics.Bitmap
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import java.util.concurrent.TimeUnit

/** Reads the characters on a cropped number plate with ML Kit (fully on-device). */
object PlateReader {
    data class Result(val text: String, val valid: Boolean)

    private val recognizer by lazy { TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS) }

    // Standard Indian format (e.g. KL07CD1234, DL1CAB1234) and the Bharat series (22BH1234AA).
    private val standard = Regex("^[A-Z]{2}[0-9]{1,2}[A-Z]{0,3}[0-9]{4}$")
    private val bharat = Regex("^[0-9]{2}BH[0-9]{4}[A-Z]{1,2}$")

    /** Blocking; call from a worker thread. Returns null if recognition fails or times out. */
    fun read(plate: Bitmap): Result? {
        return try {
            val t = Tasks.await(recognizer.process(InputImage.fromBitmap(plate, 0)), 3, TimeUnit.SECONDS)
            val text = t.text.uppercase().filter { it in 'A'..'Z' || it in '0'..'9' }
            Result(text, standard.matches(text) || bharat.matches(text))
        } catch (_: Throwable) {
            null
        }
    }
}
