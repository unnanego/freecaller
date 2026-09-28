package com.unnanego.freecaller

import android.app.Activity
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import android.net.Uri
import android.os.Bundle
import android.provider.MediaStore
import android.util.Log
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream

/**
 * Picking a profile photo, in an activity of our own.
 *
 * MainActivity is `singleInstance` because that is what makes answering a call
 * work (see the note in AndroidManifest.xml), and a singleInstance activity is
 * the only member its task can ever hold: anything it starts for a result is
 * pushed into another task, and the result never comes back. That is why
 * image_picker silently did nothing here — the photo was chosen and the answer
 * went nowhere.
 *
 * This activity has an ordinary launch mode, so the system picker it starts
 * lands in ITS task and answers it normally. Dart talks to it through
 * [PhotoPickerBridge] rather than through MainActivity's activity results, so
 * nothing about the call path is involved.
 */
class PhotoPickerActivity : Activity() {
    private var captureFile: File? = null

    // Whether the Dart call that opened this activity has been answered. Every
    // way out of here must answer it exactly once: an unanswered one is a Dart
    // future that never completes and a profile screen stuck on its spinner.
    private var answered = false

    // Which Dart request this activity is answering (see PhotoPickerBridge).
    // Read from the launching intent, which a recreated instance gets again.
    private val ticket: Int by lazy { intent.getIntExtra(EXTRA_TICKET, -1) }

    companion object {
        const val EXTRA_CAMERA = "camera"
        const val EXTRA_TICKET = "ticket"

        private const val TAG = "FreecallerPhoto"
        private const val REQ_PICK = 4001
        private const val REQ_CAPTURE = 4002
        private const val STATE_CAPTURE_FILE = "captureFile"

        // The server caps an avatar at 2 MB and never serves the original — it
        // is shown at 46-140 px. Matching what image_picker was asked for on
        // iOS keeps the two platforms uploading comparable files.
        private const val MAX_EDGE = 1024
        private const val QUALITY = 85
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Recreated (rotation, or "don't keep activities" / low memory while the
        // camera was in front) with a pick already in flight. Do not start a
        // second picker — but do NOT finish either: the first picker is still
        // up and its result is delivered to this new instance through
        // onActivityResult. Finishing here threw that result away without
        // answering PhotoPickerBridge, so Dart's `pick` never completed. All
        // the new instance needs in order to carry on is where the camera was
        // told to write.
        //
        // After real process death the parked Dart result died with the
        // process; the bridge then has nothing pending and answering it is a
        // no-op, which is the right outcome.
        if (savedInstanceState != null) {
            captureFile = savedInstanceState.getString(STATE_CAPTURE_FILE)?.let { File(it) }
            return
        }
        try {
            if (intent.getBooleanExtra(EXTRA_CAMERA, false)) startCapture() else startPick()
        } catch (e: Throwable) {
            Log.w(TAG, "could not open picker", e)
            answered = true
            PhotoPickerBridge.fail(ticket, "unavailable", e.message ?: "picker unavailable")
            finish()
        }
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        captureFile?.let { outState.putString(STATE_CAPTURE_FILE, it.absolutePath) }
    }

    override fun onDestroy() {
        // Finishing without having answered — dismissed by the system, a
        // finish() from a path nobody thought of — is reported as "nothing
        // chosen". Not when merely being recreated (isFinishing is false
        // then): the pick is still in flight and its result is still coming.
        // succeed() is a no-op once the bridge has been answered, so this can
        // never produce a second reply.
        if (isFinishing && !answered) {
            answered = true
            PhotoPickerBridge.succeed(ticket, null)
            captureFile?.delete()
        }
        super.onDestroy()
    }

    private fun startPick() {
        val intent = Intent(Intent.ACTION_GET_CONTENT).apply {
            type = "image/*"
            addCategory(Intent.CATEGORY_OPENABLE)
        }
        startActivityForResult(intent, REQ_PICK)
    }

    private fun startCapture() {
        val file = File(cacheDir, "capture_${System.currentTimeMillis()}.jpg")
        captureFile = file
        val uri = FileProvider.getUriForFile(this, "$packageName.photos", file)
        val intent = Intent(MediaStore.ACTION_IMAGE_CAPTURE).apply {
            putExtra(MediaStore.EXTRA_OUTPUT, uri)
            addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        }
        startActivityForResult(intent, REQ_CAPTURE)
    }

    @Deprecated("startActivityForResult is the only path that works from our own task")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        // Whatever happens below answers the bridge (every branch does).
        answered = true
        if (resultCode != RESULT_OK) {
            // Backed out of the picker: not an error, just nothing chosen.
            PhotoPickerBridge.succeed(ticket, null)
            captureFile?.delete()
            finish()
            return
        }
        val source = when (requestCode) {
            REQ_CAPTURE -> captureFile?.let { Uri.fromFile(it) }
            else -> data?.data
        }
        if (source == null) {
            PhotoPickerBridge.fail(ticket, "no-image", "picker returned no image")
            finish()
            return
        }
        try {
            val scaled = downscale(source)
            if (scaled == null) {
                PhotoPickerBridge.fail(ticket, "decode", "could not read the chosen image")
            } else {
                PhotoPickerBridge.succeed(ticket, scaled.absolutePath)
            }
        } catch (e: Throwable) {
            Log.w(TAG, "could not process image", e)
            PhotoPickerBridge.fail(ticket, "decode", e.message ?: "could not process image")
        } finally {
            // The capture original is redundant once it has been scaled down,
            // and it is a photo of someone sitting in a cache directory.
            captureFile?.delete()
            finish()
        }
    }

    /** Decode, rotate upright and shrink to a JPEG in our cache. */
    private fun downscale(uri: Uri): File? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null

        // Halve until the cheap decode is within one step of the target, so a
        // 12 MP phone photo never has to exist full-size in memory.
        var sample = 1
        while (bounds.outWidth / sample > MAX_EDGE * 2 && bounds.outHeight / sample > MAX_EDGE * 2) {
            sample *= 2
        }
        val options = BitmapFactory.Options().apply { inSampleSize = sample }
        val decoded = contentResolver.openInputStream(uri)
            ?.use { BitmapFactory.decodeStream(it, null, options) } ?: return null

        val upright = applyExifRotation(uri, decoded)
        val longest = maxOf(upright.width, upright.height)
        val bitmap = if (longest > MAX_EDGE) {
            val scale = MAX_EDGE.toFloat() / longest
            Bitmap.createScaledBitmap(
                upright,
                (upright.width * scale).toInt().coerceAtLeast(1),
                (upright.height * scale).toInt().coerceAtLeast(1),
                true,
            )
        } else {
            upright
        }

        val out = File(cacheDir, "avatar_${System.currentTimeMillis()}.jpg")
        FileOutputStream(out).use { bitmap.compress(Bitmap.CompressFormat.JPEG, QUALITY, it) }
        return out
    }

    /**
     * Phone cameras store the photo as the sensor read it plus an orientation
     * tag; ignoring the tag uploads a portrait of someone lying on their side.
     */
    private fun applyExifRotation(uri: Uri, bitmap: Bitmap): Bitmap {
        val orientation = try {
            contentResolver.openInputStream(uri)?.use {
                ExifInterface(it).getAttributeInt(
                    ExifInterface.TAG_ORIENTATION,
                    ExifInterface.ORIENTATION_NORMAL,
                )
            } ?: ExifInterface.ORIENTATION_NORMAL
        } catch (e: Throwable) {
            ExifInterface.ORIENTATION_NORMAL
        }
        val matrix = Matrix()
        when (orientation) {
            ExifInterface.ORIENTATION_ROTATE_90 -> matrix.postRotate(90f)
            ExifInterface.ORIENTATION_ROTATE_180 -> matrix.postRotate(180f)
            ExifInterface.ORIENTATION_ROTATE_270 -> matrix.postRotate(270f)
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.postScale(-1f, 1f)
            ExifInterface.ORIENTATION_FLIP_VERTICAL -> matrix.postScale(1f, -1f)
            else -> return bitmap
        }
        return Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
    }
}

/**
 * Hands the picked file back to the Dart call that asked for it.
 *
 * The channel lives on MainActivity's engine while the picking happens in
 * another activity (and another task), so the pending result is parked here in
 * the process both share. One pick at a time: a second request cancels the
 * first rather than leaving a Dart future that never completes.
 */
object PhotoPickerBridge {
    private var pending: MethodChannel.Result? = null
    // Starts somewhere arbitrary rather than at 0, so an activity restored
    // after process death (still carrying a ticket from the old process)
    // cannot coincide with the first ticket this process hands out.
    private var ticket = (System.nanoTime() and 0x3fffffff).toInt()

    /**
     * Park [result] for the activity to answer, and return the ticket that
     * activity must present when it does.
     *
     * The ticket is what makes "exactly once" hold with two activities alive:
     * a second `pick` abandons the first request, but the first activity is
     * still out there, and when it eventually finishes it answers. Without a
     * ticket that late answer landed on the SECOND request — resolving a pick
     * the user was still in the middle of with somebody else's "nothing".
     */
    fun begin(result: MethodChannel.Result): Int {
        pending?.success(null) // whatever was in flight is abandoned, not lost
        pending = result
        ticket += 1
        return ticket
    }

    fun succeed(forTicket: Int, path: String?) {
        if (forTicket != ticket) return
        val result = pending ?: return
        pending = null
        result.success(path)
    }

    fun fail(forTicket: Int, code: String, message: String) {
        if (forTicket != ticket) return
        val result = pending ?: return
        pending = null
        result.error(code, message, null)
    }
}
