import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import '../models/traducao_response.dart';

class TraducaoService {
  Future<TraducaoResponse> traduzirTexto(String texto) async {
    final textoLimpo = texto.trim();

    if (textoLimpo.isEmpty) {
      throw Exception('Digite um texto para traduzir.');
    }

    final response = await http.post(
      Uri.parse(AppConfig.urlTraducao),
      headers: {'Content-Type': 'application/json; charset=UTF-8'},
      body: jsonEncode({'text': textoLimpo}),
    );

    final Map<String, dynamic> json = jsonDecode(response.body);

    if (response.statusCode == 200) {
      return TraducaoResponse.fromJson(json);
    }

    final erro = json['error']?.toString() ?? 'Erro ao traduzir texto.';
    throw Exception(erro);
  }
}
