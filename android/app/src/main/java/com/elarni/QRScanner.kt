package com.elarni

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.ImageFormat
import android.graphics.Matrix
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.SurfaceTexture
import android.graphics.YuvImage
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.params.OutputConfiguration
import android.hardware.camera2.params.SessionConfiguration
import android.media.Image
import android.media.ImageReader
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.SystemClock
import android.util.Size
import android.view.Surface
import android.view.TextureView
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.compose.LifecycleResumeEffect
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.util.concurrent.Executor

/** Reads a camera frame's luminance plane through the same decoder as a QR photo. */
object QRFrames {
    /** Instrumentation stands in for a code the emulated camera cannot show. */
    @Volatile var read: (ByteBuffer, Int, Int, Int) -> String? = ::decode

    fun decode(luma: ByteBuffer, rowStride: Int, width: Int, height: Int): String? {
        // A QR decoder reads only brightness; gray chroma makes the plane an NV21 frame Android can encode.
        val frame = ByteArray(width * height * 3 / 2)
        for (row in 0 until height) { luma.position(row * rowStride); luma.get(frame, row * width, width) }
        frame.fill(128.toByte(), width * height)
        val jpeg = ByteArrayOutputStream().also { YuvImage(frame, ImageFormat.NV21, width, height, null).compressToJpeg(Rect(0, 0, width, height), 90, it) }.toByteArray()
        return try { Native.qr(jpeg) } catch (_: AppFailure) { null }
    }
}

/** A live back-camera preview that reads a QR code four times a second. Camera2 keeps the app free of a camera library. */
class QRScanner(private val context: Context, private val found: (String) -> Unit, private val failed: () -> Unit) : TextureView.SurfaceTextureListener {
    private val thread = HandlerThread("qr-scanner").apply { start() }
    private val camera = Handler(thread.looper)
    private val main = Handler(Looper.getMainLooper())
    private var view: TextureView? = null
    @Volatile private var size: Size? = null
    // The rest belongs to the camera thread.
    private var texture: SurfaceTexture? = null
    private var resumed = false
    private var opening = false
    private var device: CameraDevice? = null
    private var reader: ImageReader? = null
    private var lastRead = 0L
    private var done = false
    private var ended = false

    fun attach(view: TextureView) {
        this.view = view
        view.surfaceTextureListener = this
        if (view.isAvailable) view.surfaceTexture?.let { onSurfaceTextureAvailable(it, view.width, view.height) }
    }
    fun resume() { camera.post { resumed = true; open() } }
    fun pause() { camera.post { resumed = false; release() } }
    // A camera still opening reports back on this thread, so the thread outlives it.
    fun close() { camera.post { ended = true; resumed = false; release(); settle() } }
    private fun settle() { if (ended && !opening) thread.quitSafely() }

    override fun onSurfaceTextureAvailable(surface: SurfaceTexture, width: Int, height: Int) { camera.post { texture = surface; open() } }
    override fun onSurfaceTextureSizeChanged(surface: SurfaceTexture, width: Int, height: Int) = transform()
    // The camera may still draw into the texture, so it is released after the camera closes.
    override fun onSurfaceTextureDestroyed(surface: SurfaceTexture): Boolean {
        if (!camera.post { release(); texture = null; surface.release() }) surface.release()
        return false
    }
    override fun onSurfaceTextureUpdated(surface: SurfaceTexture) {}

    @SuppressLint("MissingPermission") // The QR screen shows the scanner only with the camera permission.
    private fun open() {
        val surface = texture ?: return
        if (!resumed || done || opening || device != null) return
        try {
            val manager = context.getSystemService(CameraManager::class.java)
            val id = manager.cameraIdList.let { ids -> ids.firstOrNull { manager.getCameraCharacteristics(it).get(CameraCharacteristics.LENS_FACING) == CameraCharacteristics.LENS_FACING_BACK } ?: ids.firstOrNull() }
                ?: return fail()
            val characteristics = manager.getCameraCharacteristics(id)
            // Large enough for a dense code at arm's length, small enough to read several times a second; 4:3 fills the frame.
            val fitting = characteristics.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)?.getOutputSizes(ImageFormat.YUV_420_888)
                ?.filter { it.width <= 1280 && it.height <= 960 }?.sortedByDescending { it.width * it.height }.orEmpty()
            val chosen = fitting.firstOrNull { it.width * 3 == it.height * 4 } ?: fitting.firstOrNull() ?: return fail()
            val focus = characteristics.get(CameraCharacteristics.CONTROL_AF_AVAILABLE_MODES)?.contains(CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE) == true
            size = chosen; opening = true
            manager.openCamera(id, object : CameraDevice.StateCallback() {
                override fun onOpened(opened: CameraDevice) {
                    opening = false
                    if (!resumed || done || texture !== surface) { opened.close(); settle(); return }
                    device = opened
                    try { start(opened, surface, chosen, focus) } catch (_: Exception) { fail() }
                }
                override fun onDisconnected(closed: CameraDevice) {
                    opening = false; closed.close()
                    if (device === closed) release()
                    settle()
                }
                override fun onError(closed: CameraDevice, error: Int) { onDisconnected(closed); fail() }
            }, camera)
        } catch (_: Exception) { opening = false; fail() }
    }

    private fun start(opened: CameraDevice, surface: SurfaceTexture, size: Size, focus: Boolean) {
        surface.setDefaultBufferSize(size.width, size.height)
        val preview = Surface(surface)
        val frames = ImageReader.newInstance(size.width, size.height, ImageFormat.YUV_420_888, 2).also { reader = it }
        frames.setOnImageAvailableListener({ it.acquireLatestImage()?.let(::frame) }, camera)
        val request = opened.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW).apply {
            addTarget(preview); addTarget(frames.surface)
            if (focus) set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE)
        }.build()
        opened.createCaptureSession(SessionConfiguration(SessionConfiguration.SESSION_REGULAR,
            listOf(OutputConfiguration(preview), OutputConfiguration(frames.surface)), Executor { camera.post(it) },
            object : CameraCaptureSession.StateCallback() {
                override fun onConfigured(session: CameraCaptureSession) {
                    if (device !== opened) return
                    try { session.setRepeatingRequest(request, null, camera) } catch (_: Exception) { if (device === opened) fail() }
                }
                override fun onConfigureFailed(session: CameraCaptureSession) { if (device === opened) fail() }
            }))
        main.post(::transform)
    }

    private fun frame(image: Image) {
        val text = try {
            val now = SystemClock.elapsedRealtime()
            if (done || now - lastRead < 250) null
            else { lastRead = now; image.planes[0].let { QRFrames.read(it.buffer, it.rowStride, image.width, image.height) } }
        } finally { image.close() }
        if (text == null) return
        done = true; release()
        main.post { found(text) }
    }

    private fun release() {
        device?.close(); device = null
        reader?.close(); reader = null
    }

    private fun fail() { release(); main.post { failed() } }

    // Android turns the sensor's frames upright; this keeps their proportions and follows a landscape display.
    private fun transform() {
        val view = view ?: return
        val size = size ?: return
        val w = view.width.toFloat(); val h = view.height.toFloat()
        if (w == 0f || h == 0f) return
        val rotation = view.display?.rotation ?: Surface.ROTATION_0
        val matrix = Matrix()
        if (rotation == Surface.ROTATION_90 || rotation == Surface.ROTATION_270) {
            val bounds = RectF(0f, 0f, w, h)
            val buffer = RectF(0f, 0f, size.height.toFloat(), size.width.toFloat()).apply { offset(bounds.centerX() - centerX(), bounds.centerY() - centerY()) }
            matrix.setRectToRect(bounds, buffer, Matrix.ScaleToFit.FILL)
            val scale = maxOf(h / size.height, w / size.width)
            matrix.postScale(scale, scale, w / 2, h / 2)
            matrix.postRotate(90f * (rotation - 2), w / 2, h / 2)
        } else {
            // Upright, a frame is size.height wide; both axes scale alike to cover the view.
            val fx = w / size.height; val fy = h / size.width; val cover = maxOf(fx, fy)
            matrix.setScale(cover / fx, cover / fy, w / 2, h / 2)
            if (rotation == Surface.ROTATION_180) matrix.postRotate(180f, w / 2, h / 2)
        }
        view.setTransform(matrix)
    }
}

/** The camera opens while the screen is resumed and closes when it pauses or leaves. */
@Composable fun LiveQRPreview(modifier: Modifier, found: (String) -> Unit, failed: () -> Unit) {
    val context = LocalContext.current
    val onFound by rememberUpdatedState(found)
    val onFailed by rememberUpdatedState(failed)
    val scanner = remember { QRScanner(context.applicationContext, { onFound(it) }, { onFailed() }) }
    DisposableEffect(scanner) { onDispose { scanner.close() } }
    LifecycleResumeEffect(scanner) { scanner.resume(); onPauseOrDispose { scanner.pause() } }
    AndroidView({ TextureView(it).also(scanner::attach) }, modifier)
}
