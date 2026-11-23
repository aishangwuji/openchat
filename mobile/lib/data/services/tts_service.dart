import 'dart:convert';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// DeepSeek 语音合成（POST /v1/tools/tts）与本地缓存播放。
///
/// 1. 合成：Bearer 鉴权、JSON 体 `{text, voice_id, format:'wav'}`，响应为音频二进制；
/// 2. 缓存：按 `voice|text` 的 FNV-1a 哈希落盘到临时目录，重复朗读不再请求；
/// 3. 文本过长会截断（服务端单次上限之外的部分朗读无意义）。
class TtsService {
  const TtsService._();

  static const String _endpoint = 'https://api.deepseek.com/v1/tools/tts';
  static const int _maxChars = 2000;
  static const Duration _timeout = Duration(seconds: 120);
  static const List<String> voices = <String>['stella', 'tide'];
  static const String defaultVoice = 'stella';

  static final AudioPlayer _player = AudioPlayer();
  static String _playingKey = '';

  /// 当前正在朗读的消息 id（null 表示没有在播）；全局单实例，避免两条消息同时显示「停止」。
  static final ValueNotifier<String?> playingOwner = ValueNotifier<String?>(null);

  /// 当前正在朗读的缓存 key（空串表示未播放）。
  static String get playingKey => _playingKey;

  /// 合成并播放；返回实际的缓存 key（供 UI 标记）。
  static Future<String> speak({
    required String text,
    required String apiKey,
    String voiceId = defaultVoice,
    String? ownerId,
  }) async {
    final String key = apiKey.trim();
    if (key.isEmpty) {
      throw const TtsException('未配置 DeepSeek API Key');
    }
    String clipped = text.trim();
    if (clipped.isEmpty) {
      throw const TtsException('没有可朗读的内容');
    }
    if (clipped.length > _maxChars) {
      clipped = clipped.substring(0, _maxChars);
    }
    final String voice = voices.contains(voiceId) ? voiceId : defaultVoice;
    final String cacheKey = _hashKey(voice, clipped);
    final File file = await _cacheFile(cacheKey);
    if (!await file.exists() || await file.length() < 44) {
      final Uint8List bytes = await _synthesize(
        text: clipped,
        apiKey: key,
        voice: voice,
      );
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes, flush: true);
    }
    await _player.stop();
    _playingKey = cacheKey;
    playingOwner.value = ownerId;
    await _player.play(DeviceFileSource(file.path));
    _player.onPlayerComplete.first.then((_) {
      if (_playingKey == cacheKey) {
        _playingKey = '';
        if (playingOwner.value == ownerId) {
          playingOwner.value = null;
        }
      }
    });
    return cacheKey;
  }

  static Future<void> stop() async {
    _playingKey = '';
    playingOwner.value = null;
    await _player.stop();
  }

  static Future<Uint8List> _synthesize({
    required String text,
    required String apiKey,
    required String voice,
  }) async {
    try {
      final http.Response resp = await http
          .post(
            Uri.parse(_endpoint),
            headers: <String, String>{
              'Authorization': 'Bearer $apiKey',
              'Content-Type': 'application/json',
              'Accept': 'audio/wav',
            },
            body: jsonEncode(<String, String>{
              'text': text,
              'voice_id': voice,
              'format': 'wav',
            }),
          )
          .timeout(_timeout);
      if (resp.statusCode != 200) {
        throw TtsException('语音合成失败（HTTP ${resp.statusCode}）');
      }
      if (resp.bodyBytes.length < 44) {
        throw const TtsException('语音合成返回为空');
      }
      return resp.bodyBytes;
    } on TtsException {
      rethrow;
    } catch (error) {
      throw TtsException('语音合成失败：$error');
    }
  }

  static Future<File> _cacheFile(String key) async {
    final Directory dir = await getTemporaryDirectory();
    return File('${dir.path}/tts_cache/$key.wav');
  }

  /// FNV-1a 32 位：确定性、无依赖，够做缓存键。
  static String _hashKey(String voice, String text) {
    final String seed = '$voice|$text';
    int hash = 0x811c9dc5;
    for (final int unit in seed.codeUnits) {
      hash ^= unit & 0xff;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return '${voice}_${text.length}_${hash.toRadixString(16)}';
  }
}

class TtsException implements Exception {
  const TtsException(this.message);

  final String message;

  @override
  String toString() => message;
}
