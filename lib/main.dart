import 'package:flutter/material.dart';

import 'pages/tela_traducao.dart';

void main() {
  runApp(const ElaApp());
}

class ElaApp extends StatelessWidget {
  const ElaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ELA Mobile',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: const TelaTraducao(),
    );
  }
}
