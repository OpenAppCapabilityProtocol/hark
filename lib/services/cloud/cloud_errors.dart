/// Error types thrown by [HarkLlmClient] implementations. The resolver
/// (Slice 4) classifies cloud failures via these so it knows whether to
/// fall back to the on-device slot filler or surface a hard error.
///
/// Adapters MUST use these exact types — not generic `Exception` — so
/// the resolver's catch can be precise.
library;

/// Recoverable cloud failure. The resolver in `CLOUD_PREFERRED` mode
/// falls back to the on-device slot filler; in `CLOUD_ONLY` mode it
/// surfaces as a hard error.
///
/// Use for:
/// - Network errors (DNS, timeout, connection refused, TLS)
/// - HTTP 401 (auth failure — recoverable in the sense that user can
///   fix it in settings, but immediate fallback is still desired)
/// - HTTP 429 (rate limit — fallback now, retry later)
/// - HTTP 5xx
/// - Malformed JSON in response body
/// - Tool-call output that fails to parse as JSON
class CloudUnavailableError implements Exception {
  CloudUnavailableError(this.message, {this.cause, this.statusCode});

  final String message;
  final Object? cause;
  final int? statusCode;

  @override
  String toString() {
    final parts = <String>['CloudUnavailableError: $message'];
    if (statusCode != null) parts.add('(HTTP $statusCode)');
    if (cause != null) parts.add('cause: $cause');
    return parts.join(' ');
  }
}

/// Unrecoverable cloud failure that the user must fix in settings.
/// The resolver does NOT fall back to local — instead it surfaces the
/// error to the UI with a suggestion to open the Cloud Brain screen.
///
/// Use for:
/// - Invalid base URL / unparseable
/// - Deployment / model not found (HTTP 404)
/// - Schema translation produced an empty tool definition (action has
///   no parameters and adapter cannot fall back to a no-tool call)
/// - Configuration is structurally broken (missing api version on
///   Azure, etc.)
class CloudHardError implements Exception {
  CloudHardError(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => 'CloudHardError: $message'
      '${cause != null ? ' (cause: $cause)' : ''}';
}
