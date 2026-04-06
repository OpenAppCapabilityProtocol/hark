import 'dart:async';

import 'package:flutter/services.dart';

class OacpResult {
  const OacpResult({
    this.requestId,
    this.status = 'completed',
    this.capabilityId,
    this.message,
    this.error,
    this.sourcePackage,
    this.result,
  });

  final String? requestId;
  final String status;
  final String? capabilityId;
  final String? message;
  final String? error;
  final String? sourcePackage;
  final String? result;

  bool get isSuccess => status == 'completed';
  bool get isFailure => status == 'failed';

  String get displayMessage {
    if (message != null && message!.isNotEmpty) return message!;
    if (error != null && error!.isNotEmpty) return 'Error: $error';
    if (isSuccess) return 'Action completed.';
    return 'Action failed.';
  }
}

class OacpResultService {
  static const _channel = EventChannel('com.oacp.hark/results');

  Stream<OacpResult>? _stream;

  Stream<OacpResult> get results {
    _stream ??= _channel.receiveBroadcastStream().where((event) {
      return event is Map;
    }).map((event) {
      final map = Map<String, dynamic>.from(event as Map);
      return OacpResult(
        requestId: map['requestId'] as String?,
        status: (map['status'] as String?) ?? 'completed',
        capabilityId: map['capabilityId'] as String?,
        message: map['message'] as String?,
        error: map['error'] as String?,
        sourcePackage: map['sourcePackage'] as String?,
        result: map['result'] as String?,
      );
    });
    return _stream!;
  }
}
