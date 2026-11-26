import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/models/chat_models.dart';
import '../data/models/provider.dart';
import '../core/utils/markdown_utils.dart';
import '../data/services/auth_service.dart';

import '../data/services/baizhi_web_search_service.dart';
import 'dart:convert';

import '../data/services/file_upload_service.dart';
import '../data/services/image_gen_service.dart';
import '../data/services/chat_service.dart';
import '../data/services/chat_storage_service.dart';
import '../data/services/key_store.dart';
import '../data/services/model_service.dart';
import 'settings_controller.dart';

CharacterCard emptyCharacter() => CharacterCard(
      id: '',
      name: '助手',
      systemPrompt: '',
      firstMessage: '',
      temperature: 0.7,
      createdAt: 0,
    );

/// DeepSeek 服务端扩展能力是否要求 `deepseek-flash`。
///
/// Business Rule: 官方《联网工具》《文件解析》《模型内容安全》《会话标题》都要求
/// `deepseek-flash`；`deepseek-v4-pro` 不支持图像理解。只要任一能力开启，发送前
/// 就把模型切回 flash，宁可改变用户选择也不静默降级。
bool requiresDeepSeekFlash({
  required String providerId,
  required bool webSearch,
  required bool files,
  required bool readUrl,
  required bool safety,
  required bool title,
}) {
  if (providerId != 'deepseek') {
    return false;
  }
  return webSearch || files || readUrl || safety || title;
}

/// 是否进入请求历史：正文、附件、服务端工具调用任一非空即可。
///
/// Business Rule: 只按 `content` 判空会把「只传文件」「只读链接/拒答但保留
/// signature」的轮次整条丢掉，表现为下一轮模型突然看不到文档或网页。
bool isReplayableMessage(ChatMessage message) {
  if (!message.isUser && !message.isAssistant) {
    return false;
  }
  return message.content.isNotEmpty ||
      message.attachments.isNotEmpty ||
      message.serverToolCallsJson.isNotEmpty;
}

/// Owns session tree state, streaming and model selection.
///
/// Concurrency notes:
/// 1. Each reply gets a monotonically increasing generation token; late
///    callbacks from a stopped or replaced stream are ignored.
/// 2. UI updates during streaming are coalesced on a 120ms ticker so token
///    bursts cannot starve the frame pipeline.
class ChatController extends ChangeNotifier {
  ChatController({
    required ChatStorageService storage,
    required SettingsController settings,
    required KeyStore keyStore,
    required AuthService auth,
  })  : _storage = storage,
        _settings = settings,
        _keyStore = keyStore,
        _auth = auth;

  final ChatStorageService _storage;
  final SettingsController _settings;
  final KeyStore _keyStore;
  final AuthService _auth;

  final List<ChatSession> _sessions = <ChatSession>[];
  final List<CharacterCard> _characters = <CharacterCard>[];
  final List<UserIdentityCard> _identities = <UserIdentityCard>[];
  final List<ModelInfo> _availableModels = <ModelInfo>[];
  final List<ProviderDefinition> _configuredProviders = <ProviderDefinition>[];
  final Set<String> _collapsedReasons = <String>{};

  ChatSession? _draft;
  String _currentSessionId = '';
  String _currentCharacterId = '';
  String _currentProviderId = 'deepseek';
  String _currentModelId = '';
  String _currentApiKey = '';
  bool _enableThinking = true;
  bool _enableWebSearch = true;
  final List<MessageAttachment> _pendingAttachments = <MessageAttachment>[];
  bool _attachmentBusy = false; // ignore: prefer_final_fields
  bool _isGenerating = false;
  bool _fetchingModels = false;
  bool _initialized = false;
  String _noticeText = '';
  StreamSubscription<ChatStreamEvent>? _subscription;
  Timer? _ticker;
  int _seq = 0;
  int _generation = 0;

  bool get initialized => _initialized;
  List<ChatSession> get sessions => List<ChatSession>.unmodifiable(_sessions);
  List<CharacterCard> get characters =>
      List<CharacterCard>.unmodifiable(_characters);
  List<UserIdentityCard> get identities =>
      List<UserIdentityCard>.unmodifiable(_identities);
  List<ModelInfo> get availableModels =>
      List<ModelInfo>.unmodifiable(_availableModels);
  List<ProviderDefinition> get configuredProviders =>
      List<ProviderDefinition>.unmodifiable(_configuredProviders);
  String get currentSessionId => _currentSessionId;
  String get currentCharacterId => _currentCharacterId;
  String get currentProviderId => _currentProviderId;
  String get currentModelId => _currentModelId;
  String get currentApiKey => _currentApiKey;
  bool get featureAsr => _settings.featureAsr;
  bool get featureTts => _settings.featureTts;
  String get ttsVoice => _settings.ttsVoice;
  bool get enableThinking => _enableThinking;
  bool get enableWebSearch => _enableWebSearch;
  List<MessageAttachment> get pendingAttachments =>
      List<MessageAttachment>.unmodifiable(_pendingAttachments);
  bool get attachmentBusy => _attachmentBusy;
  bool get isGenerating => _isGenerating;
  bool get fetchingModels => _fetchingModels;
  String get noticeText => _noticeText;

  ChatSession? get currentSession {
    final ChatSession? draft = _draft;
    if (draft != null && draft.id == _currentSessionId) {
      return draft;
    }
    for (final ChatSession session in _sessions) {
      if (session.id == _currentSessionId) {
        return session;
      }
    }
    return null;
  }

  List<ChatMessage> get activePath {
    final ChatSession? session = currentSession;
    if (session == null) {
      return const <ChatMessage>[];
    }
    final List<ChatMessage> path = <ChatMessage>[];
    String cursor = session.activeRootId;
    int guard = 0;
    while (cursor.isNotEmpty && guard < 2000) {
      guard++;
      final ChatMessage? node = findMessage(session, cursor);
      if (node == null) {
        break;
      }
      path.add(node);
      cursor = node.activeChildId;
    }
    return path;
  }

  String get providerName =>
      findProvider(_currentProviderId)?.name ?? _currentProviderId;

  bool get thinkingSupported =>
      isThinkingSupported(_currentProviderId, _currentModelId);

  String get sessionTitle => currentSession?.title ?? '新对话';

  Future<void> init() async {
    if (_initialized) {
      return;
    }
    _characters
      ..clear()
      ..addAll(await _storage.loadCharacters());
    _identities
      ..clear()
      ..addAll(await _storage.loadIdentities());
    final List<ChatSession> loaded = await _storage.loadSessions();
    final List<ChatSession> kept = loaded
        .where((ChatSession s) => s.messages.isNotEmpty)
        .toList(growable: false);
    _sessions
      ..clear()
      ..addAll(kept);
    if (kept.length != loaded.length) {
      await _storage.saveSessions(_sessions);
    }
    if (_characters.isNotEmpty) {
      _currentCharacterId = _characters.first.id;
    }
    _createNewSessionInternal();
    await loadConfiguredProviders();
    if (_configuredProviders.isNotEmpty) {
      _currentProviderId = _configuredProviders.first.id;
      final ChatSession? draft = _draft;
      if (draft != null) {
        draft.providerId = _currentProviderId;
      }
    }
    await _reloadApiKey();
    unawaited(refreshModelList());
    _initialized = true;
    notifyListeners();
  }

  // ── Session tree helpers ──

  ChatMessage? findMessage(ChatSession session, String id) {
    for (final ChatMessage m in session.messages) {
      if (m.id == id) {
        return m;
      }
    }
    return null;
  }

  List<ChatMessage> pathToNode(ChatSession session, String targetId) {
    final List<ChatMessage> rev = <ChatMessage>[];
    String cursor = targetId;
    int guard = 0;
    while (cursor.isNotEmpty && guard < 2000) {
      guard++;
      final ChatMessage? node = findMessage(session, cursor);
      if (node == null) {
        break;
      }
      rev.add(node);
      cursor = node.parentId;
    }
    return rev.reversed.toList(growable: false);
  }

  List<ChatMessage> historyTo(ChatSession session, String targetId) {
    final List<ChatMessage> full = pathToNode(session, targetId);
    return full.where(isReplayableMessage).toList(growable: false);
  }

  List<String> siblingsOf(ChatSession session, ChatMessage message) {
    if (message.parentId.isEmpty) {
      return List<String>.from(session.rootIds);
    }
    final ChatMessage? parent = findMessage(session, message.parentId);
    if (parent == null) {
      return <String>[message.id];
    }
    return List<String>.from(parent.childIds);
  }

  int siblingIndex(ChatSession session, ChatMessage message) {
    final List<String> siblings = siblingsOf(session, message);
    final int index = siblings.indexOf(message.id);
    return index < 0 ? 0 : index;
  }

  int branchCount(ChatMessage message) {
    final ChatSession? session = currentSession;
    return session == null ? 1 : siblingsOf(session, message).length;
  }

  int branchIndex(ChatMessage message) {
    final ChatSession? session = currentSession;
    return session == null ? 0 : siblingIndex(session, message);
  }

  String nextId(String role) {
    _seq++;
    return 'msg_${role}_${DateTime.now().millisecondsSinceEpoch}_$_seq';
  }

  ChatMessage buildMessage(
    MessageRole role,
    String content,
    String parentId, {
    List<MessageAttachment> attachments = const <MessageAttachment>[],
  }) {
    return ChatMessage(
      id: nextId(ChatMessage.roleToWire(role)),
      role: role,
      content: content,
      reasoningContent: role == MessageRole.assistant ? '' : null,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      status: MessageStatus.success,
      parentId: parentId,
      attachments: List<MessageAttachment>.from(attachments),
    );
  }

  void attach(ChatSession session, ChatMessage node) {
    _promoteDraftIfNeeded(session);
    session.messages.add(node);
    if (node.parentId.isEmpty) {
      session.rootIds.add(node.id);
      session.activeRootId = node.id;
      return;
    }
    final ChatMessage? parent = findMessage(session, node.parentId);
    if (parent == null) {
      node.parentId = '';
      session.rootIds.add(node.id);
      session.activeRootId = node.id;
      return;
    }
    parent.childIds.add(node.id);
    parent.activeChildId = node.id;
  }

  void _promoteDraftIfNeeded(ChatSession session) {
    final ChatSession? draft = _draft;
    if (draft == null || draft.id != session.id) {
      return;
    }
    _draft = null;
    _sessions.insert(0, session);
    unawaited(_saveState());
  }

  // ── Session lifecycle ──

  void _createNewSessionInternal() {
    _currentSessionId = 'session_${DateTime.now().millisecondsSinceEpoch}';
    _draft = ChatSession(
      id: _currentSessionId,
      title: '新对话',
      characterId: '',
      providerId: _currentProviderId,
      modelId: _currentModelId,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    _currentCharacterId = '';
    _noticeText = '';
    _collapsedReasons.clear();
  }

  void createNewSession() {
    _createNewSessionInternal();
    notifyListeners();
  }

  Future<void> switchSession(String sessionId) async {
    if (_draft != null && _draft!.id != sessionId) {
      _draft = null;
    }
    _currentSessionId = sessionId;
    final ChatSession? session = currentSession;
    if (session != null) {
      _currentProviderId = session.providerId;
      _currentModelId = session.modelId;
      _currentCharacterId = session.characterId;
      await _reloadApiKey();
      await refreshModelList();
    }
    _initCollapsedReasons();
    await _storage.saveActiveSessionId(sessionId);
    notifyListeners();
  }

  Future<void> openSessionWithPrivacy(ChatSession session) async {
    if (session.isPrivate) {
      final bool ok = await _auth.authenticate('解锁保密对话');
      if (!ok) {
        return;
      }
    }
    await switchSession(session.id);
  }

  Future<void> deleteSession(String sessionId) async {
    _sessions.removeWhere((ChatSession s) => s.id == sessionId);
    if (_currentSessionId == sessionId) {
      final String nextId = _firstNonPrivateSessionId();
      if (nextId.isNotEmpty) {
        await switchSession(nextId);
      } else {
        _createNewSessionInternal();
      }
    }
    await _saveState();
    notifyListeners();
  }

  String _firstNonPrivateSessionId() {
    for (final ChatSession s in _sessions) {
      if (!s.isPrivate) {
        return s.id;
      }
    }
    return '';
  }

  Future<void> renameSession(String sessionId, String title) async {
    final String trimmed = title.trim();
    if (trimmed.isEmpty) {
      return;
    }
    for (final ChatSession s in _sessions) {
      if (s.id == sessionId) {
        s.title = trimmed;
        break;
      }
    }
    await _saveState();
    notifyListeners();
  }

  /// 当前标题是否仍是自动取名：默认名，或首条用户消息的截断标题。
  /// Business Rule: 只有自动取名的标题才允许被服务端标题覆盖，用户重命名过的必须保留。
  bool _isAutoTitle(ChatSession session) {
    if (session.title == '新对话') {
      return true;
    }
    final String first = _firstUserText(session);
    if (first.isEmpty) {
      return false;
    }
    return session.title == autoTitleFor(first);
  }

  /// 首条用户消息正文（按 createdAt 取最早，兼容分叉后 messages 顺序不固定）。
  String _firstUserText(ChatSession session) {
    ChatMessage? earliest;
    for (final ChatMessage m in session.messages) {
      if (!m.isUser || m.content.trim().isEmpty) {
        continue;
      }
      if (earliest == null || m.createdAt < earliest.createdAt) {
        earliest = m;
      }
    }
    return earliest?.content ?? '';
  }

  Future<void> toggleSessionPrivacy(String sessionId) async {
    ChatSession? session;
    for (final ChatSession s in _sessions) {
      if (s.id == sessionId) {
        session = s;
        break;
      }
    }
    if (session == null) {
      return;
    }
    if (session.isPrivate) {
      final bool ok = await _auth.authenticate('取消保密需要验证身份');
      if (!ok) {
        return;
      }
      session.isPrivate = false;
    } else {
      session.isPrivate = true;
    }
    await _saveState();
    notifyListeners();
  }

  bool sessionIsPrivate(String sessionId) {
    for (final ChatSession s in _sessions) {
      if (s.id == sessionId) {
        return s.isPrivate;
      }
    }
    return false;
  }

  // ── Characters and identities ──

  CharacterCard? characterById(String id) {
    for (final CharacterCard c in _characters) {
      if (c.id == id) {
        return c;
      }
    }
    return null;
  }

  UserIdentityCard? identityById(String id) {
    for (final UserIdentityCard c in _identities) {
      if (c.id == id) {
        return c;
      }
    }
    return null;
  }

  CharacterCard get currentCharacter =>
      characterById(_currentCharacterId) ?? emptyCharacter();

  Future<CharacterCard> saveCharacter({
    String? id,
    required String name,
    required String systemPrompt,
    required String firstMessage,
    required double temperature,
  }) async {
    final String trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('角色名称不能为空');
    }
    CharacterCard? updated;
    for (int i = 0; i < _characters.length; i++) {
      final CharacterCard c = _characters[i];
      if (c.id == id) {
        updated = CharacterCard(
          id: c.id,
          name: trimmed,
          avatarIcon: c.avatarIcon,
          description: c.description,
          systemPrompt: systemPrompt.trim(),
          firstMessage: firstMessage.trim(),
          temperature: temperature,
          knowledge: c.knowledge,
          createdAt: c.createdAt,
        );
        _characters[i] = updated;
        break;
      }
    }
    updated ??= CharacterCard(
      id: 'char_${DateTime.now().millisecondsSinceEpoch}',
      name: trimmed,
      systemPrompt: systemPrompt.trim(),
      firstMessage: firstMessage.trim(),
      temperature: temperature,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    if (!_characters.contains(updated)) {
      _characters.insert(0, updated);
    }
    _currentCharacterId = updated.id;
    await _storage.saveCharacters(_characters);
    notifyListeners();
    return updated;
  }

  Future<void> deleteCharacter(String id) async {
    _characters.removeWhere((CharacterCard c) => c.id == id);
    if (_currentCharacterId == id) {
      _currentCharacterId = '';
      final ChatSession? session = currentSession;
      if (session != null) {
        session.characterId = '';
      }
    }
    await _storage.saveCharacters(_characters);
    await _saveState();
    notifyListeners();
  }

  void selectCharacterForDraft(String characterId) {
    _currentCharacterId = characterId;
    final ChatSession? session = currentSession;
    if (session != null && session.messages.isEmpty) {
      session.characterId = characterId;
      session.participantIds = characterId.isEmpty ? <String>[] : <String>[characterId];
      _currentCharacterId = characterId;
    }
    notifyListeners();
  }

  void selectIdentityForDraft(String identityId) {
    final ChatSession? session = currentSession;
    if (session != null && session.messages.isEmpty) {
      session.userIdentityId = identityId;
      notifyListeners();
    }
  }

  Future<void> saveIdentity({
    String? id,
    required String name,
    required String persona,
  }) async {
    final String trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('身份名称不能为空');
    }
    UserIdentityCard? updated;
    for (int i = 0; i < _identities.length; i++) {
      final UserIdentityCard c = _identities[i];
      if (c.id == id) {
        updated = UserIdentityCard(
          id: c.id,
          name: trimmed,
          persona: persona.trim(),
          createdAt: c.createdAt,
        );
        _identities[i] = updated;
        break;
      }
    }
    updated ??= UserIdentityCard(
      id: 'identity_${DateTime.now().millisecondsSinceEpoch}',
      name: trimmed,
      persona: persona.trim(),
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    if (!_identities.contains(updated)) {
      _identities.insert(0, updated);
    }
    await _storage.saveIdentities(_identities);
    notifyListeners();
  }

  Future<void> deleteIdentity(String id) async {
    _identities.removeWhere((UserIdentityCard c) => c.id == id);
    await _storage.saveIdentities(_identities);
    await _saveState();
    notifyListeners();
  }

  /// Binds the selected character/identity to the current draft on confirm.
  Future<void> bindDraftParticipants({
    required String characterId,
    required String identityId,
  }) async {
    final ChatSession? session = currentSession;
    if (session == null) {
      return;
    }
    if (session.characterId.isNotEmpty ||
        session.participantIds.isNotEmpty ||
        session.userIdentityId.isNotEmpty) {
      return;
    }
    session.characterId = characterId;
    session.participantIds = characterId.isEmpty ? <String>[] : <String>[characterId];
    session.userIdentityId = identityId;
    _currentCharacterId = characterId;
    final CharacterCard? c = characterById(characterId);
    if (c != null &&
        c.firstMessage.trim().isNotEmpty &&
        session.messages.isEmpty) {
      final ChatMessage welcome = buildMessage(
        MessageRole.assistant,
        c.firstMessage.trim(),
        '',
      );
      attach(session, welcome);
    }
    await _saveState();
    notifyListeners();
  }

  // ── Providers and models ──

  Future<void> loadConfiguredProviders() async {
    final List<ProviderDefinition> out = <ProviderDefinition>[];
    // Only chat-capable providers: balance-only ones (Baizhi cookie wallet)
    // store a session cookie that must never be sent to chat endpoints.
    for (final ProviderDefinition p in chatProviders) {
      final String key = await _keyStore.read(KeyStore.providerKey(p.id));
      if (key.trim().isNotEmpty) {
        out.add(p);
      }
    }
    _configuredProviders
      ..clear()
      ..addAll(out);
    notifyListeners();
  }

  Future<void> _reloadApiKey() async {
    _currentApiKey = await _keyStore.read(KeyStore.providerKey(_currentProviderId));
  }

  Future<void> refreshModelList() async {
    _fetchingModels = true;
    notifyListeners();
    try {
      final List<ModelInfo> models =
          await ModelService.fetchModels(_currentProviderId, _currentApiKey);
      _availableModels
        ..clear()
        ..addAll(models);
      if (models.isNotEmpty &&
          !models.any((ModelInfo m) => m.id == _currentModelId)) {
        _currentModelId = models.first.id;
        final ChatSession? session = currentSession;
        if (session != null) {
          session.modelId = _currentModelId;
        }
        unawaited(_saveState());
      }
    } finally {
      _fetchingModels = false;
      notifyListeners();
    }
  }

  Future<void> selectProvider(String providerId) async {
    _currentProviderId = providerId;
    final ChatSession? session = currentSession;
    if (session != null) {
      session.providerId = providerId;
    }
    await _reloadApiKey();
    await refreshModelList();
    if (thinkingSupported) {
      _enableThinking = true;
    }
    await _saveState();
    notifyListeners();
  }

  Future<void> selectModel(String modelId) async {
    _currentModelId = modelId;
    final ChatSession? session = currentSession;
    if (session != null) {
      session.modelId = modelId;
    }
    if (isThinkingSupported(_currentProviderId, modelId)) {
      _enableThinking = true;
    }
    await _saveState();
    notifyListeners();
  }

  void setEnableThinking(bool value) {
    _enableThinking = value;
    notifyListeners();
  }

  void setEnableWebSearch(bool value) {
    _enableWebSearch = value;
    notifyListeners();
  }

  void clearNotice() {
    if (_noticeText.isEmpty) {
      return;
    }
    _noticeText = '';
    notifyListeners();
  }

  bool _canSend() {
    if (_currentApiKey.trim().isEmpty) {
      _noticeText = '未配置 [$providerName] 的 API Key，请先在设置中添加';
      notifyListeners();
      return false;
    }
    if (_currentModelId.trim().isEmpty || _currentModelId == '选择模型') {
      _noticeText = '请先点击右上角选择一个有效模型';
      notifyListeners();
      return false;
    }
    _noticeText = '';
    return true;
  }

  /// DeepSeek 服务端扩展能力是否已开启（联网走百智云时不算服务端工具）。
  bool get _needsDeepSeekFlash => requiresDeepSeekFlash(
        providerId: _currentProviderId,
        webSearch: _enableWebSearch &&
            _settings.webSearchProvider != webSearchProviderBaizhi,
        files: _settings.featureFiles,
        readUrl: _settings.featureReadUrl,
        safety: _settings.featureSafety,
        title: _settings.featureTitle,
      );

  /// 发送前把 DeepSeek 模型切回 `deepseek-flash`，并给出可解释的提示。
  ///
  /// 只改当前请求用的模型与会话记录，用户之后关闭全部扩展能力仍可手动选回 v4-pro。
  void _ensureDeepSeekFlashModel() {
    if (!_needsDeepSeekFlash || _currentModelId == deepSeekFlashModel) {
      return;
    }
    _currentModelId = deepSeekFlashModel;
    final ChatSession? session = currentSession;
    if (session != null) {
      session.modelId = _currentModelId;
    }
    _noticeText =
        '联网/文件/内容安全/会话标题等能力需要 $deepSeekFlashModel，已自动切换模型';
    unawaited(_saveState());
    notifyListeners();
  }

  // ── Sending and streaming ──

  Future<void> sendMessage(String text) async {
    final String trimmed = text.trim();
    final List<MessageAttachment> attachments =
        List<MessageAttachment>.from(_pendingAttachments);
    if ((trimmed.isEmpty && attachments.isEmpty) || _isGenerating) {
      return;
    }
    final ChatSession? session = currentSession;
    if (session == null || !_canSend()) {
      return;
    }
    if (session.title == '新对话' && trimmed.isNotEmpty) {
      session.title = autoTitleFor(trimmed);
    }
    final List<ChatMessage> path = activePath;
    final String parentId = path.isEmpty ? '' : path.last.id;
    final ChatMessage userMsg = buildMessage(
      MessageRole.user,
      trimmed,
      parentId,
      attachments: attachments,
    );
    _pendingAttachments.clear();
    attach(session, userMsg);
    session.updatedAt = DateTime.now().millisecondsSinceEpoch;
    notifyListeners();
    generateReply(session, userMsg, currentCharacter);
  }

  Future<void> generateReply(
    ChatSession session,
    ChatMessage parentMessage,
    CharacterCard speaker,
  ) async {
    // 联网/文件/安全/标题等能力只用 deepseek-flash 有官方保证；必须在组装请求前切。
    _ensureDeepSeekFlashModel();
    final ChatMessage assistant = buildMessage(
      MessageRole.assistant,
      '',
      parentMessage.id,
    )
      ..status = MessageStatus.streaming
      ..speakerId = speaker.id;
    attach(session, assistant);
    session.updatedAt = DateTime.now().millisecondsSinceEpoch;

    _isGenerating = true;
    _generation++;
    final int token = _generation;
    _startTicker();
    notifyListeners();

    final List<ChatMessage> rawHistory = historyTo(session, parentMessage.id);
    final String identityName = _currentIdentityName(session);
    // Business Rule: 回放副本必须把可回放字段（附件等）原样带过去，
    // 否则第二轮起 buildApiMessages 看不到 file_id，文档问答会「上一轮还记得、下一轮就失忆」。
    final List<ChatMessage> history = rawHistory
        .map((ChatMessage m) => replayMessage(m, identityName))
        .toList(growable: false);

    // 百智云联网搜索：发送前先检索，把摘要注入系统提示、来源挂到本条消息。
    // Business Rule: 检索失败降级为普通回答，绝不阻塞对话。
    String webContext = '';
    if (_enableWebSearch &&
        _settings.webSearchProvider == webSearchProviderBaizhi &&
        parentMessage.content.trim().isNotEmpty) {
      assistant
        ..searching = true
        ..searchHint = '正在联网搜索…';
      notifyListeners();
      try {
        final String key = await _settings.readBaizhiWebKey();
        final List<SearchSource> results =
            await BaizhiWebSearchService.search(parentMessage.content, key);
        if (results.isNotEmpty) {
          assistant.sources = results;
          webContext = BaizhiWebSearchService.buildContext(results);
        }
      } catch (error) {
        assistant.searchHint = '联网搜索失败，改为普通回答';
      }
      assistant.searching = false;
      notifyListeners();
    }
    final List<CitationRange> citations = <CitationRange>[];
    final Map<int, String> toolNames = <int, String>{};
    final Map<int, StringBuffer> toolArgs = <int, StringBuffer>{};
    final int thinkingStart = DateTime.now().millisecondsSinceEpoch;
    int thinkingEnd = 0;
    bool finished = false;
    // 会话标题：每个会话只请求一次；标题仍是自动取名时才请求（用户重命名过就不覆盖）。
    // Business Rule: 服务端不保证给标题（拒答/出错时没有），故本地兜底标题必须先写。
    final bool titleEnabled = !session.autoTitled &&
        _settings.featureTitle &&
        _isAutoTitle(session);

    void complete({required bool stopped}) {
      if (finished) {
        return;
      }
      finished = true;
      if (token != _generation) {
        return;
      }
      _stopTicker();
      _subscription = null;
      if (titleEnabled) {
        session.autoTitled = true;
      }
      if (assistant.content.isEmpty && assistant.status == MessageStatus.streaming) {
        assistant.status = MessageStatus.success;
      } else if (assistant.status == MessageStatus.streaming) {
        assistant.status = MessageStatus.success;
      }
      if ((assistant.reasoningContent ?? '').isNotEmpty) {
        if (assistant.thinkingDuration == null) {
          final int end = thinkingEnd > 0 ? thinkingEnd : DateTime.now().millisecondsSinceEpoch;
          assistant.thinkingDuration =
              ((end - thinkingStart) / 1000).round().clamp(1, 1 << 30).toInt();
        }
        if (_settings.autoCollapseThinking) {
          _collapsedReasons.add(assistant.id);
        }
      }
      assistant.searching = false;
      assistant.searchHint = null;
      if (citations.isNotEmpty &&
          assistant.content.isNotEmpty &&
          // 正文自带 [citation:N] 标记时由渲染层就地替换，不能再按偏移补一遍，
          // 否则同一处会出现两个角标（官方客户端也只保留标记这一种）。
          !hasCitationTokens(assistant.content)) {
        assistant.content = injectCitationMarkers(
          assistant.content,
          citations,
          assistant.sources,
        );
      }      _isGenerating = false;
      unawaited(_saveState());
      notifyListeners();
      if (!stopped) {
      }
    }

    void fail(Object error) {
      if (finished) {
        return;
      }
      finished = true;
      if (token != _generation) {
        return;
      }
      _stopTicker();
      _subscription = null;
      assistant
        ..status = MessageStatus.error
        ..errorMessage = error is ChatException ? error.message : '$error';
      _isGenerating = false;
      unawaited(_saveState());
      notifyListeners();
    }

    final Stream<ChatStreamEvent> stream = ChatService.streamChat(
      ChatRequestOptions(
        providerId: _currentProviderId,
        apiKey: _currentApiKey,
        model: _currentModelId,
        temperature: speaker.temperature,
        messages: history,
        systemPrompt: _systemPromptFor(session, speaker) +
            (webContext.isEmpty ? '' : '\n\n$webContext'),
        enableThinking: _enableThinking,
        reasoningEffort: 'high',

        enableFiles: _settings.featureFiles,
        enableImageTool: _settings.featureImage &&
            _currentProviderId == 'deepseek',
        enableWebSearch: _enableWebSearch &&
            _settings.webSearchProvider != webSearchProviderBaizhi,
        enableSafety: _settings.featureSafety,
        enableTitle: titleEnabled,
        // 阅读链接：让服务端抓取用户消息里的 URL（与联网搜索独立，是否读由模型判断）。
        enableReadUrl: _settings.featureReadUrl,
        // 用户元信息：日期/语言/所在地（latest_reminder 仅 DeepSeek 支持）。
        reminder: _currentProviderId == 'deepseek'
            ? ChatReminder(
                location: _settings.userLocation,
                language: _settings.language,
              )
            : null,
      ),
    );

    _subscription = stream.listen(
      (ChatStreamEvent event) {
        if (token != _generation) {
          return;
        }
        // 生成中失败：保留已收到的正文，但状态必须是 error，不能落成成功。
        if (event.error.isNotEmpty) {
          fail(ChatException(event.error));
          return;
        }
        if (event.done) {
          complete(stopped: false);
          if (toolNames.containsValue('generate_image')) {
            final int key = toolNames.entries
                .firstWhere((MapEntry<int, String> e) => e.value == 'generate_image')
                .key;
            final StringBuffer? args = toolArgs[key];
            if (args != null) {
              unawaited(_runImageTool(assistant, args.toString()));
            }
          }
          return;
        }
        if (event.toolCallIndex >= 0) {
          if (event.toolCallName.isNotEmpty) {
            toolNames[event.toolCallIndex] = event.toolCallName;
          }
          if (event.toolCallArgs.isNotEmpty) {
            toolArgs
                .putIfAbsent(event.toolCallIndex, () => StringBuffer())
                .write(event.toolCallArgs);
          }
        }
        if (event.searchHint.isNotEmpty) {
          assistant.searchHint = event.searchHint;
          assistant.searching = event.searchHint.contains('正在');
        }
        if (event.sources.isNotEmpty) {
          for (final SearchSource source in event.sources) {
            if (assistant.sources.length >= 24) {
              break;
            }
            if (!assistant.sources.any((SearchSource s) => s.url == source.url)) {
              assistant.sources.add(source);
            }
          }
        }
        // 官方 finish_reason=length：正文被截断（搜索/读链接后上下文用尽也会走到这里）。
        if (event.truncated) {
          assistant.truncated = true;
        }
        // 阅读链接：末块原文（含 signature）随消息持久化，下一轮原样回传。
        if (event.serverToolCallsJson.isNotEmpty) {
          assistant.serverToolCallsJson = event.serverToolCallsJson;
        }
        if (event.citations.isNotEmpty) {
          citations.addAll(event.citations);
        }
        if (event.title.isNotEmpty &&
            titleEnabled &&
            _isAutoTitle(session)) {
          session.title = event.title;
        }
        if (event.refusal.isNotEmpty) {
          // 官方要求：拒答时删除已展示的回答（含思考），改为拒答文案；
          // server_tool_calls 保留（阅读链接的 signature 下一轮仍可用）。
          assistant
            ..content = ''
            ..reasoningContent = null
            ..status = MessageStatus.error
            ..errorMessage = safetyNotice(event.refusal);
          assistant.searching = false;
          notifyListeners();
          return;
        }
        if (event.reasoning.isNotEmpty) {
          assistant.reasoningContent =
              (assistant.reasoningContent ?? '') + event.reasoning;
          _collapsedReasons.remove(assistant.id);
        }
        if (event.content.isNotEmpty) {
          if (thinkingEnd == 0 &&
              (assistant.reasoningContent ?? '').isNotEmpty) {
            thinkingEnd = DateTime.now().millisecondsSinceEpoch;
            assistant.thinkingDuration =
                ((thinkingEnd - thinkingStart) / 1000).round().clamp(1, 1 << 30).toInt();
            if (_settings.autoCollapseThinking) {
              _collapsedReasons.add(assistant.id);
            }
          }
          assistant.content += event.content;
        }
      },
      onError: fail,
      onDone: () => complete(stopped: false),
      cancelOnError: true,
    );
  }

  void stopGenerating() {
    if (!_isGenerating) {
      return;
    }
    _generation++;
    final StreamSubscription<ChatStreamEvent>? sub = _subscription;
    _subscription = null;
    unawaited(sub?.cancel());
    _stopTicker();
    _isGenerating = false;
    final List<ChatMessage> path = activePath;
    if (path.isNotEmpty) {
      final ChatMessage last = path.last;
      if (last.status == MessageStatus.streaming) {
        last.status = MessageStatus.success;
        if ((last.reasoningContent ?? '').isNotEmpty &&
            last.thinkingDuration == null) {
          last.thinkingDuration = 1;
        }
        final ChatSession? session = currentSession;
        if (session != null) {
          final ChatMessage? parent = findMessage(session, last.parentId);
          if (parent != null) {
          }
        }
      }
    }
    unawaited(_saveState());
    notifyListeners();
  }

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(milliseconds: 120), (_) {
      if (_isGenerating) {
        notifyListeners();
      }
    });
  }

  void _stopTicker() {
    _ticker?.cancel();
    _ticker = null;
  }

  String _systemPromptFor(ChatSession session, CharacterCard speaker) {
    final String base = speaker.systemPrompt.trim();
    String persona = '';
    if (session.userIdentityId.isNotEmpty) {
      final UserIdentityCard? identity = identityById(session.userIdentityId);
      if (identity != null) {
        persona = identity.persona.trim().isEmpty
            ? '【与你对话的用户在剧中身份】：「${identity.name}」'
            : '【与你对话的用户在剧中身份】：「${identity.name}」—— ${identity.persona.trim()}';
      }
    }
    if (persona.isEmpty) {
      return base;
    }
    return base.isEmpty ? persona : '$base\n\n$persona';
  }

  String _currentIdentityName(ChatSession session) {
    if (session.userIdentityId.isEmpty) {
      return '';
    }
    return identityById(session.userIdentityId)?.name ?? '';
  }

  // ── Message actions ──

  bool isReasonCollapsed(String id) => _collapsedReasons.contains(id);

  void toggleReason(String id) {
    if (_collapsedReasons.contains(id)) {
      _collapsedReasons.remove(id);
    } else {
      _collapsedReasons.add(id);
    }
    notifyListeners();
  }

  bool isThinkingStreaming(ChatMessage message) =>
      message.status == MessageStatus.streaming && message.content.isEmpty;

  String reasonTitle(ChatMessage message) {
    if (isThinkingStreaming(message)) {
      return '正在思考...';
    }
    final int seconds = (message.thinkingDuration ?? 0) > 0
        ? message.thinkingDuration!
        : 1;
    return '已思考（用时 $seconds 秒）';
  }

  Future<void> regenerate(String assistantId) async {
    final ChatSession? session = currentSession;
    if (session == null || _isGenerating) {
      return;
    }
    final ChatMessage? assistant = findMessage(session, assistantId);
    if (assistant == null || !assistant.isAssistant) {
      return;
    }
    final ChatMessage? user = findMessage(session, assistant.parentId);
    if (user == null || !_canSend()) {
      return;
    }
    CharacterCard speaker = currentCharacter;
    final CharacterCard? bySpeaker = characterById(assistant.speakerId);
    if (bySpeaker != null) {
      speaker = bySpeaker;
    }
    generateReply(session, user, speaker);
  }

  Future<void> editAndResend(String userId, String newText) async {
    final ChatSession? session = currentSession;
    final String trimmed = newText.trim();
    if (session == null || _isGenerating || trimmed.isEmpty || !_canSend()) {
      return;
    }
    final ChatMessage? original = findMessage(session, userId);
    if (original == null || !original.isUser) {
      return;
    }
    final ChatMessage replacement =
        buildMessage(MessageRole.user, trimmed, original.parentId);
    replacement.mentionedIds = List<String>.from(original.mentionedIds);
    attach(session, replacement);
    session.updatedAt = DateTime.now().millisecondsSinceEpoch;
    notifyListeners();
    generateReply(session, replacement, currentCharacter);
  }

  Future<void> switchBranch(String messageId, int delta) async {
    if (_isGenerating) {
      return;
    }
    final ChatSession? session = currentSession;
    if (session == null) {
      return;
    }
    final ChatMessage? message = findMessage(session, messageId);
    if (message == null) {
      return;
    }
    final List<String> siblings = siblingsOf(session, message);
    if (siblings.length <= 1) {
      return;
    }
    int index = siblingIndex(session, message) + delta;
    if (index < 0 || index >= siblings.length) {
      return;
    }
    final String target = siblings[index];
    if (message.parentId.isEmpty) {
      session.activeRootId = target;
    } else {
      final ChatMessage? parent = findMessage(session, message.parentId);
      if (parent == null) {
        return;
      }
      parent.activeChildId = target;
    }
    session.updatedAt = DateTime.now().millisecondsSinceEpoch;
    await _saveState();
    notifyListeners();
  }

  void _initCollapsedReasons() {
    _collapsedReasons.clear();
    final ChatSession? session = currentSession;
    if (session == null) {
      return;
    }
    for (final ChatMessage m in session.messages) {
      if ((m.reasoningContent ?? '').isNotEmpty) {
        _collapsedReasons.add(m.id);
      }
    }
  }

  Future<void> _saveState() async {
    await _storage.saveSessions(_sessions);
    await _storage.saveActiveSessionId(
      _draft != null ? '' : _currentSessionId,
    );
  }

  @override
  void dispose() {
    _stopTicker();
    _subscription?.cancel();
    super.dispose();
  }

  /// 上传附件：仅 DeepSeek 支持 Files API；成功后进入待发送列表。
  Future<bool> uploadPendingAttachment({
    required String fileName,
    required Uint8List bytes,
  }) async {
    if (!_settings.featureFiles) {
      _noticeText = '文件与图片解析已在设置 > 工具中关闭';
      notifyListeners();
      return false;
    }
    if (_currentProviderId != 'deepseek') {
      _noticeText = '文件解析仅支持 DeepSeek 服务商';
      notifyListeners();
      return false;
    }
    if (_attachmentBusy) {
      return false;
    }
    _attachmentBusy = true;
    notifyListeners();
    try {
      final MessageAttachment attachment = await FileUploadService.upload(
        apiKey: _currentApiKey,
        fileName: fileName,
        bytes: bytes,
      );
      _pendingAttachments.add(attachment);
      _noticeText = '';
      return true;
    } on FileUploadException catch (error) {
      _noticeText = error.message;
      return false;
    } catch (error) {
      _noticeText = '上传失败：$error';
      return false;
    } finally {
      _attachmentBusy = false;
      notifyListeners();
    }
  }

  void removePendingAttachment(String fileId) {
    _pendingAttachments.removeWhere((MessageAttachment a) => a.fileId == fileId);
    notifyListeners();
  }

  /// 执行生图工具：建任务 → 轮询 → 结果挂到消息（URL 有时效）。
  Future<void> _runImageTool(ChatMessage assistant, String argsJson) async {
    String prompt = '';
    String ratio = 'auto';
    int count = 1;
    try {
      final Object? decoded = jsonDecode(argsJson);
      if (decoded is Map) {
        final Object? p = decoded['prompt'];
        if (p is String) {
          prompt = p;
        }
        final Object? r = decoded['ratio'];
        if (r is String) {
          ratio = r;
        }
        final Object? c = decoded['count'];
        if (c is num) {
          count = c.toInt().clamp(1, 4);
        }
      }
    } catch (_) {
      // 参数不是合法 JSON 时按空提示词处理，下面会直接失败提示。
    }
    if (prompt.trim().isEmpty) {
      assistant
        ..imageState = 'failed'
        ..imageHint = '生图参数缺少提示词';
      notifyListeners();
      return;
    }
    assistant
      ..imagePrompt = prompt
      ..imageAspect = _aspectOfRatio(ratio)
      ..imageState = 'generating'
      ..imageHint = '正在生成图片…';
    notifyListeners();
    try {
      final String key = await _settings.readBaizhiImageKey();
      // Same contract as HarmonyOS: the tool is always declared, a missing key
      // is reported here instead of silently hiding the tool.
      if (key.trim().isEmpty) {
        throw const ImageGenException('未配置百智云「生图」Key（设置 > 工具）');
      }
      final String taskId = await ImageGenService.createTask(
        prompt: prompt,
        ratio: ratio,
        resolution: '2K',
        count: count,
        apiKey: key,
      );
      final DateTime deadline = DateTime.now().add(
        const Duration(milliseconds: ImageGenService.taskTimeoutMs),
      );
      List<String> urls = const <String>[];
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(
          const Duration(milliseconds: ImageGenService.pollIntervalMs),
        );
        final ImageTaskStatus status =
            await ImageGenService.queryTask(taskId, key);
        if (status.imageUrls.isNotEmpty) {
          urls = status.imageUrls;
          break;
        }
        if (status.isFailed) {
          throw ImageGenException(
            status.message.isEmpty ? '生图任务失败' : status.message,
          );
        }
      }
      if (urls.isEmpty) {
        throw const ImageGenException('生图超时（约 6 分钟），请稍后重试');
      }
      assistant
        ..imageUrls = urls.take(4).toList(growable: false)
        ..imageState = 'done'
        ..imageHint = null
        ..imageMeta = '百智云 | $ratio | 2K';
    } on ImageGenException catch (error) {
      assistant
        ..imageState = 'failed'
        ..imageHint = error.message;
    } catch (error) {
      assistant
        ..imageState = 'failed'
        ..imageHint = '生图失败：$error';
    }
    unawaited(_saveState());
    notifyListeners();
  }

  static double _aspectOfRatio(String ratio) {
    switch (ratio) {
      case '4:3':
        return 4 / 3;
      case '3:4':
        return 3 / 4;
      case '16:9':
        return 16 / 9;
      case '9:16':
        return 9 / 16;
      default:
        return 1;
    }
  }
}

/// 回放用的消息副本：只给用户正文拼身份名前缀，其余可回放字段原样带过去。
/// Business Rule: 附件（file_id）由 buildApiMessages 读取，投影时漏拷字段会让多轮能力
/// 在第二轮悄悄失效（实测表现为「上一轮读过文档、下一轮就失忆」）。
ChatMessage replayMessage(ChatMessage message, String identityName) {
  final bool prefix = message.isUser &&
      identityName.isNotEmpty &&
      message.content.isNotEmpty;
  return ChatMessage(
    id: message.id,
    role: message.role,
    content: prefix ? '$identityName：${message.content}' : message.content,
    createdAt: message.createdAt,
    status: message.status,
    parentId: message.parentId,
    reasoningContent: message.reasoningContent,
    attachments: message.attachments,
    serverToolCallsJson: message.serverToolCallsJson,
  );
}

/// 本地兜底会话标题：取用户首条消息的前 14 个字符。
/// Business Rule: 服务端标题（title.enabled）只在首轮请求、且可能不下发，
/// 所以发送时就先落一个本地标题，服务端标题到达后按「是否自动取名」决定是否替换。
String autoTitleFor(String text) {
  final String trimmed = text.trim();
  return trimmed.length > 14 ? '${trimmed.substring(0, 14)}...' : trimmed;
}

/// 在正文引用区间的末尾插入 [N](#cite-N) 标记。
///
/// Business Rule: 偏移以 Unicode 码点计（与 DeepSeek annotations 一致），
/// 越界或找不到来源的区间直接跳过，不影响正文。
String injectCitationMarkers(
  String content,
  List<CitationRange> citations,
  List<SearchSource> sources,
) {
  if (content.isEmpty || citations.isEmpty) {
    return content;
  }
  final Map<int, List<int>> atEnd = <int, List<int>>{};
  for (final CitationRange cite in citations) {
    final int number =
        sources.indexWhere((SearchSource s) => s.url == cite.url) + 1;
    if (number <= 0 || cite.end < 0) {
      continue;
    }
    final List<int> numbers = atEnd.putIfAbsent(cite.end, () => <int>[]);
    if (!numbers.contains(number)) {
      numbers.add(number);
    }
  }
  if (atEnd.isEmpty) {
    return content;
  }
  final StringBuffer out = StringBuffer();
  int index = 0;
  for (final int rune in content.runes) {
    out.writeCharCode(rune);
    index++;
    final List<int>? numbers = atEnd[index];
    if (numbers == null) {
      continue;
    }
    numbers.sort();
    for (final int number in numbers) {
      final String marker = number.toString();
      out.write('[$marker](#cite-$marker)');
    }
  }
  return out.toString();
}
