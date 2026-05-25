class TraducaoResponse {
  final bool success;
  final String input;
  final String output;
  final String method;
  final double confidence;

  TraducaoResponse({
    required this.success,
    required this.input,
    required this.output,
    required this.method,
    required this.confidence,
  });

  factory TraducaoResponse.fromJson(Map<String, dynamic> json) {
    return TraducaoResponse(
      success: json['success'] == true,
      input: json['input']?.toString() ?? '',
      output: json['output']?.toString() ?? '',
      method: json['method']?.toString() ?? '',
      confidence: double.tryParse(json['confidence']?.toString() ?? '0') ?? 0.0,
    );
  }
}
