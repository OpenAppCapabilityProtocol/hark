import 'package:flutter_test/flutter_test.dart';
import 'package:hark/services/cloud/cloud_provider_config.dart';

void main() {
  group('CloudProviderConfig round-trip', () {
    test('OpenAiConfig round-trips with defaults', () {
      const cfg = OpenAiConfig(apiKey: 'sk-test');
      expect(cfg.model, 'gpt-4o-mini');
      expect(cfg.baseUrl, 'https://api.openai.com/v1');

      final restored = CloudProviderConfig.fromJson(cfg.toJson());
      expect(restored, isA<OpenAiConfig>());
      expect(restored.apiKey, 'sk-test');
      expect(restored.model, 'gpt-4o-mini');
      expect(restored.kind, CloudProviderKind.openai);
    });

    test('OpenAiConfig round-trips with custom model', () {
      const cfg = OpenAiConfig(apiKey: 'sk-test', model: 'gpt-4o');
      final restored = CloudProviderConfig.fromJson(cfg.toJson());
      expect(restored.model, 'gpt-4o');
    });

    test('AzureConfig round-trips with all fields', () {
      const cfg = AzureConfig(
        apiKey: 'az-test',
        resourceName: 'my-resource',
        model: 'hark-extract-mini',
        apiVersion: '2024-12-01',
      );
      expect(
        cfg.baseUrl,
        'https://my-resource.openai.azure.com/openai/v1',
      );

      final json = cfg.toJson();
      expect(json['kind'], 'azure');
      expect(json['resource_name'], 'my-resource');
      expect(json['api_version'], '2024-12-01');

      final restored = CloudProviderConfig.fromJson(json) as AzureConfig;
      expect(restored.apiKey, 'az-test');
      expect(restored.resourceName, 'my-resource');
      expect(restored.model, 'hark-extract-mini');
      expect(restored.apiVersion, '2024-12-01');
    });

    test('AzureConfig.fromJson defaults missing api_version', () {
      final json = {
        'kind': 'azure',
        'api_key': 'az',
        'model': 'gpt-4o-mini',
        'resource_name': 'r',
      };
      final restored = CloudProviderConfig.fromJson(json) as AzureConfig;
      expect(restored.apiVersion, '2024-10-21');
    });

    test('GeminiConfig round-trips with defaults', () {
      const cfg = GeminiConfig(apiKey: 'gm-test');
      expect(cfg.model, 'gemini-2.5-flash-lite');
      expect(
        cfg.baseUrl,
        'https://generativelanguage.googleapis.com/v1beta/openai',
      );

      final restored = CloudProviderConfig.fromJson(cfg.toJson());
      expect(restored, isA<GeminiConfig>());
      expect(restored.model, 'gemini-2.5-flash-lite');
    });

    test('AnthropicConfig round-trips with defaults', () {
      const cfg = AnthropicConfig(apiKey: 'ant-test');
      expect(cfg.model, 'claude-haiku-4-5');
      expect(cfg.baseUrl, 'https://api.anthropic.com/v1');

      final restored = CloudProviderConfig.fromJson(cfg.toJson());
      expect(restored, isA<AnthropicConfig>());
    });

    test('CustomOpenAiConfig round-trips with user-supplied URL', () {
      const cfg = CustomOpenAiConfig(
        apiKey: 'or-test',
        model: 'mistral-7b',
        customBaseUrl: 'https://openrouter.ai/api/v1',
      );
      expect(cfg.baseUrl, 'https://openrouter.ai/api/v1');

      final restored =
          CloudProviderConfig.fromJson(cfg.toJson()) as CustomOpenAiConfig;
      expect(restored.customBaseUrl, 'https://openrouter.ai/api/v1');
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
      const raw = '{"kind": "nonexistent", "api_key": "x", "model": "y"}';
      expect(CloudProviderConfig.fromJsonString(raw), isNull);
    });

    test('missing required field returns null', () {
      // AzureConfig requires resource_name — missing field surfaces as
      // a TypeError during field extraction, caught by fromJsonString.
      const raw = '{"kind": "azure", "api_key": "x", "model": "y"}';
      expect(CloudProviderConfig.fromJsonString(raw), isNull);
    });

    test('valid round-trip via toJsonString / fromJsonString', () {
      const cfg = OpenAiConfig(apiKey: 'sk-test');
      final raw = cfg.toJsonString();
      final restored = CloudProviderConfig.fromJsonString(raw);
      expect(restored, isNotNull);
      expect(restored, isA<OpenAiConfig>());
      expect(restored!.apiKey, 'sk-test');
    });
  });

  group('CloudProviderKind / CloudRoutingMode wire names', () {
    test('CloudProviderKind.fromWireName round-trips all values', () {
      for (final kind in CloudProviderKind.values) {
        expect(
          CloudProviderKind.fromWireName(kind.wireName),
          kind,
        );
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
        expect(
          CloudRoutingMode.fromWireName(mode.wireName),
          mode,
        );
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
