# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in Hark, please report it responsibly.

**Do not open a public GitHub issue for security vulnerabilities.**

Instead, email: **security@oacp.dev** (or contact [@0xharkirat](https://github.com/0xharkirat) directly)

Please include:

- Description of the vulnerability
- Steps to reproduce
- Affected versions
- Any potential impact

We will acknowledge receipt within 48 hours and aim to provide a fix or mitigation within 7 days for critical issues.

## Scope

This policy covers:

- The Hark voice assistant application
- On-device model handling and storage
- OACP app discovery and intent dispatch
- Voice input processing

## Security Model

Hark uses Android's standard security mechanisms:

- **Voice input**: Processed on-device via Android's SpeechRecognizer. No raw audio is stored or transmitted by Hark.
- **On-device AI**: All intent resolution runs locally using on-device models. No voice commands are sent to external servers in the default configuration.
- **App discovery**: Read-only ContentProvider queries. Hark cannot modify other apps' data.
- **Intent dispatch**: Uses Android's standard Intent system with explicit component targeting. Apps must declare `exported="true"` receivers to be invocable.
- **Model storage**: Model files are stored in app-private storage with backup to `Downloads/local-llm/`. No credential or user data is stored alongside models.
- **Permissions**: `RECORD_AUDIO` for voice input, `QUERY_ALL_PACKAGES` for app discovery. No network permission is required for core functionality.
