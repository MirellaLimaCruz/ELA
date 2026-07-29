import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../config/app_config.dart';
import '../models/stt_message.dart';

class SttWebSocketService {
  WebSocketChannel? _channel;
  StreamSubscription? _channelSubscription;

  bool _conectado = false;
  int _contadorChunksEnviados = 0;

  Completer<void>? _sessionStartedCompleter;

  final StreamController<SttMessage> _mensagensController =
      StreamController<SttMessage>.broadcast();

  Stream<SttMessage> get mensagens => _mensagensController.stream;

  bool get conectado => _conectado;

  Future<void> conectar() async {
    if (_conectado && _channel != null) {
      debugPrint('STT WebSocket já está conectado.');
      return;
    }

    await desconectar();

    final uri = Uri.parse(AppConfig.urlSttWebSocket);
    _contadorChunksEnviados = 0;
    debugPrint('Tentando conectar ao STT WebSocket: $uri');

    _sessionStartedCompleter = Completer<void>();

    try {
      final channel = IOWebSocketChannel.connect(
        uri,
        pingInterval: const Duration(seconds: 20),
        connectTimeout: const Duration(seconds: 10),
      );

      _channel = channel;

      _channelSubscription = channel.stream.listen(
        (event) {
          debugPrint('Mensagem recebida do STT: $event');

          if (event is! String) {
            return;
          }

          try {
            final Map<String, dynamic> json = jsonDecode(event);
            final mensagem = SttMessage.fromJson(json);

            if (mensagem.type == 'session_started') {
              _conectado = true;

              if (_sessionStartedCompleter != null &&
                  !_sessionStartedCompleter!.isCompleted) {
                _sessionStartedCompleter!.complete();
              }
            }

            if (mensagem.type == 'error') {
              debugPrint(
                'Mensagem de erro recebida do STT: ${mensagem.errorMessage}',
              );
            }

            _mensagensController.add(mensagem);
          } catch (e) {
            debugPrint('Erro ao interpretar mensagem do STT: $e');

            _mensagensController.add(
              SttMessage(
                type: 'error',
                errorMessage: 'Erro ao interpretar mensagem do STT: $e',
              ),
            );
          }
        },
        onError: (erro) {
          debugPrint('Erro no stream WebSocket STT: $erro');

          if (_sessionStartedCompleter != null &&
              !_sessionStartedCompleter!.isCompleted) {
            _sessionStartedCompleter!.completeError(erro);
          }

          _mensagensController.add(
            SttMessage(
              type: 'error',
              errorMessage: 'Erro no WebSocket STT: $erro',
            ),
          );

          _limparConexao();
        },
        onDone: () {
          debugPrint('WebSocket STT encerrado.');

          if (_sessionStartedCompleter != null &&
              !_sessionStartedCompleter!.isCompleted) {
            _sessionStartedCompleter!.completeError(
              Exception('WebSocket foi encerrado antes de iniciar a sessão.'),
            );
          }

          _mensagensController.add(
            SttMessage(type: 'closed', errorMessage: 'Conexão STT encerrada.'),
          );

          _limparConexao();
        },
        cancelOnError: false,
      );

      await channel.ready.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          throw TimeoutException(
            'Timeout aguardando abertura do WebSocket STT.',
          );
        },
      );

      debugPrint('Canal WebSocket aberto. Aguardando session_started...');

      await _sessionStartedCompleter!.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          throw TimeoutException('Timeout aguardando session_started do STT.');
        },
      );

      debugPrint(
        'Sessão STT iniciada com sucesso. WebSocket pronto para áudio.',
      );
    } catch (e) {
      debugPrint('Falha ao conectar no STT: $e');

      await desconectar();

      throw Exception('Não foi possível conectar ao STT: $e');
    }
  }

  void enviarAudio(Uint8List pcmBytes) {
    if (!_conectado || _channel == null) {
      debugPrint(
        'Tentou enviar áudio, mas o WebSocket STT não está conectado.',
      );
      return;
    }

    if (pcmBytes.isEmpty) {
      return;
    }

    try {
      _contadorChunksEnviados++;
      if (_contadorChunksEnviados % 20 == 0) {
        debugPrint(
          'Enviando áudio para STT: chunk $_contadorChunksEnviados, ${pcmBytes.length} bytes',
        );
      }

      _channel!.sink.add(pcmBytes);
    } catch (e) {
      debugPrint('Erro ao enviar áudio para STT: $e');

      _mensagensController.add(
        SttMessage(
          type: 'error',
          errorMessage: 'Erro ao enviar áudio para STT: $e',
        ),
      );
    }
  }

  Future<void> desconectar() async {
    _conectado = false;

    try {
      await _channelSubscription?.cancel();
    } catch (_) {}

    _channelSubscription = null;

    try {
      await _channel?.sink.close();
    } catch (_) {}

    _channel = null;
    _sessionStartedCompleter = null;
  }

  void _limparConexao() {
    _conectado = false;
    _channelSubscription = null;
    _channel = null;
    _sessionStartedCompleter = null;
  }

  Future<void> dispose() async {
    await desconectar();
    await _mensagensController.close();
  }
}
