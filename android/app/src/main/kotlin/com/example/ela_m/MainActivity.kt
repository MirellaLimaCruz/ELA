package com.example.ela_m

import android.Manifest
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread
import kotlin.math.abs
import kotlin.math.sqrt

class MainActivity : FlutterActivity() {
    companion object {
        private const val METHOD_CHANNEL = "ela/audio_capture_method"
        private const val EVENT_CHANNEL = "ela/audio_capture_stream"

        private const val SAMPLE_RATE = 16000
        private const val CHUNK_SIZE = 8192
        private const val TAG_AUDIO = "ELA_AUDIO"
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
                Log.d(TAG_AUDIO, "EventChannel conectado.")
            }

            override fun onCancel(arguments: Any?) {
                eventSink = null
                Log.d(TAG_AUDIO, "EventChannel cancelado.")
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

    private fun calcularRmsPcm16(bytes: ByteArray, length: Int): Double {
        if (length < 2) return 0.0

        var somaQuadrados = 0.0
        val totalAmostras = length / 2

        for (i in 0 until totalAmostras) {
            val index = i * 2

            val sample = (
                (bytes[index + 1].toInt() shl 8) or
                (bytes[index].toInt() and 0xFF)
            ).toShort().toInt()

            somaQuadrados += sample.toDouble() * sample.toDouble()
        }

        return sqrt(somaQuadrados / totalAmostras)
    }

    private fun calcularMaxAbsPcm16(bytes: ByteArray, length: Int): Int {
        if (length < 2) return 0

        var maxAbs = 0
        val totalAmostras = length / 2

        for (i in 0 until totalAmostras) {
            val index = i * 2

            val sample = (
                (bytes[index + 1].toInt() shl 8) or
                (bytes[index].toInt() and 0xFF)
            ).toShort().toInt()

            val absValue = abs(sample)

            if (absValue > maxAbs) {
                maxAbs = absValue
            }
        }

        return maxAbs
    }

    @Suppress("MissingPermission")
    private fun startRecording(result: MethodChannel.Result) {
        if (isRecording.get()) {
            Log.d(TAG_AUDIO, "startRecording chamado, mas já estava gravando.")
            result.success(true)
            return
        }

        if (!hasRecordAudioPermission()) {
            Log.e(TAG_AUDIO, "Permissão de microfone não concedida.")
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

            Log.d(TAG_AUDIO, "minBufferSize=$minBufferSize")

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

            Log.d(
                TAG_AUDIO,
                "Criando AudioRecord: sampleRate=$SAMPLE_RATE, chunkSize=$CHUNK_SIZE, internalBufferSize=$internalBufferSize"
            )

            val recorder = AudioRecord(
                MediaRecorder.AudioSource.VOICE_RECOGNITION,
                SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                internalBufferSize
            )

            if (recorder.state != AudioRecord.STATE_INITIALIZED) {
                recorder.release()
                Log.e(TAG_AUDIO, "AudioRecord não inicializou.")
                result.error(
                    "AUDIO_RECORD_ERROR",
                    "AudioRecord não foi inicializado corretamente.",
                    null
                )
                return
            }

            audioRecord = recorder

            recorder.startRecording()

            Log.d(TAG_AUDIO, "recordingState=${recorder.recordingState}")

            if (recorder.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
                recorder.release()
                audioRecord = null

                result.error(
                    "AUDIO_RECORD_NOT_RECORDING",
                    "AudioRecord inicializou, mas não entrou em modo de gravação.",
                    null
                )
                return
            }

            isRecording.set(true)

            recordingThread = thread(
                start = true,
                name = "ELA-AudioRecord-Thread"
            ) {
                val buffer = ByteArray(CHUNK_SIZE)
                var contadorChunks = 0

                Log.d(TAG_AUDIO, "Thread de captura iniciada.")

                while (isRecording.get()) {
                    val bytesRead = recorder.read(buffer, 0, buffer.size)

                    if (bytesRead > 0) {
                        val chunk = buffer.copyOf(bytesRead)

                        contadorChunks++

                        if (contadorChunks % 10 == 0) {
                            val rms = calcularRmsPcm16(chunk, bytesRead)
                            val maxAbs = calcularMaxAbsPcm16(chunk, bytesRead)

                            Log.d(
                                TAG_AUDIO,
                                "NATIVE AUDIO DEBUG: chunk=$contadorChunks, bytes=$bytesRead, rms=${"%.2f".format(rms)}, maxAbs=$maxAbs"
                            )
                        }

                        mainHandler.post {
                            eventSink?.success(chunk)
                        }
                    } else if (bytesRead == 0) {
                        Log.w(TAG_AUDIO, "AudioRecord.read retornou 0 bytes.")
                    } else {
                        Log.e(
                            TAG_AUDIO,
                            "Erro ao ler áudio do microfone. Código: $bytesRead"
                        )

                        mainHandler.post {
                            eventSink?.error(
                                "AUDIO_READ_ERROR",
                                "Erro ao ler áudio do microfone. Código: $bytesRead",
                                null
                            )
                        }
                    }
                }

                Log.d(TAG_AUDIO, "Thread de captura encerrada.")
            }

            Log.d(TAG_AUDIO, "Captura de áudio iniciada com sucesso.")
            result.success(true)
        } catch (e: Exception) {
            Log.e(TAG_AUDIO, "Erro ao iniciar gravação: ${e.message}", e)

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

        Log.d(TAG_AUDIO, "Parando captura de áudio...")

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

        Log.d(TAG_AUDIO, "Captura de áudio encerrada.")
    }

    override fun onDestroy() {
        stopRecording()
        super.onDestroy()
    }
}