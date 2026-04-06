class ResolvedAction {
  final String sourceType;
  final String sourceId;
  final String actionId;
  final Map<String, dynamic> parameters;
  final String confirmationMessage;

  ResolvedAction({
    required this.sourceType,
    required this.sourceId,
    required this.actionId,
    required this.parameters,
    required this.confirmationMessage,
  });

  factory ResolvedAction.fromJson(Map<String, dynamic> json) {
    return ResolvedAction(
      sourceType: json['sourceType'] as String,
      sourceId: json['sourceId'] as String,
      actionId: json['actionId'] as String,
      parameters: json['parameters'] as Map<String, dynamic>? ?? {},
      confirmationMessage: json['confirmationMessage'] as String,
    );
  }
}
