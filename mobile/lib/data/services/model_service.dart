import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/chat_models.dart';
import '../models/provider.dart';

/// DeepSeek 对话能力（联网、阅读链接、文件、内容安全、会话标题）官方指定模型。
///
/// Business Rule: 这些扩展能力只在 `deepseek-flash` 下保证可用；`deepseek-v4-pro`
/// 不支持图像理解，文件/联网等能力也没有官方保证。选中其他 DeepSeek 模型时由
/// `ChatController` 在发送前自动切回本模型，避免静默降级。
const String deepSeekFlashModel = 'deepseek-flash';

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
    if (providerId == 'deepseek') {
      // 官方已于 2026-07-24 下线 deepseek-chat / deepseek-reasoner（见 V4 预览版公告），
      // 现行模型为 deepseek-flash 与 deepseek-v4-pro；对话扩展能力优先使用 flash。
      return _toModelInfos(<String>[deepSeekFlashModel, 'deepseek-v4-pro']);
    }
    return <ModelInfo>[];
  }

  static List<ModelInfo> _toModelInfos(List<String> ids) => ids
      .map((String id) => ModelInfo(id: id, name: id))
      .toList(growable: false);
}
