package com.example.ela_m

import android.Manifest
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

class MainActivity : FlutterActivity() {
    companion object {
        private const val METHOD_CHANNEL = "ela/audio_capture_method"
        private const val EVENT_CHANNEL = "ela/audio_capture_stream"

        private const val SAMPLE_RATE = 16000
        private const val CHUNK_SIZE = 8192
    }

    private var eventSink: EventChannel.EventSink? = null
    private var audioRecord: AudioRecord? = null
    private var recordingThread: Thread? = null

    private val isRecording = AtomicBoolean(false)
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            EVENT_CHANNEL
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                eventSink = events
            }

            override fun onCancel(arguments: Any?) {
                eventSink = null
            }
        })

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            METHOD_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> startRecording(result)
                "stop" -> {
                    stopRecording()
                    result.success(true)
                }
                "isRecording" -> {
                    result.success(isRecording.get())
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun hasRecordAudioPermission(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
        } else {
            true
        }
    }

    @Suppress("MissingPermission")
    private fun startRecording(result: MethodChannel.Result) {
        if (isRecording.get()) {
            result.success(true)
            return
        }

        if (!hasRecordAudioPermission()) {
            result.error(
                "NO_PERMISSION",
                "Permissão de microfone não concedida.",
                null
            )
            return
        }

        try {
            val minBufferSize = AudioRecord.getMinBufferSize(
                SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT
            )

            if (
                minBufferSize == AudioRecord.ERROR ||
                minBufferSize == AudioRecord.ERROR_BAD_VALUE
            ) {
                result.error(
                    "BUFFER_ERROR",
                    "Não foi possível calcular o buffer mínimo do AudioRecord.",
                    null
                )
                return
            }

            val internalBufferSize = maxOf(minBufferSize, CHUNK_SIZE * 2)

            val recorder = AudioRecord(
                MediaRecorder.AudioSource.MIC,
                SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                internalBufferSize
            )

            if (recorder.state != AudioRecord.STATE_INITIALIZED) {
                recorder.release()
                result.error(
                    "AUDIO_RECORD_ERROR",
                    "AudioRecord não foi inicializado corretamente.",
                    null
                )
                return
            }

            audioRecord = recorder
            recorder.startRecording()
            isRecording.set(true)

            recordingThread = thread(
                start = true,
                name = "ELA-AudioRecord-Thread"
            ) {
                val buffer = ByteArray(CHUNK_SIZE)

                while (isRecording.get()) {
                    val bytesRead = recorder.read(buffer, 0, buffer.size)

                    if (bytesRead > 0) {
                        val chunk = buffer.copyOf(bytesRead)

                        mainHandler.post {
                            eventSink?.success(chunk)
                        }
                    } else if (bytesRead < 0) {
                        mainHandler.post {
                            eventSink?.error(
                                "AUDIO_READ_ERROR",
                                "Erro ao ler áudio do microfone. Código: $bytesRead",
                                null
                            )
                        }
                    }
                }
            }

            result.success(true)
        } catch (e: Exception) {
            stopRecording()
            result.error(
                "START_RECORDING_ERROR",
                e.message ?: "Erro inesperado ao iniciar gravação.",
                null
            )
        }
    }

    private fun stopRecording() {
        if (!isRecording.get()) {
            return
        }

        isRecording.set(false)

        try {
            recordingThread?.join(500)
        } catch (_: Exception) {
        }

        recordingThread = null

        try {
            audioRecord?.stop()
        } catch (_: Exception) {
        }

        try {
            audioRecord?.release()
        } catch (_: Exception) {
        }

        audioRecord = null
    }

    override fun onDestroy() {
        stopRecording()
        super.onDestroy()
    }
}