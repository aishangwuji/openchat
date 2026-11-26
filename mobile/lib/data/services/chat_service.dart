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

/// 内容安全拒答 / 输入拦截的统一文案。
///
/// Business Rule: 官方不说明拒答的具体原因（Chat Completions 的
/// `finish_reason=content_filter`，流式为末块 `delta.refusal`）；图片被拦时
/// `refusal` 会带 `The following images were blocked by content moderation: ...`，
/// 原样附在括号里帮助用户定位，其余情况只给通用提示。
String safetyNotice(String detail) {
  const String base = '本次对话未通过内容安全审核，回答已拦截。请调整内容后重试';
  final String trimmed = detail.trim();
  if (trimmed.isEmpty || trimmed == '内容未通过安全审核') {
    return base;
  }
  return '$base（$trimmed）';
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
    this.truncated = false,
    this.error = '',
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
  /// 输出是否被长度上限截断（finish_reason=length）。
  final bool truncated;
  /// 生成中失败（末块 error / 流意外中断 / 资源不足）。
  final String error;
  /// 末块 `delta.server_tool_calls` 的原文（含阅读链接的 signature，多轮必须原样回传）。
  final String serverToolCallsJson;
  /// 客户端工具调用分片：index 相同的分片需要累加。
  final int toolCallIndex;
  final String toolCallId;
  final String toolCallName;
  final String toolCallArgs;

  /// 本块是否有需要交给上层的载荷。
  ///
  /// Business Rule: `server_tool_event`、`annotations`、`server_tool_calls`、`title`
  /// 都独立于正文增量下发，末块甚至可能没有 `delta`。只按正文/思考判断会把
  /// 检索进度、来源、引用、服务端标题与阅读链接的 signature 整体丢掉。
  bool get hasPayload =>
      content.isNotEmpty ||
      reasoning.isNotEmpty ||
      searchHint.isNotEmpty ||
      sources.isNotEmpty ||
      citations.isNotEmpty ||
      title.isNotEmpty ||
      refusal.isNotEmpty ||
      truncated ||
      error.isNotEmpty ||
      serverToolCallsJson.isNotEmpty ||
      toolCallIndex >= 0;
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
    this.reminder,
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
  /// 用户元信息（仅 DeepSeek）：每条 user 消息前插 latest_reminder。
  final ChatReminder? reminder;
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

/// 用户元信息标记（`latest_reminder`）的取值来源。
class ChatReminder {
  const ChatReminder({required this.location, required this.language});

  /// 所在地，可留空（官方允许空字段）。
  final String location;

  /// 'zh-CN' | 'en-US'。
  final String language;
}

/// 一天的历史单位：1~2 条线上消息（user 消息可能紧跟一条 latest_reminder）。
class _WireUnit {
  const _WireUnit({required this.items, required this.chars});

  final List<Map<String, dynamic>> items;
  final int chars;
}

/// DateTime.weekday 是 1(周一)~7(周日)。
const List<String> _zhWeekdays = <String>[
  '星期一',
  '星期二',
  '星期三',
  '星期四',
  '星期五',
  '星期六',
  '星期日',
];
const List<String> _enWeekdays = <String>[
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];

/// OpenAI-compatible streaming engine.
///
/// Protocol contract (ported from the HarmonyOS client):
/// 1. `[DONE]` is the only completion signal; `finish_reason` is ignored.
/// 2. `delta.content` and `delta.reasoning_content` are append-only.
/// 3. The terminal usage chunk has an empty `choices` array and is skipped.
/// 4. History is stateless per request and truncated by count + chars.
class ChatService {
  const ChatService._();

  // 历史预算：DeepSeek 模型有 1M 上下文，旧的 20 条/12000 字会把带 file_id 的
  // 附件轮次和带 signature 的阅读链接轮次在十几轮后截掉，造成「突然失忆」。
  static const int _maxHistoryMessages = 60;
  static const int _maxHistoryChars = 100000;

  static const Duration _connectTimeout = Duration(seconds: 15);
  static const Duration _readTimeout = Duration(seconds: 90);

  /// [clientFactory] 仅测试用：注入 mock client 验证流式解码，生产传 null。
  static Stream<ChatStreamEvent> streamChat(
    ChatRequestOptions options, {
    http.Client Function()? clientFactory,
  }) async* {
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
    final http.Client client =
        clientFactory != null ? clientFactory() : http.Client();
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
        // 官方：输入未通过审核时返回 400 Content Exists Risk（输入 token 仍计费）。
        if (response.statusCode == 400 &&
            body.contains('Content Exists Risk')) {
          throw const ChatException('本次对话未通过内容安全审核，请调整内容后重试');
        }
        throw ChatException(
          '服务商返回状态码 ${response.statusCode}: ${_truncate(body)}',
        );
      }

      bool sawDone = false;
      bool sawError = false;
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
          // 官方：生成中失败时最后一个 chunk 带 error、choices 为空、且没有 [DONE]。
          // 收到错误立即结束，不要把半截回答当成功。
          if (event.error.isNotEmpty) {
            sawError = true;
            break;
          }
        }
      }
      if (sawError) {
        return;
      }
      if (!sawDone) {
        // 没有 [DONE] 就断流：保留已收到的正文，但必须让上层显示失败而不是成功。
        yield const ChatStreamEvent(
          error: '连接中断，回答可能不完整，请重试',
        );
        return;
      }
      yield const ChatStreamEvent(done: true);
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
      // 生成中失败：官方最后一个 chunk 是 {"error": {...}, "usage": ...}，
      // 没有 choices，也没有 [DONE]。先于 choices 解析，否则整条错误被丢掉。
      final String streamError = _errorMessage(parsed['error']);
      if (streamError.isNotEmpty) {
        return ChatStreamEvent(error: streamError);
      }
      final Object? choices = parsed['choices'];
      if (choices is! List || choices.isEmpty) {
        return null;
      }
      final Object? choice = choices.first;
      if (choice is! Map) {
        return null;
      }
      // `server_tool_event` 与 `delta` 并列；`annotations`/`server_tool_calls`/`title`
      // 只在末块出现，且末块可能没有正文增量。把 delta 当解析前提会丢掉这些块。
      final Object? deltaRaw = choice['delta'];
      final Map<Object?, Object?> delta =
          deltaRaw is Map ? deltaRaw : const <Object?, Object?>{};
      final Object? content = delta['content'];
      final Object? reasoning = delta['reasoning_content'];
      final _ToolEvent toolEvent = _parseToolEvent(choice['server_tool_event']);
      final List<CitationRange> citations = _parseAnnotations(delta['annotations']);
      // 完整的 server_tool_calls 只在带 finish_reason 的最后一个 chunk 下发一次；
      // 只保留带 signature 的阅读链接调用，搜索结构不回传也不占存储。
      final String toolCallsJson = encodeServerToolCalls(delta['server_tool_calls']);
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
      final Object? finishRaw = choice['finish_reason'];
      final String finishReason = finishRaw is String ? finishRaw : '';
      String refusal = '';
      if (finishReason == 'content_filter') {
        refusal = '内容未通过安全审核';
      }
      // 输出达到长度上限（含「搜索/阅读链接后上下文已用尽」）：正文被截断。
      final bool truncated = finishReason == 'length';
      // 后端资源不足 / 服务端中止：连接可能是 200 + 半截正文，必须按失败处理。
      String error = '';
      if (finishReason == 'insufficient_system_resource') {
        error = '服务资源不足，生成被中断，请重试';
      } else if (finishReason == 'aborted') {
        error = '生成被中断，请重试';
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
      }
      return ChatStreamEvent(
        content: content is String ? content : '',
        reasoning: reasoning is String ? reasoning : '',
        searchHint: toolEvent.hint,
        sources: sources,
        citations: citations,
        title: title,
        refusal: refusal,
        truncated: truncated,
        error: error,
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
  ///
  /// [reminder] 非空时，每条 user 消息前插一条 `latest_reminder`
  /// （`<date>,<weekday>,<location>,App,<language>`），让模型知道当前日期与所在地。
  ///
  /// [replayReasoning] 为 false 时不回传 `reasoning_content`（DeepSeek）：
  /// 上一轮的思考被带进新一轮会让模型顺着旧计划作答，且空的思考回合必须整体丢弃。
  static List<Map<String, dynamic>> buildApiMessages(
    List<ChatMessage> messages,
    String? systemPrompt,
    bool enableFiles, {
    ChatReminder? reminder,
    bool replayReasoning = true,
  }) {
    final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
    if (systemPrompt != null && systemPrompt.trim().isNotEmpty) {
      out.add(<String, dynamic>{
        'role': 'system',
        'content': systemPrompt.trim(),
      });
    }
    // 一条历史单位 = 1~2 条线上消息（user 消息可能带一条 latest_reminder），
    // 截断按单位做，避免把 reminder 与它所属的 user 消息拆开（协议要求紧邻）。
    final List<_WireUnit> candidates = <_WireUnit>[];
    for (final ChatMessage message in messages) {
      if (!message.isUser && !message.isAssistant) {
        continue;
      }
      final String replay = message.content;
      final String reasoning =
          replayReasoning ? (message.reasoningContent ?? '') : '';
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
      final List<Map<String, dynamic>> items = <Map<String, dynamic>>[];
      if (reminder != null && message.isUser) {
        items.add(_reminderEntry(message, reminder));
        chars += _reminderChars;
      }
      items.add(item);
      candidates.add(_WireUnit(items: items, chars: chars));
    }

    final int start = candidates.length > _maxHistoryMessages
        ? candidates.length - _maxHistoryMessages
        : 0;
    final List<_WireUnit> kept = <_WireUnit>[];
    int used = 0;
    for (int i = candidates.length - 1; i >= start; i--) {
      final _WireUnit unit = candidates[i];
      if (kept.isNotEmpty && used + unit.chars > _maxHistoryChars) {
        break;
      }
      kept.insert(0, unit);
      used += unit.chars;
    }
    for (final _WireUnit unit in kept) {
      out.addAll(unit.items);
    }
    return out;
  }

  /// latest_reminder 的固定开销（日期/星期/语言），只用于本地字符预算。
  static const int _reminderChars = 32;

  /// `<date>,<weekday>,<location>,App,<language>`（官方《用户元信息标记》）。
  /// Business Rule: 日期取该条消息自己的时间，回放历史时每天仍是当天的日期；
  /// 位于任意非 DeepSeek 服务商会被 400，调用方只在 DeepSeek 下传 reminder。
  static Map<String, dynamic> _reminderEntry(
    ChatMessage message,
    ChatReminder reminder,
  ) {
    final DateTime date =
        DateTime.fromMillisecondsSinceEpoch(message.createdAt);
    final String iso = '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
    final bool isEnglish = reminder.language == 'en-US';
    final String weekday =
        isEnglish ? _enWeekdays[date.weekday - 1] : _zhWeekdays[date.weekday - 1];
    final String language = isEnglish ? 'English' : '中文';
    final String location = sanitizeLocation(reminder.location);
    return <String, dynamic>{
      'role': 'latest_reminder',
      'content': '$iso,$weekday,$location,App,$language',
    };
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
        reminder: options.reminder,
        replayReasoning: options.providerId == 'kimi' ||
            options.providerId == 'mimo',
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

  /// 末块 `{"error": {...}}` → 可展示的失败文案；没有错误返回空串。
  static String _errorMessage(Object? raw) {
    if (raw is! Map) {
      return '';
    }
    final Object? message = raw['message'];
    if (message is String && message.trim().isNotEmpty) {
      return message.trim();
    }
    final Object? code = raw['code'] ?? raw['type'];
    if (code is String && code.isNotEmpty) {
      return '生成失败（$code）';
    }
    return '生成失败，请重试';
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
    final String callType = call['type'] is String ? call['type'] as String : '';
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
      // 失败时 `call_completed` 可能不带 kind/action，用 type 兜底区分阅读链接与搜索。
      final bool readLink = actionType == 'read_link' ||
          kind == 'read_link' ||
          callType == 'deepseek_read_url';
      final String what = readLink
          ? '链接读取失败'
          : (actionType == 'open_page' ? '网页打开失败' : '搜索失败');
      final Object? errorRaw = call['error'];
      String code = '';
      if (errorRaw is Map && errorRaw['code'] is String) {
        code = errorRaw['code'] as String;
      }
      return _ToolEvent(
        hint: '$what${code.isEmpty ? '' : '（$code）'}，继续整理答案…',
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
    final Object? siteIcon = raw['site_icon'];
    return SearchSource(
      url: url,
      title: title is String && title.trim().isNotEmpty ? title.trim() : url,
      snippet: raw['snippet'] is String ? raw['snippet'] as String : null,
      siteName: raw['site_name'] is String ? raw['site_name'] as String : null,
      siteIcon: siteIcon is String &&
              (siteIcon.startsWith('http://') || siteIcon.startsWith('https://'))
          ? siteIcon
          : null,
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
