class AppConfig {
  // Quando for usar **É DE BOM TOM** trocar o número pelo Ip real do computador/servidor onde estão rodando Flask e FastAP
  // PARA ISSO, rode no terminaL: ipconfig e vai ter algo tipo "Endereço IPv4. . . . . . . .  . . . . . . . : 172.16.0.17"
  // NÃO USE LOCALHOST nem 127.0.0.1 no celular.
  static const String servidor = '127.0.0.1';

  static const String urlTraducao = 'http://$servidor:5000/translate';
  static const String urlSttWebSocket = 'ws://$servidor:9100/stt';
}
