import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/chat_models.dart';
import '../models/provider.dart';

class ChatException implements Exception {
  const ChatException(this.message);
  final String message;

  @override
  String toString() => message;
}

class ChatStreamEvent {
  const ChatStreamEvent({
    this.content = '',
    this.reasoning = '',
    this.done = false,
    this.searchHint = '',
    this.sources = const <SearchSource>[],
    this.citations = const <CitationRange>[],
    this.title = '',
    this.refusal = '',
    this.serverToolCallsJson = '',
    this.toolCallIndex = -1,
    this.toolCallId = '',
    this.toolCallName = '',
    this.toolCallArgs = '',
  });

  final String content;
  final String reasoning;
  final bool done;
  /// 检索过程提示（server_tool_event）；空串表示本块没有搜索事件。
  final String searchHint;
  /// 本块新出现的来源（已按 url 去重由调用方合并）。
  final List<SearchSource> sources;
  /// 正文引用区间（delta.annotations）。
  final List<CitationRange> citations;
  /// 会话标题（仅首轮声明 title 时下发）。
  final String title;
  /// 内容安全拒答原因（finish_reason=content_filter / delta.refusal）。
  final String refusal;
  /// 末块 `delta.server_tool_calls` 的原文（含阅读链接的 signature，多轮必须原样回传）。
  final String serverToolCallsJson;
  /// 客户端工具调用分片：index 相同的分片需要累加。
  final int toolCallIndex;
  final String toolCallId;
  final String toolCallName;
  final String toolCallArgs;

  bool get hasPayload => content.isNotEmpty || reasoning.isNotEmpty;
}

class ChatRequestOptions {
  const ChatRequestOptions({
    required this.providerId,
    required this.apiKey,
    required this.model,
    required this.messages,
    this.temperature,
    this.systemPrompt,
    this.enableThinking = false,
    this.reasoningEffort = 'high',
    this.enableWebSearch = false,
    this.enableFiles = false,
    this.enableImageTool = false,
    this.enableSafety = false,
    this.enableTitle = false,
    this.enableReadUrl = false,
  });

  final String providerId;
  final String apiKey;
  final String model;
  final List<ChatMessage> messages;
  final double? temperature;
  final String? systemPrompt;
  final bool enableThinking;
  final String reasoningEffort;
  /// 联网搜索：仅 DeepSeek 声明服务端工具 deepseek_web_search。
  final bool enableWebSearch;
  /// 文件/图片附件：仅 DeepSeek 回放 file 块。
  final bool enableFiles;
  /// 生图工具：声明客户端函数 generate_image（百智云异步任务）。
  final bool enableImageTool;
  /// 内容安全：声明 safety_check.level=high（仅 DeepSeek）。
  final bool enableSafety;
  /// 会话标题：声明 title.enabled（仅 DeepSeek）；只在会话首次请求开启。
  final bool enableTitle;
  /// 阅读链接：声明 deepseek_read_url（仅 DeepSeek），模型自动读用户消息里的 URL。
  final bool enableReadUrl;
}

/// 联网能力的数据块 kind（其余 kind 是别的工具，解析时忽略）。
const Set<String> _webToolKinds = <String>{
  'search',
  'deep_search',
  'read_link',
  'image_search',
  'deep_image_search',
};

/// 一次服务端工具事件的解析结果。
class _ToolEvent {
  const _ToolEvent({this.hint = '', this.sources = const <SearchSource>[]});

  final String hint;
  final List<SearchSource> sources;
}

/// OpenAI-compatible streaming engine.
///
/// Protocol contract (ported from the HarmonyOS client):
/// 1. `[DONE]` is the only completion signal; `finish_reason` is ignored.
/// 2. `delta.content` and `delta.reasoning_content` are append-only.
/// 3. The terminal usage chunk has an empty `choices` array and is skipped.
/// 4. History is stateless per request and truncated by count + chars.
class ChatService {
  const ChatService._();

  static const int _maxHistoryMessages = 20;
  static const int _maxHistoryChars = 12000;

  static const Duration _connectTimeout = Duration(seconds: 15);
  static const Duration _readTimeout = Duration(seconds: 90);

  static Stream<ChatStreamEvent> streamChat(ChatRequestOptions options) async* {
    final ProviderDefinition? def = findProvider(options.providerId);
    if (def == null) {
      throw ChatException('未知的服务商: ${options.providerId}');
    }
    if (options.apiKey.trim().isEmpty) {
      throw const ChatException('未配置 API Key，请先配置');
    }
    if (options.model.trim().isEmpty) {
      throw const ChatException('未选择模型');
    }

    final Uri uri = Uri.parse('${def.baseUrl}${def.chatEndpoint}');
    final http.Client client = http.Client();
    try {
      final http.Request request = http.Request('POST', uri)
        ..headers.addAll(<String, String>{
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${options.apiKey.trim()}',
          'api-key': options.apiKey.trim(),
          'Accept': 'text/event-stream',
        })
        ..body = jsonEncode(_buildPayload(options, def, true));

      final http.StreamedResponse response =
          await client.send(request).timeout(_connectTimeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final String body = await response.stream.bytesToString();
        throw ChatException(
          '服务商返回状态码 ${response.statusCode}: ${_truncate(body)}',
        );
      }

      bool sawDone = false;
      final Stream<String> lines = response.stream
          .timeout(_readTimeout)
          .transform(utf8.decoder)
          .transform(const LineSplitter());
      await for (final String rawLine in lines) {
        final String line = rawLine.trim();
        if (!line.startsWith('data:')) {
          continue;
        }
        final String data = line.substring(5).trim();
        if (data == '[DONE]') {
          sawDone = true;
          break;
        }
        final ChatStreamEvent? event = _parseChunk(data);
        if (event != null && event.hasPayload) {
          yield event;
        }
      }
      if (!sawDone) {
        // Stream closed without [DONE]: keep the partial content, but let the
        // caller know the reply ended abnormally.
        yield const ChatStreamEvent(done: true);
      } else {
        yield const ChatStreamEvent(done: true);
      }
    } on TimeoutException {
      throw const ChatException('网络请求超时，请重试');
    } on http.ClientException catch (error) {
      throw ChatException('网络请求失败: ${error.message}');
    } finally {
      client.close();
    }
  }

  static ChatStreamEvent? _parseChunk(String data) {
    try {
      final Object? parsed = jsonDecode(data);
      if (parsed is! Map) {
        return null;
      }
      final Object? choices = parsed['choices'];
      if (choices is! List || choices.isEmpty) {
        return null;
      }
      final Object? choice = choices.first;
      if (choice is! Map) {
        return null;
      }
      final Object? delta = choice['delta'];
      if (delta is! Map) {
        return null;
      }
      final Object? content = delta['content'];
      final Object? reasoning = delta['reasoning_content'];
      final _ToolEvent toolEvent = _parseToolEvent(choice['server_tool_event']);
      final List<CitationRange> citations = _parseAnnotations(delta['annotations']);
      // 完整的 server_tool_calls 只在带 finish_reason 的最后一个 chunk 下发一次。
      final Object? toolCallsRaw = delta['server_tool_calls'];
      String toolCallsJson = '';
      if (toolCallsRaw is List && toolCallsRaw.isNotEmpty) {
        final String encoded = jsonEncode(toolCallsRaw);
        if (encoded.length <= maxServerToolCallsChars) {
          toolCallsJson = encoded;
        }
      }
      final List<SearchSource> sources = <SearchSource>[
        ...toolEvent.sources,
      ];
      for (final CitationRange cite in citations) {
        if (!sources.any((SearchSource s) => s.url == cite.url)) {
          sources.add(SearchSource(url: cite.url, title: cite.title));
        }
      }
      final Object? titleRaw = delta['title'];
      final String title = titleRaw is String ? titleRaw.trim() : '';
      String refusal = '';
      if (choice['finish_reason'] == 'content_filter') {
        refusal = '内容未通过安全审核';
      }
      final Object? deltaRefusal = delta['refusal'];
      if (deltaRefusal is String && deltaRefusal.isNotEmpty) {
        refusal = deltaRefusal;
      }
      int callIndex = -1;
      String callId = '';
      String callName = '';
      String callArgs = '';
      final Object? toolCalls = delta['tool_calls'];
      if (toolCalls is List && toolCalls.isNotEmpty) {
        final Object? first = toolCalls.first;
        if (first is Map) {
          final Object? indexRaw = first['index'];
          if (indexRaw is num) {
            callIndex = indexRaw.toInt();
          }
          final Object? idRaw = first['id'];
          if (idRaw is String) {
            callId = idRaw;
          }
          final Object? fn = first['function'];
          if (fn is Map) {
            final Object? nameRaw = fn['name'];
            if (nameRaw is String) {
              callName = nameRaw;
            }
            final Object? argsRaw = fn['arguments'];
            if (argsRaw is String) {
              callArgs = argsRaw;
            }
          }
        }
      }      return ChatStreamEvent(
        content: content is String ? content : '',
        reasoning: reasoning is String ? reasoning : '',
        searchHint: toolEvent.hint,
        sources: sources,
        citations: citations,
        title: title,
        refusal: refusal,
        serverToolCallsJson: toolCallsJson,
        toolCallIndex: callIndex,
        toolCallId: callId,
        toolCallName: callName,
        toolCallArgs: callArgs,
      );
    } catch (_) {
      // Ignore keep-alive or malformed single lines.
      return null;
    }
  }

  /// System prompt first, then history newest-first truncation.
  ///
  /// Business Rule: assistant history is projected through its stored topic
  /// mask; mismatched masks fail open. `reasoning_content` is replayed for
  /// preserved-thinking providers.
  static List<Map<String, dynamic>> buildApiMessages(
    List<ChatMessage> messages,
    String? systemPrompt,
    bool enableFiles,
  ) {
    final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
    if (systemPrompt != null && systemPrompt.trim().isNotEmpty) {
      out.add(<String, dynamic>{
        'role': 'system',
        'content': systemPrompt.trim(),
      });
    }
    final List<Map<String, dynamic>> candidates = <Map<String, dynamic>>[];
    for (final ChatMessage message in messages) {
      if (!message.isUser && !message.isAssistant) {
        continue;
      }
      final String replay = message.content;
      final String reasoning = message.reasoningContent ?? '';
      final bool hasAtts =
          message.isUser && enableFiles && message.attachments.isNotEmpty;
      // 服务端工具调用（阅读链接的 signature）必须随历史原样回传，否则模型读不到旧网页。
      final List<Map<String, dynamic>>? serverToolCalls = message.isAssistant
          ? parseServerToolCalls(message.serverToolCallsJson)
          : null;
      final bool hasToolCalls = serverToolCalls != null;
      // 纯附件消息（只发文件不打字）也要保留，否则追问会丢文档。
      if (replay.isEmpty && reasoning.isEmpty && !hasAtts && !hasToolCalls) {
        continue;
      }
      final Map<String, dynamic> item = <String, dynamic>{
        'role': ChatMessage.roleToWire(message.role),
      };
      int chars = replay.length;
      if (hasAtts) {
        // Business Rule: 文档块在前、用户文字在后（官方示例顺序）。
        final List<Map<String, String>> parts = <Map<String, String>>[];
        for (final MessageAttachment att in message.attachments) {
          parts.add(<String, String>{'type': 'file', 'file_id': att.fileId});
          chars += att.fileName.length;
        }
        if (replay.isNotEmpty) {
          parts.add(<String, String>{'type': 'text', 'text': replay});
        }
        item['content'] = parts;
      } else {
        item['content'] = replay;
      }
      if (message.isAssistant && reasoning.isNotEmpty) {
        item['reasoning_content'] = reasoning;
        chars += reasoning.length;
      }
      if (serverToolCalls != null) {
        item['server_tool_calls'] = serverToolCalls;
      }
      item['_chars'] = chars;
      candidates.add(item);
    }

    final int start = candidates.length > _maxHistoryMessages
        ? candidates.length - _maxHistoryMessages
        : 0;
    final List<Map<String, dynamic>> kept = <Map<String, dynamic>>[];
    int used = 0;
    for (int i = candidates.length - 1; i >= start; i--) {
      final Map<String, dynamic> c = candidates[i];
      final int total = (c['_chars'] as int?) ?? 0;
      if (kept.isNotEmpty && used + total > _maxHistoryChars) {
        break;
      }
      kept.insert(0, c);
      used += total;
    }
    for (final Map<String, dynamic> c in kept) {
      c.remove('_chars');
    }
    out.addAll(kept);
    return out;
  }
  static Map<String, dynamic> _buildPayload(
    ChatRequestOptions options,
    ProviderDefinition def,
    bool isStream,
  ) {
    final Map<String, dynamic> payload = <String, dynamic>{
      'model': options.model,
      'messages': buildApiMessages(
        options.messages,
        options.systemPrompt,
        options.enableFiles && options.providerId == 'deepseek',
      ),
      'stream': isStream,
    };
    // 联网搜索：仅 DeepSeek 声明服务端工具（搜索/抓取由服务端完成）；
    // 生图工具与它能同时声明，二者互不影响。
    final List<Map<String, dynamic>> tools = <Map<String, dynamic>>[];
    if (options.enableWebSearch && options.providerId == 'deepseek') {
      tools.add(<String, dynamic>{'type': 'deepseek_web_search'});
    }
    // 阅读链接：与联网搜索可同时声明，但服务端规则是「开思考 + 声明搜索」走深度思考搜索、
    // 不单独读链接；只有关思考或未声明搜索时才会读用户消息里的 URL。
    if (options.enableReadUrl && options.providerId == 'deepseek') {
      tools.add(<String, dynamic>{'type': 'deepseek_read_url'});
    }
    if (options.enableImageTool && options.providerId == 'deepseek') {
      tools.add(_imageToolDeclaration());
    }
    if (tools.isNotEmpty) {
      payload['tools'] = tools;
    }
    // 内容安全：官方基础风控，输入输出都审核；拒答走 finish_reason/refusal。
    if (options.enableSafety && options.providerId == 'deepseek') {
      payload['safety_check'] = <String, String>{'level': 'high'};
    }
    // 会话标题：DeepSeek 扩展字段，与 tools 并列；服务端在最后一个 chunk 的
    // delta.title 下发，回答结束后最多多等 5 秒，标题不计费。
    if (options.enableTitle && options.providerId == 'deepseek') {
      payload['title'] = <String, bool>{'enabled': true};
    }

    final bool thinkingOn =
        options.enableThinking && def.supportsThinking;
    final String model = options.model.toLowerCase();

    if (options.providerId == 'kimi') {
      if (model.startsWith('kimi-k3')) {
        payload['reasoning_effort'] = options.reasoningEffort;
      } else if (model.contains('kimi-k2.7')) {
        // Always-thinking model: no thinking flag and no temperature.
      } else if (model.startsWith('kimi-k2.6')) {
        payload['thinking'] = <String, String>{
          'type': thinkingOn ? 'enabled' : 'disabled',
        };
      } else {
        payload['temperature'] = options.temperature ?? 0.7;
      }
      return payload;
    }

    if (options.providerId == 'mimo') {
      payload['thinking'] = <String, String>{
        'type': thinkingOn ? 'enabled' : 'disabled',
      };
      if (!thinkingOn) {
        payload['temperature'] = options.temperature ?? 0.7;
      }
      return payload;
    }

    if (thinkingOn) {
      payload['thinking'] = <String, String>{'type': 'enabled'};
      payload['reasoning_effort'] = options.reasoningEffort;
    } else {
      if (def.supportsThinking) {
        payload['thinking'] = <String, String>{'type': 'disabled'};
      }
      payload['temperature'] = options.temperature ?? 0.7;
    }
    return payload;
  }

  static String _truncate(String text) =>
      text.length <= 500 ? text : '${text.substring(0, 500)}…';

  /// server_tool_event → 进度提示 + 本步产出的来源。
  ///
  /// 协议（Chat Completions）：`{type: "call_started"|"call_completed", step, call}`；
  /// `call` 带 `kind`、`action`（search/open_page/find_in_page/read_link），
  /// 结束时带 `sources`（搜索）或 `page`（打开网页/阅读链接）；`call_completed` 不带 `kind`。
  static _ToolEvent _parseToolEvent(Object? raw) {
    if (raw is! Map) {
      return const _ToolEvent();
    }
    final Object? type = raw['type'];
    if (type != 'call_started' && type != 'call_completed') {
      return const _ToolEvent();
    }
    final Object? call = raw['call'];
    if (call is! Map) {
      return const _ToolEvent();
    }
    final String kind = call['kind'] is String ? call['kind'] as String : '';
    // 只关心联网能力；明确是别的工具（如生图）才丢弃，kind 缺失一律放行。
    if (kind.isNotEmpty && !_webToolKinds.contains(kind)) {
      return const _ToolEvent();
    }

    String actionType = '';
    final List<String> queries = <String>[];
    final Object? action = call['action'];
    if (action is Map) {
      if (action['type'] is String) {
        actionType = action['type'] as String;
      }
      final Object? rawQueries = action['queries'];
      if (rawQueries is List) {
        for (final Object? q in rawQueries) {
          if (q is String && q.trim().isNotEmpty) {
            queries.add(q.trim());
          }
        }
      }
    }

    if (type == 'call_started') {
      return _ToolEvent(hint: _startedHint(actionType, kind, queries));
    }

    // 调用结束：把搜索结果或打开的网页转成来源卡片；失败时给一行提示。
    final List<SearchSource> sources = <SearchSource>[];
    final Object? rawSources = call['sources'];
    if (rawSources is List) {
      for (final Object? item in rawSources) {
        if (item is! Map) {
          continue;
        }
        final SearchSource? source = _sourceFromApi(item);
        if (source != null) {
          sources.add(source);
        }
      }
    }
    final Object? page = call['page'];
    if (page is Map) {
      final SearchSource? source = _sourceFromApi(page);
      if (source != null) {
        sources.add(source);
      }
    }
    if (call['status'] == 'failed') {
      return _ToolEvent(
        hint: actionType == 'read_link' ? '链接读取失败，继续整理答案…' : '',
        sources: sources,
      );
    }
    return _ToolEvent(sources: sources);
  }

  /// API 的 snake_case 来源对象 → SearchSource（http/https 之外的直接丢弃）。
  static SearchSource? _sourceFromApi(Map<Object?, Object?> raw) {
    final Object? url = raw['url'];
    if (url is! String ||
        !(url.startsWith('http://') || url.startsWith('https://'))) {
      return null;
    }
    final Object? title = raw['title'];
    final Object? publishedAt = raw['published_at'];
    return SearchSource(
      url: url,
      title: title is String && title.trim().isNotEmpty ? title.trim() : url,
      snippet: raw['snippet'] is String ? raw['snippet'] as String : null,
      siteName: raw['site_name'] is String ? raw['site_name'] as String : null,
      publishedAt: publishedAt is String ? publishedAt : null,
    );
  }

  static String _startedHint(String action, String kind, List<String> queries) {
    if (action == 'read_link') {
      return '正在阅读链接…';
    }
    if (action == 'open_page') {
      return '正在阅读网页…';
    }
    if (action == 'find_in_page') {
      return '正在网页内查找…';
    }
    if (kind == 'image_search' || kind == 'deep_image_search') {
      return '正在按图片搜索…';
    }
    if (queries.isEmpty) {
      return '正在联网搜索…';
    }
    if (queries.length == 1) {
      return '正在联网搜索「${queries.first}」…';
    }
    return '正在联网搜索「${queries.first}」等 ${queries.length} 个关键词…';
  }

  /// 解析 delta.annotations 中的 url_citation；偏移是 Unicode 码点。
  static List<CitationRange> _parseAnnotations(Object? raw) {
    if (raw is! List) {
      return const <CitationRange>[];
    }
    final List<CitationRange> out = <CitationRange>[];
    for (final Object? item in raw) {
      if (item is! Map || item['type'] != 'url_citation') {
        continue;
      }
      final Object? payload = item['url_citation'];
      if (payload is! Map) {
        continue;
      }
      final Object? url = payload['url'];
      if (url is! String || !(url.startsWith('http://') || url.startsWith('https://'))) {
        continue;
      }
      final Object? start = payload['start_index'];
      final Object? end = payload['end_index'];
      if (start is! num || end is! num) {
        continue;
      }
      final Object? title = payload['title'];
      out.add(
        CitationRange(
          url: url,
          title: title is String && title.isNotEmpty ? title : url,
          start: start.toInt(),
          end: end.toInt(),
        ),
      );
    }
    return out;
  }

  /// 生图函数工具声明：模型自行判断何时画图，参数只暴露 prompt/ratio/count。
  static Map<String, dynamic> _imageToolDeclaration() {
    return <String, dynamic>{
      'type': 'function',
      'function': <String, dynamic>{
        'name': 'generate_image',
        'description': '根据用户的描述生成图片。当用户明确要求画图、生成图片、插画、海报时调用。',
        'parameters': <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'prompt': <String, dynamic>{
              'type': 'string',
              'description': '用于生图的详细中文提示词，包含主体、风格、构图与光线。',
            },
            'ratio': <String, dynamic>{
              'type': 'string',
              'enum': <String>['1:1', '4:3', '3:4', '16:9', '9:16', 'auto'],
              'description': '图片比例，不确定时用 auto。',
            },
            'count': <String, dynamic>{
              'type': 'integer',
              'minimum': 1,
              'maximum': 4,
              'description': '生成张数，默认 1。',
            },
          },
          'required': <String>['prompt'],
        },
      },
    };
  }
}
