import 'dart:async';
import 'dart:math' as math;
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
  int _contadorChunksAudio = 0;

  String _status = 'Pronto';
  String _textoParcial = '';
  String _textoFinal = '';
  String _gloss = '';

  double _rmsAtualAudio = 0.0;
  String _estadoCapturaAudio = 'Aguardando início da gravação.';
  String _textoCapturadoPortugues = '';
  String _ultimoTextoFinalPortugues = '';

  Timer? _debounceTraducaoVoz;
  String _ultimoTextoVozTraduzido = '';
  bool _traduzindoVoz = false;

  @override
  void initState() {
    super.initState();

    _sttSubscription = _sttService.mensagens.listen((mensagem) {
      if (!mounted) return;

      final textoRecebido = mensagem.text?.trim() ?? '';

      setState(() {
        switch (mensagem.type) {
          case 'session_started':
            _status = 'Sessão STT iniciada. Pronto para ouvir.';
            _estadoCapturaAudio = 'Conectado ao STT. Aguardando áudio...';
            break;

          case 'partial':
            _textoParcial = mensagem.text ?? '';
            _textoCapturadoPortugues = mensagem.text ?? '';
            _status = 'Ouvindo e transcrevendo...';
            _estadoCapturaAudio = 'STT retornou uma transcrição parcial.';
            break;

          case 'final':
            _textoFinal = mensagem.text ?? '';
            _ultimoTextoFinalPortugues = mensagem.text ?? '';
            _textoCapturadoPortugues = mensagem.text ?? '';
            _textoParcial = '';

            if (mensagem.gloss != null && mensagem.gloss!.trim().isNotEmpty) {
              _gloss = mensagem.gloss!;
              _status = 'Fala traduzida.';
              _estadoCapturaAudio = 'STT retornou texto e Gloss.';
            } else {
              _status =
                  'Texto reconhecido, mas ainda sem tradução Gloss retornada.';
              _estadoCapturaAudio =
                  'STT retornou texto em português, mas sem Gloss.';
            }
            break;

          case 'error':
            _status = mensagem.errorMessage ?? 'Erro no STT.';
            _estadoCapturaAudio = 'Erro recebido do STT.';
            _ouvindo = false;

            Future.microtask(() => _pararVoz(silencioso: true));
            break;

          case 'closed':
            _status = mensagem.errorMessage ?? 'Conexão STT encerrada.';
            _ouvindo = false;
            break;

          default:
            break;
        }
      });

      if ((mensagem.type == 'partial' || mensagem.type == 'final') &&
          textoRecebido.isNotEmpty) {
        _agendarTraducaoDaVoz(textoRecebido);
      }
    });
  }

  double _calcularRmsPcm16(Uint8List bytes) {
    if (bytes.length < 2) {
      return 0.0;
    }

    final byteData = ByteData.sublistView(bytes);

    int quantidadeAmostras = bytes.length ~/ 2;
    double somaQuadrados = 0.0;

    for (int i = 0; i < quantidadeAmostras; i++) {
      final amostra = byteData.getInt16(i * 2, Endian.little);
      somaQuadrados += amostra * amostra;
    }

    return math.sqrt(somaQuadrados / quantidadeAmostras);
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
      _contadorChunksAudio = 0;

      _rmsAtualAudio = 0.0;
      _estadoCapturaAudio = 'Preparando microfone...';
      _textoCapturadoPortugues = '';
      _ultimoTextoFinalPortugues = '';
      _ultimoTextoVozTraduzido = '';
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
          final rms = _calcularRmsPcm16(pcmBytes);

          _contadorChunksAudio++;

          if (_contadorChunksAudio % 10 == 0) {
            if (mounted) {
              setState(() {
                _rmsAtualAudio = rms;

                if (rms <= 20) {
                  _estadoCapturaAudio =
                      'Silêncio ou micrfone praticamente mudo.';
                } else if (rms < 80) {
                  _estadoCapturaAudio = 'Áudo muito baixo detectado.';
                } else if (rms < 250) {
                  _estadoCapturaAudio =
                      'áudio detectado. Fale um pouco mais alto ou mais perto.';
                } else {
                  _estadoCapturaAudio =
                      'Voz/áudio forte detectado. Aguardando retorno do STT.';
                }
              });
            }

            debugPrint(
              'AUDIO DEBUG: chunk=$_contadorChunksAudio, bytes=${pcmBytes.length}, rms=${rms.toStringAsFixed(2)}',
            );
          }

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
            _estadoCapturaAudio = 'Erro na captura de áudio.';
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
    _debounceTraducaoVoz?.cancel();
    _textoController.dispose();
    _audioSubscription?.cancel();
    _sttSubscription?.cancel();
    _audioCaptureService.stop();
    _sttService.dispose();
    super.dispose();
  }

  Widget _buildCaixaCapturaAudio() {
    final progressoRms = (_rmsAtualAudio / 1000).clamp(0.0, 1.0);

    return Card(
      color: Colors.blueGrey.shade50,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'O que a voz está capturando',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
            ),

            const SizedBox(height: 12),

            Text(
              'Volume capturado: ${_rmsAtualAudio.toStringAsFixed(2)} RMS',
              style: const TextStyle(fontSize: 14),
            ),

            const SizedBox(height: 8),

            LinearProgressIndicator(value: progressoRms),

            const SizedBox(height: 12),

            const Text(
              'Estado da captura:',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),

            const SizedBox(height: 4),

            Text(_estadoCapturaAudio),

            const SizedBox(height: 12),

            const Text(
              'Português escutado pelo STT:',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),

            const SizedBox(height: 4),

            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.blueGrey.shade100),
              ),
              child: Text(
                _textoCapturadoPortugues.trim().isEmpty
                    ? 'Ainda não recebi texto do STT.'
                    : _textoCapturadoPortugues,
                style: const TextStyle(fontSize: 16),
              ),
            ),

            const SizedBox(height: 12),

            const Text(
              'Último texto final confirmado:',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),

            const SizedBox(height: 4),

            Text(
              _ultimoTextoFinalPortugues.trim().isEmpty
                  ? 'Nenhum texto final ainda.'
                  : _ultimoTextoFinalPortugues,
            ),
          ],
        ),
      ),
    );
  }

  void _agendarTraducaoDaVoz(String texto) {
    final textoLimpo = texto.trim();

    if (textoLimpo.isEmpty) {
      return;
    }

    if (textoLimpo == _ultimoTextoVozTraduzido) {
      return;
    }

    _debounceTraducaoVoz?.cancel();

    _debounceTraducaoVoz = Timer(const Duration(milliseconds: 1200), () {
      _traduzirTextoCapturadoDaVoz(textoLimpo);
    });
  }

  Future<void> _traduzirTextoCapturadoDaVoz(String texto) async {
    final textoLimpo = texto.trim();

    if (textoLimpo.isEmpty) {
      return;
    }

    if (textoLimpo == _ultimoTextoVozTraduzido) {
      return;
    }

    if (_traduzindoVoz) {
      return;
    }

    _traduzindoVoz = true;

    if (mounted) {
      setState(() {
        _status = 'Traduzindo fala capturada para Gloss...';
      });
    }

    try {
      final resposta = await _traducaoService.traduzirTexto(textoLimpo);

      if (!mounted) return;

      setState(() {
        _ultimoTextoVozTraduzido = textoLimpo;
        _textoFinal = textoLimpo;
        _ultimoTextoFinalPortugues = textoLimpo;
        _gloss = resposta.output;
        _status = 'Fala traduzida para Gloss.';
        _estadoCapturaAudio = 'Texto capturado e traduzido para Gloss.';
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _status =
            'Erro ao traduzir fala capturada: ${e.toString().replaceFirst('Exception: ', '')}';
        _estadoCapturaAudio = 'STT ouviu, mas a tradução para Gloss falhou.';
      });
    } finally {
      _traduzindoVoz = false;
    }
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

            const SizedBox(height: 12),
            _buildCaixaCapturaAudio(),

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
