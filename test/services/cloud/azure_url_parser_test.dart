import 'package:flutter_test/flutter_test.dart';
import 'package:hark/services/cloud/azure_url_parser.dart';

void main() {
  const parser = AzureUrlParser();

  group('AzureUrlParser — happy paths', () {
    test('parses full classic cognitiveservices URL', () {
      final cfg = parser.parse(
        rawUrl:
            'https://hark-ai-resource.cognitiveservices.azure.com/openai/deployments/hark-cloud-gpt-4-mini/chat/completions?api-version=2025-01-01-preview',
        apiKey: 'sk-test',
      );
      expect(
        cfg.baseUrl,
        'https://hark-ai-resource.cognitiveservices.azure.com/openai/deployments/hark-cloud-gpt-4-mini',
      );
      expect(cfg.model, 'hark-cloud-gpt-4-mini');
      expect(cfg.apiVersion, '2025-01-01-preview');
      expect(cfg.apiKey, 'sk-test');
    });

    test('parses classic openai.azure.com URL', () {
      final cfg = parser.parse(
        rawUrl:
            'https://my-resource.openai.azure.com/openai/deployments/gpt4mini/chat/completions?api-version=2024-10-21',
        apiKey: 'k',
      );
      expect(
        cfg.baseUrl,
        'https://my-resource.openai.azure.com/openai/deployments/gpt4mini',
      );
      expect(cfg.model, 'gpt4mini');
      expect(cfg.apiVersion, '2024-10-21');
    });

    test('parses Foundry services.ai.azure.com URL', () {
      final cfg = parser.parse(
        rawUrl:
            'https://hark-ai-resource.services.ai.azure.com/openai/deployments/hark-mini/chat/completions?api-version=2025-01-01-preview',
        apiKey: 'k',
      );
      expect(
        cfg.baseUrl,
        'https://hark-ai-resource.services.ai.azure.com/openai/deployments/hark-mini',
      );
      expect(cfg.model, 'hark-mini');
    });

    test('accepts URL without trailing /chat/completions', () {
      final cfg = parser.parse(
        rawUrl:
            'https://r.cognitiveservices.azure.com/openai/deployments/d?api-version=2024-10-21',
        apiKey: 'k',
      );
      expect(
        cfg.baseUrl,
        'https://r.cognitiveservices.azure.com/openai/deployments/d',
      );
      expect(cfg.model, 'd');
      expect(cfg.apiVersion, '2024-10-21');
    });

    test('strips extra query parameters but keeps api-version', () {
      final cfg = parser.parse(
        rawUrl:
            'https://r.openai.azure.com/openai/deployments/d/chat/completions?api-version=2024-10-21&other=x',
        apiKey: 'k',
      );
      expect(cfg.apiVersion, '2024-10-21');
      expect(cfg.baseUrl, 'https://r.openai.azure.com/openai/deployments/d');
    });

    test('whitespace is trimmed', () {
      final cfg = parser.parse(
        rawUrl:
            '   https://r.openai.azure.com/openai/deployments/d/chat/completions?api-version=2024-10-21  \n',
        apiKey: 'k',
      );
      expect(cfg.model, 'd');
    });
  });

  group('AzureUrlParser — error paths', () {
    test('empty URL', () {
      expect(
        () => parser.parse(rawUrl: '', apiKey: 'k'),
        throwsA(
          isA<FormatException>().having((e) => e.message, 'message', 'URL is empty.'),
        ),
      );
    });

    test('malformed URI', () {
      expect(
        () => parser.parse(rawUrl: 'http://[bad', apiKey: 'k'),
        throwsFormatException,
      );
    });

    test('missing https scheme', () {
      expect(
        () => parser.parse(rawUrl: 'ftp://x.com/openai/deployments/d?api-version=v', apiKey: 'k'),
        throwsFormatException,
      );
    });

    test('plain resource URL without /openai path', () {
      expect(
        () => parser.parse(rawUrl: 'https://r.cognitiveservices.azure.com/', apiKey: 'k'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('does not look like'),
          ),
        ),
      );
    });

    test('missing /deployments segment after /openai', () {
      expect(
        () => parser.parse(
          rawUrl: 'https://r.openai.azure.com/openai/something/d?api-version=v',
          apiKey: 'k',
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('missing /deployments'),
          ),
        ),
      );
    });

    test('missing deployment name', () {
      // /openai/deployments with no name — the path would just end there
      // and the parser should reject it.
      expect(
        () => parser.parse(
          rawUrl: 'https://r.openai.azure.com/openai/deployments?api-version=v',
          apiKey: 'k',
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('missing api-version query param', () {
      expect(
        () => parser.parse(
          rawUrl:
              'https://r.openai.azure.com/openai/deployments/d/chat/completions',
          apiKey: 'k',
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('api-version'),
          ),
        ),
      );
    });
  });
}
