import 'package:flutter_test/flutter_test.dart';
import 'package:hark/services/cloud/cloud_provider_config.dart';

void main() {
  group('CloudProviderConfig round-trip', () {
    test('OpenAiConfig round-trips', () {
      const cfg = OpenAiConfig(
        baseUrl: 'https://api.openai.com/v1',
        apiKey: 'sk-test',
        model: 'gpt-4o-mini',
      );
      final restored = CloudProviderConfig.fromJson(cfg.toJson());
      expect(restored, isA<OpenAiConfig>());
      expect(restored.baseUrl, 'https://api.openai.com/v1');
      expect(restored.apiKey, 'sk-test');
      expect(restored.model, 'gpt-4o-mini');
      expect(restored.kind, CloudProviderKind.openai);
    });

    test('AzureConfig round-trips with all fields', () {
      const cfg = AzureConfig(
        baseUrl: 'https://my-resource.openai.azure.com/openai/v1',
        apiKey: 'az-test',
        model: 'hark-extract-mini',
        apiVersion: '2024-12-01',
      );

      final json = cfg.toJson();
      expect(json['kind'], 'azure');
      expect(
        json['base_url'],
        'https://my-resource.openai.azure.com/openai/v1',
      );
      expect(json['api_version'], '2024-12-01');

      final restored = CloudProviderConfig.fromJson(json) as AzureConfig;
      expect(
        restored.baseUrl,
        'https://my-resource.openai.azure.com/openai/v1',
      );
      expect(restored.apiKey, 'az-test');
      expect(restored.model, 'hark-extract-mini');
      expect(restored.apiVersion, '2024-12-01');
    });

    test('GeminiConfig round-trips', () {
      const cfg = GeminiConfig(
        baseUrl: 'https://generativelanguage.googleapis.com/v1beta/openai',
        apiKey: 'gm-test',
        model: 'gemini-2.5-flash-lite',
      );
      final restored = CloudProviderConfig.fromJson(cfg.toJson());
      expect(restored, isA<GeminiConfig>());
      expect(
        restored.baseUrl,
        'https://generativelanguage.googleapis.com/v1beta/openai',
      );
      expect(restored.model, 'gemini-2.5-flash-lite');
    });

    test('AnthropicConfig round-trips', () {
      const cfg = AnthropicConfig(
        baseUrl: 'https://api.anthropic.com/v1',
        apiKey: 'ant-test',
        model: 'claude-haiku-4-5',
      );
      final restored = CloudProviderConfig.fromJson(cfg.toJson());
      expect(restored, isA<AnthropicConfig>());
      expect(restored.baseUrl, 'https://api.anthropic.com/v1');
      expect(restored.model, 'claude-haiku-4-5');
    });

    test('CustomOpenAiConfig round-trips', () {
      const cfg = CustomOpenAiConfig(
        baseUrl: 'https://openrouter.ai/api/v1',
        apiKey: 'or-test',
        model: 'mistral-7b',
      );
      final restored =
          CloudProviderConfig.fromJson(cfg.toJson()) as CustomOpenAiConfig;
      expect(restored.baseUrl, 'https://openrouter.ai/api/v1');
      expect(restored.model, 'mistral-7b');
    });
  });

  group('CloudProviderConfig.fromJsonString defensive parsing', () {
    test('null input returns null', () {
      expect(CloudProviderConfig.fromJsonString(null), isNull);
    });

    test('empty string returns null', () {
      expect(CloudProviderConfig.fromJsonString(''), isNull);
    });

    test('malformed JSON returns null (does not throw)', () {
      expect(CloudProviderConfig.fromJsonString('not json'), isNull);
      expect(CloudProviderConfig.fromJsonString('{incomplete'), isNull);
    });

    test('unknown kind returns null', () {
      const raw =
          '{"kind": "nonexistent", "base_url": "x", "api_key": "y", "model": "z"}';
      expect(CloudProviderConfig.fromJsonString(raw), isNull);
    });

    test('missing required field returns null', () {
      // AzureConfig requires api_version — missing field surfaces as
      // a TypeError during field extraction, caught by fromJsonString.
      const raw =
          '{"kind": "azure", "base_url": "x", "api_key": "y", "model": "z"}';
      expect(CloudProviderConfig.fromJsonString(raw), isNull);
    });

    test('missing base_url returns null', () {
      const raw =
          '{"kind": "openai", "api_key": "sk-test", "model": "gpt-4o-mini"}';
      expect(CloudProviderConfig.fromJsonString(raw), isNull);
    });

    test('valid round-trip via toJsonString / fromJsonString', () {
      const cfg = OpenAiConfig(
        baseUrl: 'https://api.openai.com/v1',
        apiKey: 'sk-test',
        model: 'gpt-4o-mini',
      );
      final raw = cfg.toJsonString();
      final restored = CloudProviderConfig.fromJsonString(raw);
      expect(restored, isNotNull);
      expect(restored, isA<OpenAiConfig>());
      expect(restored!.apiKey, 'sk-test');
    });
  });

  group('CloudProviderConfig.toString redacts apiKey', () {
    test('does not include apiKey', () {
      const cfg = OpenAiConfig(
        baseUrl: 'https://api.openai.com/v1',
        apiKey: 'sk-very-secret-key',
        model: 'gpt-4o-mini',
      );
      expect(cfg.toString(), isNot(contains('sk-very-secret-key')));
      expect(cfg.toString(), contains('<redacted>'));
      expect(cfg.toString(), contains('gpt-4o-mini'));
    });
  });

  group('CloudProviderKind / CloudRoutingMode wire names', () {
    test('CloudProviderKind.fromWireName round-trips all values', () {
      for (final kind in CloudProviderKind.values) {
        expect(CloudProviderKind.fromWireName(kind.wireName), kind);
      }
    });

    test('CloudProviderKind.fromWireName throws on unknown', () {
      expect(
        () => CloudProviderKind.fromWireName('bogus'),
        throwsArgumentError,
      );
    });

    test('CloudRoutingMode.fromWireName round-trips all values', () {
      for (final mode in CloudRoutingMode.values) {
        expect(CloudRoutingMode.fromWireName(mode.wireName), mode);
      }
    });

    test('wire names are stable (regression guard for persistence)', () {
      // These strings are burnt into secure storage blobs. Changing them
      // without a migration breaks every existing install.
      expect(CloudProviderKind.openai.wireName, 'openai');
      expect(CloudProviderKind.azureOpenAi.wireName, 'azure');
      expect(CloudProviderKind.gemini.wireName, 'gemini');
      expect(CloudProviderKind.anthropic.wireName, 'anthropic');
      expect(CloudProviderKind.customOpenAi.wireName, 'custom_openai');

      expect(CloudRoutingMode.localOnly.wireName, 'local_only');
      expect(CloudRoutingMode.cloudPreferred.wireName, 'cloud_preferred');
      expect(CloudRoutingMode.cloudOnly.wireName, 'cloud_only');
    });
  });
}
