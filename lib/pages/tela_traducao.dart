import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/stt_message.dart';
import '../services/android_audio_capture_service.dart';
import '../services/stt_websocket_service.dart';
import '../services/traducao_service.dart';

class TelaTraducao extends StatefulWidget {
  const TelaTraducao({super.key});

  @override
  State<TelaTraducao> createState() => _TelaTraducaoState();
}

class _TelaTraducaoState extends State<TelaTraducao> {
  final TextEditingController _textoController = TextEditingController();

  final TraducaoService _traducaoService = TraducaoService();
  final SttWebSocketService _sttService = SttWebSocketService();
  final AndroidAudioCaptureService _audioCaptureService =
      AndroidAudioCaptureService();

  StreamSubscription<SttMessage>? _sttSubscription;
  StreamSubscription<Uint8List>? _audioSubscription;

  bool _carregandoTexto = false;
  bool _conectandoVoz = false;
  bool _ouvindo = false;

  String _status = 'Pronto';
  String _textoParcial = '';
  String _textoFinal = '';
  String _gloss = '';

  @override
  void initState() {
    super.initState();

    _sttSubscription = _sttService.mensagens.listen((mensagem) {
      if (!mounted) return;

      setState(() {
        switch (mensagem.type) {
          case 'session_started':
            _status = 'Sessão STT iniciada. Pronto para ouvir.';
            break;

          case 'partial':
            _textoParcial = mensagem.text ?? '';
            _status = 'Ouvindo e transcrevendo...';
            break;

          case 'final':
            _textoFinal = mensagem.text ?? '';
            _textoParcial = '';

            if (mensagem.gloss != null && mensagem.gloss!.trim().isNotEmpty) {
              _gloss = mensagem.gloss!;
              _status = 'Fala traduzida.';
            } else {
              _status =
                  'Texto reconhecido, mas ainda sem tradução Gloss retornada.';
            }
            break;

          case 'error':
            _status = mensagem.errorMessage ?? 'Erro no STT.';
            break;

          case 'closed':
            _status = mensagem.errorMessage ?? 'Conexão STT encerrada.';
            _ouvindo = false;
            break;

          default:
            break;
        }
      });
    });
  }

  Future<void> _traduzirTexto() async {
    setState(() {
      _carregandoTexto = true;
      _status = 'Traduzindo texto...';
      _gloss = '';
      _textoFinal = '';
      _textoParcial = '';
    });

    try {
      final resposta = await _traducaoService.traduzirTexto(
        _textoController.text,
      );

      if (!mounted) return;

      setState(() {
        _gloss = resposta.output;
        _textoFinal = resposta.input;
        _status = 'Texto traduzido.';
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _status = e.toString().replaceFirst('Exception: ', '');
      });
    } finally {
      if (!mounted) return;

      setState(() {
        _carregandoTexto = false;
      });
    }
  }

  Future<void> _alternarVoz() async {
    if (_ouvindo) {
      await _pararVoz();
    } else {
      await _iniciarVoz();
    }
  }

  Future<void> _iniciarVoz() async {
    setState(() {
      _conectandoVoz = true;
      _status = 'Solicitando permissão do microfone...';
      _textoParcial = '';
      _textoFinal = '';
      _gloss = '';
    });

    final permissao = await Permission.microphone.request();

    if (!permissao.isGranted) {
      if (!mounted) return;

      setState(() {
        _conectandoVoz = false;
        _status = 'Permissão de microfone negada.';
      });
      return;
    }

    try {
      if (!mounted) return;

      setState(() {
        _status = 'Conectando ao WebSocket STT...';
      });

      await _sttService.conectar();

      if (!_sttService.conectado) {
        throw Exception('WebSocket STT não confirmou session_started.');
      }
      if (!mounted) return;

      setState(() {
        _status = 'WebSocket STT conectado. Iniciando microfone...';
      });
      await _audioSubscription?.cancel();
      _audioSubscription = _audioCaptureService.audioStream.listen(
        (pcmBytes) {
          if (_sttService.conectado) {
            _sttService.enviarAudio(pcmBytes);
          } else {
            debugPrint(
              'Chunk de áudio ignorado porque o STT ainda não está conectado.',
            );
          }
        },
        onError: (erro) {
          if (!mounted) return;

          setState(() {
            _status = 'Erro na captura de áudio: $erro';
          });
        },
      );

      await Future.delayed(const Duration(milliseconds: 150));

      await _audioCaptureService.start();

      if (!mounted) return;

      setState(() {
        _ouvindo = true;
        _status = 'Ouvindo... fale uma frase e aguarde o resultado.';
      });
    } catch (e) {
      await _pararVoz(silencioso: true);

      if (!mounted) return;

      setState(() {
        _status = e.toString().replaceFirst('Exception: ', '');
      });
    } finally {
      if (!mounted) return;

      setState(() {
        _conectandoVoz = false;
      });
    }
  }

  Future<void> _pararVoz({bool silencioso = false}) async {
    try {
      await _audioCaptureService.stop();
    } catch (_) {}

    try {
      await _audioSubscription?.cancel();
    } catch (_) {}

    _audioSubscription = null;

    try {
      await _sttService.desconectar();
    } catch (_) {}

    if (!mounted) return;

    setState(() {
      _ouvindo = false;

      if (!silencioso) {
        _status = 'Captura de voz encerrada.';
      }
    });
  }

  @override
  void dispose() {
    _textoController.dispose();
    _audioSubscription?.cancel();
    _sttSubscription?.cancel();
    _audioCaptureService.stop();
    _sttService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final corBotaoVoz = _ouvindo ? Colors.red : Colors.indigo;

    return Scaffold(
      appBar: AppBar(title: const Text('ELA - Tradutor PT-BR para LIBRAS')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Tradução por texto',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),

            const SizedBox(height: 12),

            TextField(
              controller: _textoController,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Digite uma frase em português',
                hintText: 'Ex: quero água',
              ),
            ),

            const SizedBox(height: 12),

            ElevatedButton.icon(
              onPressed: _carregandoTexto ? null : _traduzirTexto,
              icon: _carregandoTexto
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.translate),
              label: const Text('Traduzir texto'),
            ),

            const Divider(height: 40),

            const Text(
              'Tradução por voz',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),

            const SizedBox(height: 12),

            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: corBotaoVoz,
                foregroundColor: Colors.white,
              ),
              onPressed: _conectandoVoz ? null : _alternarVoz,
              icon: Icon(_ouvindo ? Icons.stop : Icons.mic),
              label: Text(_ouvindo ? 'Parar voz' : 'Iniciar voz'),
            ),

            const SizedBox(height: 24),

            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'Status: $_status',
                  style: const TextStyle(fontSize: 15),
                ),
              ),
            ),

            if (_textoParcial.isNotEmpty) ...[
              const SizedBox(height: 16),
              const Text(
                'Transcrição parcial:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              Text(_textoParcial),
            ],

            if (_textoFinal.isNotEmpty) ...[
              const SizedBox(height: 16),
              const Text(
                'Texto reconhecido:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              Text(_textoFinal),
            ],

            const SizedBox(height: 24),

            const Text(
              'Resultado em Gloss LIBRAS:',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),

            const SizedBox(height: 8),

            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.grey.shade300),
              ),
              child: Text(
                _gloss.isEmpty ? 'A tradução aparecerá aqui.' : _gloss,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.1,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
