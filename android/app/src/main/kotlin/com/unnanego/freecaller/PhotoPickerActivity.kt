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

    companion object {
        const val EXTRA_CAMERA = "camera"

        private const val TAG = "FreecallerPhoto"
        private const val REQ_PICK = 4001
        private const val REQ_CAPTURE = 4002

        // The server caps an avatar at 2 MB and never serves the original — it
        // is shown at 46-140 px. Matching what image_picker was asked for on
        // iOS keeps the two platforms uploading comparable files.
        private const val MAX_EDGE = 1024
        private const val QUALITY = 85
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Recreated (rotation, process death) with a pick already in flight:
        // the pending Dart call is long gone, so do not start a second picker.
        if (savedInstanceState != null) {
            finish()
            return
        }
        try {
            if (intent.getBooleanExtra(EXTRA_CAMERA, false)) startCapture() else startPick()
        } catch (e: Throwable) {
            Log.w(TAG, "could not open picker", e)
            PhotoPickerBridge.fail("unavailable", e.message ?: "picker unavailable")
            finish()
        }
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
        if (resultCode != RESULT_OK) {
            // Backed out of the picker: not an error, just nothing chosen.
            PhotoPickerBridge.succeed(null)
            captureFile?.delete()
            finish()
            return
        }
        val source = when (requestCode) {
            REQ_CAPTURE -> captureFile?.let { Uri.fromFile(it) }
            else -> data?.data
        }
        if (source == null) {
            PhotoPickerBridge.fail("no-image", "picker returned no image")
            finish()
            return
        }
        try {
            val scaled = downscale(source)
            if (scaled == null) {
                PhotoPickerBridge.fail("decode", "could not read the chosen image")
            } else {
                PhotoPickerBridge.succeed(scaled.absolutePath)
            }
        } catch (e: Throwable) {
            Log.w(TAG, "could not process image", e)
            PhotoPickerBridge.fail("decode", e.message ?: "could not process image")
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

    /** Park [result] for the activity to answer. */
    fun begin(result: MethodChannel.Result) {
        pending?.success(null) // whatever was in flight is abandoned, not lost
        pending = result
    }

    fun succeed(path: String?) {
        val result = pending ?: return
        pending = null
        result.success(path)
    }

    fun fail(code: String, message: String) {
        val result = pending ?: return
        pending = null
        result.error(code, message, null)
    }
}
