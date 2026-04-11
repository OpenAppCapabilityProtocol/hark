import 'dart:async';

import 'package:hark_platform/hark_platform.dart';

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

  factory OacpResult.fromMessage(OacpResultMessage msg) {
    return OacpResult(
      requestId: msg.requestId,
      status: msg.status,
      capabilityId: msg.capabilityId,
      message: msg.message,
      error: msg.error,
      sourcePackage: msg.sourcePackage,
      result: msg.result,
    );
  }
}

/// Receives OACP result broadcasts from native via [HarkResultFlutterApi].
///
/// The plugin's BroadcastReceiver forwards results through Pigeon's FlutterApi
/// callback, which this class implements. Results are exposed as a broadcast
/// [Stream<OacpResult>].
class OacpResultService implements HarkResultFlutterApi {
  OacpResultService() {
    HarkResultFlutterApi.setUp(this);
  }

  final _resultController = StreamController<OacpResult>.broadcast();
  final _wakeWordController = StreamController<void>.broadcast();

  Stream<OacpResult> get results => _resultController.stream;
  Stream<void> get wakeWordDetections => _wakeWordController.stream;

  @override
  void onOacpResult(OacpResultMessage result) {
    _resultController.add(OacpResult.fromMessage(result));
  }

  @override
  void onWakeWordDetected() {
    _wakeWordController.add(null);
  }

  void dispose() {
    HarkResultFlutterApi.setUp(null);
    _resultController.close();
    _wakeWordController.close();
  }
}
