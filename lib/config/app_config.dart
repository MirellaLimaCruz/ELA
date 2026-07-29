class AppConfig {
  static const String servidor = '172.16.0.17';

  static const String urlTraducao = 'http://$servidor:5000/translate';
  static const String urlSttWebSocket = 'ws://$servidor:9100/stt';
}
