import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// DeepSeek 语音识别（POST /v1/tools/asr）。
///
/// 约束（与鸿蒙端一致）：16 位 PCM WAV 或 Ogg Opus，≤ 8 MiB、≤ 120 秒；
/// multipart 只带一个 file 字段，语种由服务端自动识别。
class AsrService {
  const AsrService._();

  static const String _endpoint = 'https://api.deepseek.com/v1/tools/asr';
  static const int _maxBytes = 8 * 1024 * 1024;
  /// 官方单次识别时长上限：120 秒。UI 到点自动停录，避免录满 3 分钟才 400。
  static const int maxDurationSeconds = 120;
  static const Duration _timeout = Duration(seconds: 180);

  /// 转写一段 WAV；返回文本（可能为空），失败抛 [AsrException]。
  static Future<String> transcribe({
    required String apiKey,
    required Uint8List wavBytes,
  }) async {
    final String key = apiKey.trim();
    if (key.isEmpty) {
      throw const AsrException('未配置 DeepSeek API Key');
    }
    if (wavBytes.length <= 44) {
      throw const AsrException('没有录到声音');
    }
    if (wavBytes.length > _maxBytes) {
      throw const AsrException('录音超过 8MB，请缩短时长');
    }
    try {
      final http.MultipartRequest req =
          http.MultipartRequest('POST', Uri.parse(_endpoint))
            ..headers['Authorization'] = 'Bearer $key'
            ..headers['Accept'] = 'application/json'
            ..files.add(
              http.MultipartFile.fromBytes(
                'file',
                wavBytes,
                filename: 'speech.wav',
                contentType: _wavContentType(),
              ),
            );
      final http.StreamedResponse streamed = await req.send().timeout(_timeout);
      final String body = await streamed.stream.bytesToString();
      if (streamed.statusCode != 200) {
        throw AsrException(_errorText(streamed.statusCode, body));
      }
      final Object? decoded = jsonDecode(body);
      if (decoded is! Map) {
        throw const AsrException('识别结果格式异常');
      }
      final Object? text = decoded['text'];
      if (text is! String) {
        throw const AsrException('识别结果缺少文本');
      }
      return text.trim();
    } on AsrException {
      rethrow;
    } catch (error) {
      throw AsrException('语音识别失败：$error');
    }
  }

  static String _errorText(int code, String body) {
    switch (code) {
      case 401:
        return '语音识别鉴权失败，请检查 API Key';
      case 413:
        return '录音过大，请缩短时长';
      default:
        final String trimmed =
            body.length <= 200 ? body : '${body.substring(0, 200)}…';
        return '语音识别失败（HTTP $code）：$trimmed';
    }
  }
}

/// 独立的内容类型常量，避免在请求体里临时构造。
http.MediaType _wavContentType() => http.MediaType('audio', 'wav');

class AsrException implements Exception {
  const AsrException(this.message);

  final String message;

  @override
  String toString() => message;
}
