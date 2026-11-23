import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/chat_models.dart';
import 'preferences_service.dart';

/// Persists characters, identities and session trees as JSON.
///
/// Boundary contract: persisted JSON is untrusted. Every load goes through
/// defensive normalization; malformed records are dropped instead of crashing.
class ChatStorageService {
  ChatStorageService(this._prefs);

  final PreferencesService _prefs;

  static const List<CharacterCard> defaultCharacters = <CharacterCard>[];

  Future<List<CharacterCard>> loadCharacters() async {
    final List<CharacterCard> out = <CharacterCard>[];
    for (final Object? raw in _decodeList(_prefs.getString(
      PreferencesService.storeCharacters,
    ))) {
      final CharacterCard? card = CharacterCard.tryParse(raw);
      if (card != null) {
        out.add(card);
      }
    }
    return out;
  }

  Future<void> saveCharacters(List<CharacterCard> cards) async {
    await _prefs.setString(
      PreferencesService.storeCharacters,
      jsonEncode(cards.map((CharacterCard c) => c.toJson()).toList(growable: false)),
    );
  }

  Future<List<UserIdentityCard>> loadIdentities() async {
    final List<UserIdentityCard> out = <UserIdentityCard>[];
    for (final Object? raw in _decodeList(_prefs.getString(
      PreferencesService.storeIdentities,
    ))) {
      final UserIdentityCard? card = UserIdentityCard.tryParse(raw);
      if (card != null) {
        out.add(card);
      }
    }
    return out;
  }

  Future<void> saveIdentities(List<UserIdentityCard> cards) async {
    await _prefs.setString(
      PreferencesService.storeIdentities,
      jsonEncode(cards.map((UserIdentityCard c) => c.toJson()).toList(growable: false)),
    );
  }

  Future<List<ChatSession>> loadSessions() async {
    final List<ChatSession> out = <ChatSession>[];
    for (final Object? raw in _decodeList(_prefs.getString(
      PreferencesService.storeSessions,
    ))) {
      final ChatSession? session = _normalizeSession(raw);
      if (session != null) {
        out.add(session);
      }
    }
    return out;
  }

  Future<void> saveSessions(List<ChatSession> sessions) async {
    try {
      await _prefs.setString(
        PreferencesService.storeSessions,
        jsonEncode(sessions.map((ChatSession s) => s.toJson()).toList(growable: false)),
      );
    } catch (error) {
      debugPrint('ChatStorageService: save sessions failed: $error');
    }
  }

  Future<String> loadActiveSessionId() async =>
      _prefs.getString(PreferencesService.keyActiveSessionId);

  Future<void> saveActiveSessionId(String sessionId) async {
    await _prefs.setString(PreferencesService.keyActiveSessionId, sessionId);
  }

  List<Object?> _decodeList(String raw) {
    if (raw.isEmpty) {
      return const <Object?>[];
    }
    try {
      final Object? parsed = jsonDecode(raw);
      if (parsed is List) {
        return parsed;
      }
    } catch (error) {
      debugPrint('ChatStorageService: decode failed: $error');
    }
    return const <Object?>[];
  }

  ChatSession? _normalizeSession(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final Object? id = raw['id'];
    if (id is! String || id.isEmpty) {
      return null;
    }

    final List<ChatMessage> pool = <ChatMessage>[];
    final Object? messagesRaw = raw['messages'];
    if (messagesRaw is List) {
      for (final Object? m in messagesRaw) {
        final ChatMessage? message = ChatMessage.tryParse(m);
        if (message != null) {
          pool.add(message);
        }
      }
    }

    List<String> rootIds = <String>[];
    String activeRootId = '';
    final Object? rootsRaw = raw['rootIds'];
    final bool hasTree = rootsRaw is List && raw['activeRootId'] is String;
    if (hasTree) {
      for (final Object? r in rootsRaw) {
        if (r is String && _messageExists(pool, r)) {
          rootIds.add(r);
        }
      }
      activeRootId = raw['activeRootId'] as String;
    } else {
      rootIds = _migrateLinear(pool);
      activeRootId = rootIds.isEmpty ? '' : rootIds.first;
    }
    _repairRefs(pool, rootIds);
    if (!rootIds.contains(activeRootId)) {
      activeRootId = rootIds.isEmpty ? '' : rootIds.first;
    }

    final List<String> participantIds = <String>[];
    final Object? partsRaw = raw['participantIds'];
    if (partsRaw is List) {
      for (final Object? p in partsRaw) {
        if (p is String && p.isNotEmpty) {
          participantIds.add(p);
        }
      }
    }
    SceneMode sceneMode = SceneMode.single;
    if (raw['sceneMode'] == 'group' && participantIds.length >= 2) {
      sceneMode = SceneMode.group;
    }

    final Map<String, String> joinMap = <String, String>{};
    final Object? joinRaw = raw['joinMap'];
    if (joinRaw is Map) {
      joinRaw.forEach((Object? k, Object? v) {
        if (k is String && v is String) {
          joinMap[k] = v;
        }
      });
    }

    return ChatSession(
      id: id,
      title: raw['title'] is String ? raw['title'] as String : '对话',
      characterId: raw['characterId'] is String ? raw['characterId'] as String : '',
      providerId: raw['providerId'] is String ? raw['providerId'] as String : 'deepseek',
      modelId: raw['modelId'] is String ? raw['modelId'] as String : '',
      updatedAt: raw['updatedAt'] is num
          ? (raw['updatedAt'] as num).toInt()
          : DateTime.now().millisecondsSinceEpoch,
      messages: pool,
      rootIds: rootIds,
      activeRootId: activeRootId,
      participantIds: participantIds,
      sceneMode: sceneMode,
      joinMap: joinMap,
      userIdentityId:
          raw['userIdentityId'] is String ? raw['userIdentityId'] as String : '',
      isPrivate: raw['isPrivate'] == true,
      autoTitled: raw['autoTitled'] == true,
    );
  }

  bool _messageExists(List<ChatMessage> pool, String id) {
    for (final ChatMessage m in pool) {
      if (m.id == id) {
        return true;
      }
    }
    return false;
  }

  /// Old versions stored a linear message array; migrate to a single chain.
  List<String> _migrateLinear(List<ChatMessage> pool) {
    if (pool.isEmpty) {
      return <String>[];
    }
    for (int i = 0; i < pool.length; i++) {
      final ChatMessage cur = pool[i];
      cur.childIds = <String>[];
      cur.activeChildId = '';
      cur.parentId = i > 0 ? pool[i - 1].id : '';
      if (i > 0) {
        final ChatMessage prev = pool[i - 1];
        prev.childIds = <String>[cur.id];
        prev.activeChildId = cur.id;
      }
    }
    return <String>[pool.first.id];
  }

  void _repairRefs(List<ChatMessage> pool, List<String> roots) {
    for (final ChatMessage msg in pool) {
      final List<String> kept = msg.childIds
          .where((String id) => _messageExists(pool, id))
          .toList(growable: false);
      msg.childIds = List<String>.from(kept);
      if (kept.isEmpty) {
        msg.activeChildId = '';
      } else if (!kept.contains(msg.activeChildId)) {
        msg.activeChildId = kept.first;
      }
    }
    final List<String> seen = <String>[];
    for (final String r in roots) {
      if (!seen.contains(r)) {
        seen.add(r);
      }
    }
    roots
      ..clear()
      ..addAll(seen);
  }
}
