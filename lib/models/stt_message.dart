class SttMessage {
  final String type;
  final String? sessionId;
  final String? text;
  final String? gloss;
  final String? errorMessage;

  SttMessage({
    required this.type,
    this.sessionId,
    this.text,
    this.gloss,
    this.errorMessage,
  });

  factory SttMessage.fromJson(Map<String, dynamic> json) {
    final dispatch = json['dispatch'];
    final responseBody = dispatch is Map ? dispatch['response_body'] : null;

    String? gloss;
    if (responseBody is Map && responseBody['output'] != null) {
      gloss = responseBody['output'].toString();
    }

    return SttMessage(
      type: json['type']?.toString() ?? '',
      sessionId: json['session_id']?.toString(),
      text: json['text']?.toString(),
      gloss: gloss,
      errorMessage: json['error_message']?.toString(),
    );
  }
}
