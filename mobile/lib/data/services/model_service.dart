import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/chat_models.dart';
import '../models/provider.dart';

/// Fetches the live model list from an OpenAI-compatible `/models` endpoint.
class ModelService {
  const ModelService._();

  static const Duration _timeout = Duration(seconds: 10);

  static Future<List<ModelInfo>> fetchModels(
    String providerId,
    String apiKey,
  ) async {
    final ProviderDefinition? def = findProvider(providerId);
    if (def == null || apiKey.trim().isEmpty) {
      return <ModelInfo>[];
    }
    for (final String url in _buildCandidates(def)) {
      try {
        final List<String> ids = await _requestModels(url, apiKey);
        if (ids.isNotEmpty) {
          debugPrint('ModelService: fetched ${ids.length} models from $url');
          return _toModelInfos(ids);
        }
      } catch (error) {
        debugPrint('ModelService: fetch failed from $url: $error');
      }
    }
    return _fallbackModels(providerId);
  }

  static List<String> _buildCandidates(ProviderDefinition def) {
    String trimmed = def.baseUrl.trim();
    while (trimmed.endsWith('/')) {
      trimmed = trimmed.substring(0, trimmed.length - 1);
    }
    if (trimmed.isEmpty) {
      return <String>[];
    }
    final String primary = '$trimmed${def.modelsEndpoint}';
    final List<String> list = <String>[primary];
    for (final String fallback in <String>['/models', '/v1/models']) {
      final String candidate = '$trimmed$fallback';
      if (!list.contains(candidate)) {
        list.add(candidate);
      }
    }
    return list;
  }

  static Future<List<String>> _requestModels(String url, String apiKey) async {
    final http.Client client = http.Client();
    try {
      final http.Response response = await client.get(
        Uri.parse(url),
        headers: <String, String>{
          'Authorization': 'Bearer ${apiKey.trim()}',
          'api-key': apiKey.trim(),
          'Accept': 'application/json',
        },
      ).timeout(_timeout);
      if (response.statusCode != 200) {
        return <String>[];
      }
      final Object? parsed = jsonDecode(response.body);
      if (parsed is! Map) {
        return <String>[];
      }
      final Object? data = parsed['data'];
      if (data is! List) {
        return <String>[];
      }
      final List<String> ids = <String>[];
      for (final Object? item in data) {
        if (item is Map) {
          final Object? id = item['id'];
          if (id is String && id.trim().isNotEmpty) {
            ids.add(id.trim());
          }
        }
      }
      return ids;
    } finally {
      client.close();
    }
  }

  static List<ModelInfo> _fallbackModels(String providerId) {
    if (providerId == 'mimo') {
      return _toModelInfos(mimoThinkingModels);
    }
    if (providerId == 'deepseek') {
      // 官方已于 2026-07-24 下线 deepseek-chat / deepseek-reasoner（见 V4 预览版公告），
      // 现行模型为 deepseek-flash 与 deepseek-v4-pro；联网服务端工具也只在这两个模型下可用。
      return _toModelInfos(<String>['deepseek-flash', 'deepseek-v4-pro']);
    }
    if (providerId == 'kimi') {
      return _toModelInfos(<String>[
        'kimi-k3',
        'kimi-k2.7-code',
        'kimi-k2.7-code-highspeed',
        'kimi-k2.6',
        'moonshot-v1-8k',
        'moonshot-v1-32k',
        'moonshot-v1-128k',
      ]);
    }
    return <ModelInfo>[];
  }

  static List<ModelInfo> _toModelInfos(List<String> ids) => ids
      .map((String id) => ModelInfo(id: id, name: id))
      .toList(growable: false);
}
