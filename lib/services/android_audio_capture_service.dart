import 'dart:typed_data';

import 'package:flutter/services.dart';

class AndroidAudioCaptureService {
  static const MethodChannel _methodChannel = MethodChannel(
    'ela/audio_capture_method',
  );

  static const EventChannel _eventChannel = EventChannel(
    'ela/audio_capture_stream',
  );

  Stream<Uint8List> get audioStream {
    return _eventChannel.receiveBroadcastStream().map<Uint8List>((event) {
      if (event is Uint8List) {
        return event;
      }

      if (event is List<int>) {
        return Uint8List.fromList(event);
      }

      throw PlatformException(
        code: 'INVALID_AUDIO_CHUNK',
        message: 'Chunk de áudio recebido em formato inválido.',
      );
    });
  }

  Future<void> start() async {
    await _methodChannel.invokeMethod<bool>('start');
  }

  Future<void> stop() async {
    await _methodChannel.invokeMethod<bool>('stop');
  }

  Future<bool> isRecording() async {
    final result = await _methodChannel.invokeMethod<bool>('isRecording');
    return result ?? false;
  }
}
