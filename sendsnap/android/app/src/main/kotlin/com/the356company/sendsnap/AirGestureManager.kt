package com.the356company.sendsnap

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Matrix
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Size
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import com.google.mediapipe.framework.image.BitmapImageBuilder
import com.google.mediapipe.tasks.core.BaseOptions
import com.google.mediapipe.tasks.vision.core.RunningMode
import com.google.mediapipe.tasks.vision.handlandmarker.HandLandmarker
import com.google.mediapipe.tasks.vision.handlandmarker.HandLandmarkerResult
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

class AirGestureManager(
    private val context: Context,
    private val lifecycleOwner: LifecycleOwner,
) {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val lock = Any()

    private var handLandmarker: HandLandmarker? = null
    private var cameraProvider: ProcessCameraProvider? = null
    private var analysisExecutor: ExecutorService? = null

    @Volatile
    private var isRunning = false

    @Volatile
    private var lastEmitTimeMs = 0L

    @Volatile
    private var lastProcessedTimeMs = 0L

    private var frameCallback: ((Map<String, Any>) -> Unit)? = null
    private var errorCallback: ((String) -> Unit)? = null

    fun isSupported(): Boolean {
        return context.packageManager.hasSystemFeature(PackageManager.FEATURE_CAMERA_FRONT)
    }

    fun start(
        onFrame: (Map<String, Any>) -> Unit,
        onError: (String) -> Unit,
    ) {
        if (!isSupported()) {
            onError("Front camera is not available on this device.")
            return
        }

        val cameraPermission = ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.CAMERA,
        )
        if (cameraPermission != PackageManager.PERMISSION_GRANTED) {
            onError("Camera permission is required for Air Gestures.")
            return
        }

        stop()

        frameCallback = onFrame
        errorCallback = onError
        lastEmitTimeMs = 0L
        lastProcessedTimeMs = 0L

        val executor = Executors.newSingleThreadExecutor()
        analysisExecutor = executor

        try {
            val baseOptions = BaseOptions.builder()
                .setModelAssetPath("hand_landmarker.task")
                .build()

            val options = HandLandmarker.HandLandmarkerOptions.builder()
                .setBaseOptions(baseOptions)
                .setRunningMode(RunningMode.LIVE_STREAM)
                .setNumHands(1)
                .setMinHandDetectionConfidence(0.5f)
                .setMinHandPresenceConfidence(0.5f)
                .setMinTrackingConfidence(0.5f)
                .setResultListener { result, _ -> handleResult(result) }
                .setErrorListener { error ->
                    errorCallback?.invoke(error.message ?: "Hand detection error")
                }
                .build()

            synchronized(lock) {
                handLandmarker = HandLandmarker.createFromOptions(context, options)
            }
            isRunning = true

            val cameraProviderFuture = ProcessCameraProvider.getInstance(context)
            cameraProviderFuture.addListener({
                if (!isRunning) return@addListener
                try {
                    val provider = cameraProviderFuture.get()
                    cameraProvider = provider

                    val resolutionSelector = ResolutionSelector.Builder()
                        .setResolutionStrategy(
                            ResolutionStrategy(
                                Size(320, 240),
                                ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER,
                            ),
                        )
                        .build()

                    val imageAnalyzer = ImageAnalysis.Builder()
                        .setResolutionSelector(resolutionSelector)
                        .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                        .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_RGBA_8888)
                        .build()
                        .also { analysis ->
                            analysis.setAnalyzer(executor) { imageProxy ->
                                processImageProxy(imageProxy)
                            }
                        }

                    provider.unbindAll()
                    provider.bindToLifecycle(
                        lifecycleOwner,
                        CameraSelector.DEFAULT_FRONT_CAMERA,
                        imageAnalyzer,
                    )
                } catch (t: Throwable) {
                    val cb = errorCallback
                    stop()
                    cb?.invoke(t.message ?: "Failed to start front camera")
                }
            }, ContextCompat.getMainExecutor(context))
        } catch (t: Throwable) {
            stop()
            onError(t.message ?: "Failed to initialize HandLandmarker")
        }
    }

    private fun processImageProxy(imageProxy: ImageProxy) {
        try {
            if (!isRunning) return

            val now = SystemClock.uptimeMillis()
            if (now - lastProcessedTimeMs < 80L) return
            lastProcessedTimeMs = now

            val bitmapBuffer = imageProxy.toBitmap()
            val matrix = Matrix().apply {
                postRotate(imageProxy.imageInfo.rotationDegrees.toFloat())
                postScale(-1f, 1f)
            }
            val rotatedBitmap = Bitmap.createBitmap(
                bitmapBuffer,
                0,
                0,
                bitmapBuffer.width,
                bitmapBuffer.height,
                matrix,
                true,
            )
            if (rotatedBitmap != bitmapBuffer) {
                bitmapBuffer.recycle()
            }

            val mpImage = BitmapImageBuilder(rotatedBitmap).build()
            val frameTime = SystemClock.uptimeMillis()

            synchronized(lock) {
                if (isRunning) {
                    handLandmarker?.detectAsync(mpImage, frameTime)
                }
            }
        } catch (_: Exception) {
            // Ignore transient frame processing errors during shutdown
        } finally {
            imageProxy.close()
        }
    }

    private fun handleResult(result: HandLandmarkerResult) {
        if (!isRunning) return

        val now = SystemClock.uptimeMillis()
        if (now - lastEmitTimeMs < 35L) return
        lastEmitTimeMs = now

        val firstHand = result.landmarks().firstOrNull()
        val landmarksList: List<Map<String, Double>> = if (firstHand != null && firstHand.size >= 21) {
            firstHand.map { lm ->
                mapOf(
                    "x" to lm.x().toDouble(),
                    "y" to lm.y().toDouble(),
                    "z" to lm.z().toDouble(),
                )
            }
        } else {
            emptyList()
        }

        val payload = mapOf<String, Any>(
            "detected" to landmarksList.isNotEmpty(),
            "timestampMs" to result.timestampMs(),
            "landmarks" to landmarksList,
        )
        frameCallback?.invoke(payload)
    }

    fun stop() {
        isRunning = false
        frameCallback = null
        errorCallback = null

        val provider = cameraProvider
        cameraProvider = null
        if (provider != null) {
            if (Looper.myLooper() == Looper.getMainLooper()) {
                try {
                    provider.unbindAll()
                } catch (_: Exception) {}
            } else {
                mainHandler.post {
                    try {
                        provider.unbindAll()
                    } catch (_: Exception) {}
                }
            }
        }

        synchronized(lock) {
            try {
                handLandmarker?.close()
            } catch (_: Exception) {}
            handLandmarker = null
        }

        try {
            analysisExecutor?.shutdownNow()
        } catch (_: Exception) {}
        analysisExecutor = null
    }

    fun dispose() {
        stop()
    }
}
