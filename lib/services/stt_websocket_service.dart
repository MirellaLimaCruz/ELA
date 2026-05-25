import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../config/app_config.dart';
import '../models/stt_message.dart';

class SttWebSocketService {
  WebSocket? _socket;
  StreamSubscription? _socketSubscription;

  final StreamController<SttMessage> _mensagensController =
      StreamController<SttMessage>.broadcast();

  Stream<SttMessage> get mensagens => _mensagensController.stream;

  bool get conectado => _socket != null;

  Future<void> conectar() async {
    if (_socket != null) {
      return;
    }

    try {
      _socket = await WebSocket.connect(AppConfig.urlSttWebSocket);

      _socketSubscription = _socket!.listen(
        (event) {
          if (event is String) {
            final Map<String, dynamic> json = jsonDecode(event);
            final mensagem = SttMessage.fromJson(json);
            _mensagensController.add(mensagem);
          }
        },
        onError: (erro) {
          _mensagensController.add(
            SttMessage(type: 'error', errorMessage: 'Erro no WebSocket: $erro'),
          );
          desconectar();
        },
        onDone: () {
          _mensagensController.add(
            SttMessage(
              type: 'closed',
              errorMessage: 'Conexão WebSocket encerrada.',
            ),
          );
          _socket = null;
        },
      );
    } catch (e) {
      _socket = null;
      throw Exception('Não foi possível conectar ao STT: $e');
    }
  }

  void enviarAudio(Uint8List pcmBytes) {
    if (_socket == null) {
      return;
    }

    _socket!.add(pcmBytes);
  }

  Future<void> desconectar() async {
    await _socketSubscription?.cancel();
    _socketSubscription = null;

    await _socket?.close(WebSocketStatus.normalClosure, 'Sessão encerrada');
    _socket = null;
  }

  Future<void> dispose() async {
    await desconectar();
    await _mensagensController.close();
  }
}
