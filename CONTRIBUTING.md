# Contributing to Hark

Hark is in active development and we welcome contributions.

## Ways to Contribute

### Improve Hark itself

- Fix bugs, improve NLU accuracy, add features
- See [ROADMAP.md](ROADMAP.md) for what's planned
- Check open issues for things to work on

### Test with OACP apps

Install Hark and any [OACP-enabled app](https://github.com/OpenAppCapabilityProtocol), then test voice commands. Report any bugs, accuracy issues, or UX problems as GitHub issues.

### Improve documentation

Found something confusing? Missing a guide? PRs welcome.

### Report bugs

Open an issue with:

- What you expected
- What happened
- Steps to reproduce
- Device model and Android version

## Development Setup

### Prerequisites

- Flutter SDK (stable channel, >= 3.11)
- Android device or emulator (physical device recommended for voice features)
- Android Studio or VS Code with Flutter extension

### Build and run

```bash
git clone https://github.com/OpenAppCapabilityProtocol/hark.git
cd hark
flutter pub get
flutter run
```

### Running checks

```bash
flutter analyze
flutter test
```

Both must pass before submitting a PR.

### On-device testing

Most of Hark's functionality requires a physical Android device:

- Voice input needs a microphone
- OACP app discovery needs real installed apps
- System assistant integration needs Android settings access
- GPU acceleration for on-device models needs real hardware

### PR guidelines

- Keep PRs focused on a single change
- Include a description of what changed and why
- Ensure `flutter analyze` passes with no issues
- Test on a physical device when touching voice, discovery, or dispatch code

## Architecture

See [docs/architecture.md](docs/architecture.md) for how Hark works internally.

## Code of Conduct

See [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
