import 'dart:convert';

import 'package:balance_app/data/models/chat_models.dart';
import 'package:balance_app/data/services/chat_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 官方《模型内容安全》：输入命中审核返回 400 `Content Exists Risk`；
/// 输出命中审核以 `finish_reason=content_filter` / `delta.refusal` 结束。
/// 两端都必须给出可见提示，不能静默变成空回答。
ChatRequestOptions _options() => const ChatRequestOptions(
      providerId: 'deepseek',
      apiKey: 'test-key',
      model: 'deepseek-flash',
      messages: <ChatMessage>[],
      enableSafety: true,
    );

void main() {
  test('safetyNotice 给通用提示，并保留图片拦截说明', () {
    expect(safetyNotice(''), contains('本次对话未通过内容安全审核'));
    expect(safetyNotice('内容未通过安全审核'), safetyNotice(''));

    final String detail =
        'The following images were blocked by content moderation: messages.1.content.0';
    final String notice = safetyNotice(detail);
    expect(notice, contains('本次对话未通过内容安全审核'));
    expect(notice, contains(detail));
  });

  test('输入命中审核（400 Content Exists Risk）给出安全提示', () async {
    final MockClient client = MockClient((http.Request request) async {
      return http.Response.bytes(
        utf8.encode(
          '{"error":{"message":"Content Exists Risk","type":"invalid_request_error"}}',
        ),
        400,
        headers: <String, String>{'content-type': 'application/json'},
      );
    });

    await expectLater(
      ChatService.streamChat(_options(), clientFactory: () => client).toList(),
      throwsA(
        isA<ChatException>().having(
          (ChatException e) => e.message,
          'message',
          '本次对话未通过内容安全审核，请调整内容后重试',
        ),
      ),
    );
  });

  test('流式末块的 delta.refusal 被解析为拒答原因', () async {
    final String body = 'data: ${jsonEncode(<String, Object?>{
          'choices': <Object?>[
            <String, Object?>{
              'delta': <String, Object?>{
                'refusal':
                    'The following images were blocked by content moderation: messages.1.content.0',
              },
              'finish_reason': 'content_filter',
            },
          ],
        })}\n\ndata: [DONE]\n\n';
    final MockClient client = MockClient((http.Request request) async {
      return http.Response.bytes(
        utf8.encode(body),
        200,
        headers: <String, String>{'content-type': 'text/event-stream'},
      );
    });

    final List<ChatStreamEvent> events =
        await ChatService.streamChat(_options(), clientFactory: () => client)
            .toList();

    expect(
      events.any(
        (ChatStreamEvent e) => e.refusal.contains('images were blocked'),
      ),
      isTrue,
    );
    expect(
      events.any((ChatStreamEvent e) => e.refusal == '内容未通过安全审核'),
      isFalse,
    );
  });
}
