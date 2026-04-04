package com.peariscope.clipboard

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.content.FileProvider
import java.io.ByteArrayOutputStream
import java.io.File

/**
 * Monitors the local clipboard and shares text/image changes with remote peers.
 * Receives clipboard data from remote peers and applies it locally.
 * Port of iOS ClipboardSharing.swift.
 */
class ClipboardSharing(private val context: Context) {

    var onClipboardChanged: ((String) -> Unit)? = null
    var onImageClipboardChanged: ((ByteArray) -> Unit)? = null

    private val clipboardManager = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
    private val handler = Handler(Looper.getMainLooper())
    private var isMonitoring = false
    private var lastKnownText: String? = null
    private var lastKnownImageHash: Int = 0
    private var suppressNextCheck = false

    private val clipboardDir: File by lazy {
        File(context.cacheDir, "clipboard").also { it.mkdirs() }
    }

    private val pollRunnable = object : Runnable {
        override fun run() {
            if (isMonitoring) {
                checkClipboard()
                handler.postDelayed(this, POLL_INTERVAL_MS)
            }
        }
    }

    fun startMonitoring() {
        if (isMonitoring) return
        isMonitoring = true
        lastKnownText = currentClipboardText()
        lastKnownImageHash = currentImageHash()
        handler.postDelayed(pollRunnable, POLL_INTERVAL_MS)
    }

    fun stopMonitoring() {
        isMonitoring = false
        handler.removeCallbacks(pollRunnable)
    }

    /** Apply clipboard text received from a remote peer */
    fun applyRemoteClipboard(text: String) {
        if (text.toByteArray(Charsets.UTF_8).size > MAX_CLIPBOARD_SIZE) {
            Log.w(TAG, "Rejected remote clipboard: size exceeds max $MAX_CLIPBOARD_SIZE")
            return
        }
        suppressNextCheck = true
        lastKnownText = text
        clipboardManager.setPrimaryClip(ClipData.newPlainText("Peariscope", text))
    }

    /** Apply clipboard image (PNG) received from a remote peer */
    fun applyRemoteImage(pngData: ByteArray) {
        if (pngData.size > MAX_IMAGE_SIZE) {
            Log.w(TAG, "Rejected remote image: size ${pngData.size} exceeds max $MAX_IMAGE_SIZE")
            return
        }
        suppressNextCheck = true
        try {
            // Write PNG to cache dir, create content:// URI via FileProvider
            val file = File(clipboardDir, "clipboard_image.png")
            file.writeBytes(pngData)
            val uri = FileProvider.getUriForFile(
                context,
                "${context.packageName}.fileprovider",
                file
            )
            val clip = ClipData.newUri(context.contentResolver, "Peariscope Image", uri)
            clipboardManager.setPrimaryClip(clip)
            lastKnownImageHash = pngData.contentHashCode()
            Log.d(TAG, "Applied remote image to clipboard (${pngData.size} bytes)")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to apply remote image to clipboard", e)
        }
    }

    private fun checkClipboard() {
        if (suppressNextCheck) {
            suppressNextCheck = false
            return
        }

        // Check for image changes first (images take priority over text
        // since copying an image often also puts text on the clipboard)
        val imgHash = currentImageHash()
        if (imgHash != 0 && imgHash != lastKnownImageHash) {
            lastKnownImageHash = imgHash
            val pngData = currentImageAsPNG()
            if (pngData != null && pngData.size <= MAX_IMAGE_SIZE) {
                onImageClipboardChanged?.invoke(pngData)
                return
            }
        }

        // Check text
        val current = currentClipboardText()
        if (current != null && current != lastKnownText && current.toByteArray(Charsets.UTF_8).size <= MAX_CLIPBOARD_SIZE) {
            lastKnownText = current
            onClipboardChanged?.invoke(current)
        }
    }

    private fun currentClipboardText(): String? {
        return try {
            if (clipboardManager.hasPrimaryClip()) {
                val clip = clipboardManager.primaryClip
                if (clip != null && clip.itemCount > 0) {
                    clip.getItemAt(0).coerceToText(context)?.toString()
                } else null
            } else null
        } catch (e: Exception) {
            null
        }
    }

    /** Quick hash to detect image clipboard changes without reading full data */
    private fun currentImageHash(): Int {
        return try {
            val clip = clipboardManager.primaryClip ?: return 0
            if (clip.itemCount == 0) return 0
            val item = clip.getItemAt(0)
            val uri = item.uri ?: return 0
            val mime = context.contentResolver.getType(uri) ?: return 0
            if (!mime.startsWith("image/")) return 0
            // Use clip description + uri as a lightweight change indicator
            uri.hashCode()
        } catch (e: Exception) {
            0
        }
    }

    /** Read the current clipboard image as PNG data */
    private fun currentImageAsPNG(): ByteArray? {
        return try {
            val clip = clipboardManager.primaryClip ?: return null
            if (clip.itemCount == 0) return null
            val item = clip.getItemAt(0)
            val uri = item.uri ?: return null
            val mime = context.contentResolver.getType(uri) ?: return null
            if (!mime.startsWith("image/")) return null

            val inputStream = context.contentResolver.openInputStream(uri) ?: return null
            val bitmap = inputStream.use { BitmapFactory.decodeStream(it) } ?: return null
            val out = ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
            bitmap.recycle()
            out.toByteArray()
        } catch (e: Exception) {
            Log.w(TAG, "Failed to read clipboard image", e)
            null
        }
    }

    companion object {
        private const val TAG = "ClipboardSharing"
        private const val POLL_INTERVAL_MS = 1000L
        const val MAX_CLIPBOARD_SIZE = 1024 * 1024       // 1MB
        const val MAX_IMAGE_SIZE = 10 * 1024 * 1024      // 10MB
    }
}
