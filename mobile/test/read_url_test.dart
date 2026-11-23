import 'dart:convert';

import 'package:balance_app/data/models/chat_models.dart';
import 'package:balance_app/data/services/chat_service.dart';
import 'package:flutter_test/flutter_test.dart';

String _callsJson({String signature = 'sig-abc'}) => jsonEncode(<Map<String, dynamic>>[
      <String, dynamic>{
        'index': 0,
        'reasoning_content': '',
        'calls': <Map<String, dynamic>>[
          <String, dynamic>{
            'index': 0,
            'id': 'srvtoolu_rl_00',
            'type': 'deepseek_read_url',
            'kind': 'read_link',
            'action': <String, dynamic>{'type': 'read_link', 'url': 'https://example.com'},
            'status': 'completed',
            'page': <String, dynamic>{
              'url': 'https://example.com',
              'title': 'Example Domain',
              'published_at': null,
            },
            'signature': signature,
          },
        ],
      },
    ]);

void main() {
  test('parseServerToolCalls keeps the signature verbatim', () {
    final List<Map<String, dynamic>>? steps = parseServerToolCalls(_callsJson());
    expect(steps, isNotNull);
    final Map<String, dynamic> call =
        (steps!.single['calls'] as List<Map<String, dynamic>>).single;
    expect(call['signature'], 'sig-abc');
    expect(call['kind'], 'read_link');
  });

  test('parseServerToolCalls rejects malformed or oversized input', () {
    expect(parseServerToolCalls(''), isNull);
    expect(parseServerToolCalls('not json'), isNull);
    expect(parseServerToolCalls('{"calls": []}'), isNull);
    expect(
      parseServerToolCalls(jsonEncode(<Map<String, dynamic>>[
        <String, dynamic>{
          'calls': <Map<String, dynamic>>[
            <String, dynamic>{'kind': 'read_link'}, // 缺 action
          ],
        },
      ])),
      isNull,
    );
  });

  test('buildApiMessages replays server_tool_calls even without answer text', () {
    final ChatMessage assistant = ChatMessage(
      id: 'a1',
      role: MessageRole.assistant,
      content: '',
      createdAt: 2,
      status: MessageStatus.success,
    )..serverToolCallsJson = _callsJson();

    final List<Map<String, dynamic>> out = ChatService.buildApiMessages(
      <ChatMessage>[
        ChatMessage(
          id: 'u1',
          role: MessageRole.user,
          content: '总结 https://example.com',
          createdAt: 1,
          status: MessageStatus.success,
        ),
        assistant,
      ],
      null,
      true,
    );

    expect(out.length, 2);
    final Map<String, dynamic> replayed = out.last;
    expect(replayed['role'], 'assistant');
    final List<Map<String, dynamic>> steps =
        (replayed['server_tool_calls'] as List<Map<String, dynamic>>);
    expect(steps.single['calls'][0]['signature'], 'sig-abc');
  });

  test('ChatMessage.tryParse drops corrupt server tool calls', () {
    final ChatMessage? valid = ChatMessage.tryParse(<String, dynamic>{
      'id': 'a1',
      'role': 'assistant',
      'content': 'hi',
      'createdAt': 1,
      'status': 'success',
      'serverToolCalls': _callsJson(),
    });
    expect(valid?.serverToolCallsJson, isNotEmpty);

    final ChatMessage? corrupt = ChatMessage.tryParse(<String, dynamic>{
      'id': 'a2',
      'role': 'assistant',
      'content': 'hi',
      'createdAt': 1,
      'status': 'success',
      'serverToolCalls': '[]',
    });
    expect(corrupt?.serverToolCallsJson, isEmpty);
  });
}
