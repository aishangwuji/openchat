enum MessageRole { user, assistant, system }

enum MessageStatus { sending, streaming, success, error }

enum SceneMode { single, group }

/// 联网搜索来源（持久化，按 url 去重、按出现顺序排列）。
class SearchSource {
  const SearchSource({
    required this.url,
    required this.title,
    this.snippet,
    this.siteName,
    this.publishedAt,
  });

  final String url;
  final String title;
  final String? snippet;
  final String? siteName;
  final String? publishedAt;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'url': url,
        'title': title,
        if (snippet != null) 'snippet': snippet,
        if (siteName != null) 'siteName': siteName,
        if (publishedAt != null) 'publishedAt': publishedAt,
      };

  static SearchSource? tryParse(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final Object? url = raw['url'];
    if (url is! String || !(url.startsWith('http://') || url.startsWith('https://'))) {
      return null;
    }
    final Object? title = raw['title'];
    return SearchSource(
      url: url,
      title: title is String && title.isNotEmpty ? title : url,
      snippet: raw['snippet'] is String ? raw['snippet'] as String : null,
      siteName: raw['siteName'] is String ? raw['siteName'] as String : null,
      publishedAt: raw['publishedAt'] is String ? raw['publishedAt'] as String : null,
    );
  }
}

/// 正文引用区间（偏移以 Unicode 码点计，与 DeepSeek annotations 一致）。
class CitationRange {
  const CitationRange({
    required this.url,
    required this.title,
    required this.start,
    required this.end,
  });

  final String url;
  final String title;
  final int start;
  final int end;
}
/// 已上传到 DeepSeek Files API 的附件（文档/图片）。
class MessageAttachment {
  const MessageAttachment({
    required this.fileId,
    required this.fileName,
    required this.purpose,
    required this.bytes,
  });

  final String fileId;
  final String fileName;
  final String purpose;
  final int bytes;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'fileId': fileId,
        'fileName': fileName,
        'purpose': purpose,
        'bytes': bytes,
      };

  static MessageAttachment? tryParse(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final Object? fileId = raw['fileId'];
    final Object? fileName = raw['fileName'];
    if (fileId is! String || fileId.isEmpty || fileName is! String) {
      return null;
    }
    return MessageAttachment(
      fileId: fileId,
      fileName: fileName,
      purpose: raw['purpose'] is String ? raw['purpose'] as String : 'user_data',
      bytes: raw['bytes'] is num ? (raw['bytes'] as num).toInt() : 0,
    );
  }
}
class ChatMessage {
  ChatMessage({
    required this.id,
    required this.role,
    required this.content,
    required this.createdAt,
    required this.status,
    this.reasoningContent,
    this.thinkingDuration,
    this.errorMessage,
    this.parentId = '',
    List<String>? childIds,
    this.activeChildId = '',
    this.speakerId = '',
    List<String>? mentionedIds,
    List<SearchSource>? sources,
    List<MessageAttachment>? attachments,
    this.imageState,
    List<String>? imageUrls,
    this.imageMeta,
    this.imageAspect,
    this.imagePrompt,
  })  : childIds = childIds ?? <String>[],
        mentionedIds = mentionedIds ?? <String>[],
        sources = sources ?? <SearchSource>[],
        attachments = attachments ?? <MessageAttachment>[],
        imageUrls = imageUrls ?? <String>[];

  final String id;
  final MessageRole role;
  String content;
  String? reasoningContent;
  int? thinkingDuration;
  final int createdAt;
  MessageStatus status;
  String? errorMessage;
  String parentId;
  List<String> childIds;
  String activeChildId;
  String speakerId;
  List<String> mentionedIds;
  /// 联网搜索来源（持久化）；searchHint/searching 为实时字段，不落盘。
  List<SearchSource> sources;
  /// 文档/图片附件（已上传 file_id，仅 DeepSeek 回放）。
  List<MessageAttachment> attachments;
  /// 生图结果（百智云，URL 有时效）。
  String? imageState;
  List<String> imageUrls;
  String? imageMeta;
  double? imageAspect;
  String? imagePrompt;
  String? imageHint;
  String? searchHint;
  bool searching = false;

  bool get isUser => role == MessageRole.user;
  bool get isAssistant => role == MessageRole.assistant;

  static String roleToWire(MessageRole role) {
    switch (role) {
      case MessageRole.user:
        return 'user';
      case MessageRole.assistant:
        return 'assistant';
      case MessageRole.system:
        return 'system';
    }
  }

  static MessageRole roleFromWire(Object? value) {
    if (value == 'assistant') {
      return MessageRole.assistant;
    }
    if (value == 'system') {
      return MessageRole.system;
    }
    return MessageRole.user;
  }

  static MessageStatus statusFromWire(Object? value) {
    if (value == 'sending') {
      return MessageStatus.sending;
    }
    if (value == 'streaming') {
      return MessageStatus.streaming;
    }
    if (value == 'error') {
      return MessageStatus.error;
    }
    return MessageStatus.success;
  }

  static String statusToWire(MessageStatus status) {
    switch (status) {
      case MessageStatus.sending:
        return 'sending';
      case MessageStatus.streaming:
        return 'streaming';
      case MessageStatus.success:
        return 'success';
      case MessageStatus.error:
        return 'error';
    }
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'role': roleToWire(role),
        'content': content,
        if (reasoningContent != null) 'reasoningContent': reasoningContent,
        if (thinkingDuration != null) 'thinkingDuration': thinkingDuration,
        'createdAt': createdAt,
        'status': statusToWire(status),
        if (errorMessage != null) 'errorMessage': errorMessage,
        'parentId': parentId,
        'childIds': childIds,
        'activeChildId': activeChildId,
        'speakerId': speakerId,
        'mentionedIds': mentionedIds,
        if (imageState != null) 'imageState': imageState,
        if (imageUrls.isNotEmpty) 'imageUrls': imageUrls,
        if (imageMeta != null) 'imageMeta': imageMeta,
        if (imageAspect != null) 'imageAspect': imageAspect,
        if (imagePrompt != null) 'imagePrompt': imagePrompt,
        if (attachments.isNotEmpty)
          'attachments': attachments.map((MessageAttachment a) => a.toJson()).toList(),
        if (sources.isNotEmpty)
          'sources': sources.map((SearchSource s) => s.toJson()).toList(),
      };

  /// Boundary parser: persisted data is untrusted, so every field is
  /// type-checked and invalid records are dropped by the caller.
  static ChatMessage? tryParse(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final Object? id = raw['id'];
    if (id is! String || id.isEmpty) {
      return null;
    }
    final Object? childIdsRaw = raw['childIds'];
    final List<String> childIds = <String>[];
    if (childIdsRaw is List) {
      for (final Object? c in childIdsRaw) {
        if (c is String) {
          childIds.add(c);
        }
      }
    }
    final Object? mentionedRaw = raw['mentionedIds'];
    final List<String> mentioned = <String>[];
    if (mentionedRaw is List) {
      for (final Object? m in mentionedRaw) {
        if (m is String && m.isNotEmpty) {
          mentioned.add(m);
        }
      }
    }
    return ChatMessage(
      id: id,
      role: roleFromWire(raw['role']),
      content: raw['content'] is String ? raw['content'] as String : '',
      reasoningContent:
          raw['reasoningContent'] is String ? raw['reasoningContent'] as String : null,
      thinkingDuration:
          raw['thinkingDuration'] is num ? (raw['thinkingDuration'] as num).round() : null,
      createdAt: raw['createdAt'] is num
          ? (raw['createdAt'] as num).toInt()
          : DateTime.now().millisecondsSinceEpoch,
      status: statusFromWire(raw['status']),
      errorMessage: raw['errorMessage'] is String ? raw['errorMessage'] as String : null,
      parentId: raw['parentId'] is String ? raw['parentId'] as String : '',
      childIds: childIds,
      activeChildId: raw['activeChildId'] is String ? raw['activeChildId'] as String : '',
      speakerId: raw['speakerId'] is String ? raw['speakerId'] as String : '',
      mentionedIds: mentioned,
      sources: _parseSources(raw['sources']),
      attachments: _parseAttachments(raw['attachments']),
      imageState: raw['imageState'] is String ? raw['imageState'] as String : null,
      imageUrls: _parseImageUrls(raw['imageUrls']),
      imageMeta: raw['imageMeta'] is String ? raw['imageMeta'] as String : null,
      imageAspect: raw['imageAspect'] is num ? (raw['imageAspect'] as num).toDouble() : null,
      imagePrompt: raw['imagePrompt'] is String ? raw['imagePrompt'] as String : null,
    );
  }
}

class ChatSession {
  ChatSession({
    required this.id,
    required this.title,
    required this.characterId,
    required this.providerId,
    required this.modelId,
    required this.updatedAt,
    List<ChatMessage>? messages,
    List<String>? rootIds,
    this.activeRootId = '',
    List<String>? participantIds,
    this.sceneMode = SceneMode.single,
    Map<String, String>? joinMap,
    this.userIdentityId = '',
    this.isPrivate = false,
    this.autoTitled = false,
  })  : messages = messages ?? <ChatMessage>[],
        rootIds = rootIds ?? <String>[],
        participantIds = participantIds ?? <String>[],
        joinMap = joinMap ?? <String, String>{};

  final String id;
  String title;
  String characterId;
  String providerId;
  String modelId;
  int updatedAt;
  final List<ChatMessage> messages;
  List<String> rootIds;
  String activeRootId;
  List<String> participantIds;
  SceneMode sceneMode;
  Map<String, String> joinMap;
  String userIdentityId;
  bool isPrivate;

  /// 是否已向服务端请求过自动标题（每个会话只请求一次；失败也置位，避免每轮多等 5 秒）。
  bool autoTitled;

  bool get isGroup => sceneMode == SceneMode.group && participantIds.length >= 2;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'title': title,
        'characterId': characterId,
        'providerId': providerId,
        'modelId': modelId,
        'updatedAt': updatedAt,
        'messages': messages.map((ChatMessage m) => m.toJson()).toList(growable: false),
        'rootIds': rootIds,
        'activeRootId': activeRootId,
        'participantIds': participantIds,
        'sceneMode': sceneMode == SceneMode.group ? 'group' : 'single',
        'joinMap': joinMap,
        'userIdentityId': userIdentityId,
        'isPrivate': isPrivate,
        'autoTitled': autoTitled,
      };
}

class CharacterCard {
  CharacterCard({
    required this.id,
    required this.name,
    this.avatarIcon = 'custom',
    this.description = '',
    this.systemPrompt = '',
    this.firstMessage = '',
    this.temperature = 0.7,
    this.knowledge = '',
    required this.createdAt,
  });

  final String id;
  String name;
  String avatarIcon;
  String description;
  String systemPrompt;
  String firstMessage;
  double temperature;
  String knowledge;
  final int createdAt;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'avatarIcon': avatarIcon,
        'description': description,
        'systemPrompt': systemPrompt,
        'firstMessage': firstMessage,
        'temperature': temperature,
        'knowledge': knowledge,
        'createdAt': createdAt,
      };

  static CharacterCard? tryParse(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final Object? id = raw['id'];
    if (id is! String || id.isEmpty) {
      return null;
    }
    return CharacterCard(
      id: id,
      name: raw['name'] is String ? raw['name'] as String : '未命名',
      avatarIcon: raw['avatarIcon'] is String ? raw['avatarIcon'] as String : 'custom',
      description: raw['description'] is String ? raw['description'] as String : '',
      systemPrompt: raw['systemPrompt'] is String ? raw['systemPrompt'] as String : '',
      firstMessage: raw['firstMessage'] is String ? raw['firstMessage'] as String : '',
      temperature: raw['temperature'] is num ? (raw['temperature'] as num).toDouble() : 0.7,
      knowledge: raw['knowledge'] is String ? raw['knowledge'] as String : '',
      createdAt: raw['createdAt'] is num
          ? (raw['createdAt'] as num).toInt()
          : DateTime.now().millisecondsSinceEpoch,
    );
  }
}

class UserIdentityCard {
  UserIdentityCard({
    required this.id,
    required this.name,
    this.persona = '',
    required this.createdAt,
  });

  final String id;
  String name;
  String persona;
  final int createdAt;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'persona': persona,
        'createdAt': createdAt,
      };

  static UserIdentityCard? tryParse(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final Object? id = raw['id'];
    if (id is! String || id.isEmpty) {
      return null;
    }
    return UserIdentityCard(
      id: id,
      name: raw['name'] is String ? raw['name'] as String : '未命名',
      persona: raw['persona'] is String ? raw['persona'] as String : '',
      createdAt: raw['createdAt'] is num
          ? (raw['createdAt'] as num).toInt()
          : DateTime.now().millisecondsSinceEpoch,
    );
  }
}

class ModelInfo {
  const ModelInfo({required this.id, required this.name});

  final String id;
  final String name;
}

List<SearchSource> _parseSources(Object? raw) {
  if (raw is! List) {
    return <SearchSource>[];
  }
  final List<SearchSource> out = <SearchSource>[];
  for (final Object? item in raw) {
    final SearchSource? source = SearchSource.tryParse(item);
    if (source != null && !out.any((SearchSource s) => s.url == source.url)) {
      out.add(source);
    }
  }
  return out;
}

List<MessageAttachment> _parseAttachments(Object? raw) {
  if (raw is! List) {
    return <MessageAttachment>[];
  }
  final List<MessageAttachment> out = <MessageAttachment>[];
  for (final Object? item in raw) {
    final MessageAttachment? a = MessageAttachment.tryParse(item);
    if (a != null) {
      out.add(a);
    }
  }
  return out;
}

List<String> _parseImageUrls(Object? raw) {
  if (raw is! List) {
    return <String>[];
  }
  final List<String> out = <String>[];
  for (final Object? item in raw) {
    if (item is String &&
        (item.startsWith('http://') || item.startsWith('https://'))) {
      out.add(item);
    }
  }
  return out.take(4).toList(growable: false);
}