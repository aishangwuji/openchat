import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models/chat_models.dart';

/// DeepSeek Files API 上传（文档 / 图片）。
///
/// 约束（与鸿蒙端一致）：
/// 1. `purpose` 按扩展名选择：纯文本/表格/电子书与图片走 `user_data`（不计费），
///    PDF/Office/BMP/TIFF 走服务端解析（text_recognition / rich_layout_recognition）；
/// 2. 文档最大 100 MiB，`user_data` 原文件 32 MiB；
/// 3. 服务端按内容判格式，Content-Type 统一 octet-stream。
class FileUploadService {
  const FileUploadService._();

  static const String _endpoint = 'https://api.deepseek.com/files';
  static const int _maxDocBytes = 100 * 1024 * 1024;
  static const int _maxUserDataBytes = 32 * 1024 * 1024;
  /// 官方图片通过 Files API 引用时单张上限 64 MiB（纯文本/表格仍是 32 MiB）。
  static const int _maxImageBytes = 64 * 1024 * 1024;
  static const Duration _timeout = Duration(minutes: 5);

  static const List<String> _userDataExts = <String>[
    'txt', 'md', 'markdown', 'csv', 'json', 'log', 'xml', 'yaml', 'yml', 'html',
    'css', 'js', 'ts', 'jsx', 'tsx', 'py', 'java', 'kt', 'c', 'cpp', 'h', 'hpp',
    'go', 'rs', 'rb', 'php', 'swift', 'sh', 'sql', 'ini', 'toml', 'xlsx', 'xls',
    'epub', 'mobi',
  ];

  /// 图片必须走 user_data 原文存储，模型才能“看见”画面（OCR 模式只出文字）。
  static const List<String> _visionExts = <String>[
    'png', 'jpg', 'jpeg', 'webp', 'gif',
  ];

  static const List<String> _richLayoutExts = <String>['pdf', 'doc', 'docx'];

  static const List<String> _textRecognitionExts = <String>[
    'ppt', 'pptx', 'bmp', 'tiff', 'tif',
  ];

  static String extensionOf(String fileName) {
    final int dot = fileName.lastIndexOf('.');
    if (dot < 0 || dot == fileName.length - 1) {
      return '';
    }
    return fileName.substring(dot + 1).toLowerCase();
  }

  /// 扩展名 → purpose；不支持的格式返回空串（调用方提示用户）。
  static String purposeFor(String fileName) {
    final String ext = extensionOf(fileName);
    if (_userDataExts.contains(ext) || _visionExts.contains(ext)) {
      return 'user_data';
    }
    if (_richLayoutExts.contains(ext)) {
      return 'rich_layout_recognition';
    }
    if (_textRecognitionExts.contains(ext)) {
      return 'text_recognition';
    }
    return '';
  }

  static bool isImage(String fileName) =>
      _visionExts.contains(extensionOf(fileName));

  /// 单文件大小上限：图片 64 MiB，需解析文档 100 MiB，纯文本/表格 32 MiB。
  static int maxBytesFor(String fileName) {
    if (isImage(fileName)) {
      return _maxImageBytes;
    }
    return purposeFor(fileName) == 'user_data'
        ? _maxUserDataBytes
        : _maxDocBytes;
  }

  /// 上传单个文件；失败抛 [FileUploadException]。
  static Future<MessageAttachment> upload({
    required String apiKey,
    required String fileName,
    required Uint8List bytes,
  }) async {
    final String key = apiKey.trim();
    if (key.isEmpty) {
      throw const FileUploadException('未配置 API Key');
    }
    final String purpose = purposeFor(fileName);
    if (purpose.isEmpty) {
      throw FileUploadException('不支持的文件格式：$fileName');
    }
    final int limit = maxBytesFor(fileName);
    if (bytes.length > limit) {
      throw FileUploadException(
        '文件超过 ${limit ~/ (1024 * 1024)} MiB 上限：$fileName',
      );
    }
    try {
      final http.MultipartRequest req =
          http.MultipartRequest('POST', Uri.parse(_endpoint))
            ..headers['Authorization'] = 'Bearer $key'
            ..fields['purpose'] = purpose
            ..files.add(
              http.MultipartFile.fromBytes(
                'file',
                bytes,
                filename: fileName,
              ),
            );
      final http.StreamedResponse streamed =
          await req.send().timeout(_timeout);
      final String body = await streamed.stream.bytesToString();
      if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
        throw FileUploadException(
          '上传失败（HTTP ${streamed.statusCode}）：${_truncate(body)}',
        );
      }
      final Object? decoded = jsonDecode(body);
      if (decoded is! Map) {
        throw const FileUploadException('上传返回格式异常');
      }
      final Object? id = decoded['id'];
      if (id is! String || id.isEmpty) {
        throw const FileUploadException('上传返回缺少 file_id');
      }
      return MessageAttachment(
        fileId: id,
        fileName: fileName,
        purpose: purpose,
        bytes: bytes.length,
      );
    } on FileUploadException {
      rethrow;
    } catch (error) {
      throw FileUploadException('上传失败：$error');
    }
  }

  static String _truncate(String text) =>
      text.length <= 300 ? text : '${text.substring(0, 300)}…';
}

class FileUploadException implements Exception {
  const FileUploadException(this.message);

  final String message;

  @override
  String toString() => message;
}
