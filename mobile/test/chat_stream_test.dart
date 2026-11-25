import 'dart:convert';

import 'package:balance_app/data/models/chat_models.dart';
import 'package:balance_app/data/services/chat_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 服务端联网工具的响应契约（官方《Chat Completions API》）：
/// `server_tool_event` 与 `delta` 并列、`annotations`/`server_tool_calls` 只在末块下发，
/// 这些块都可能没有正文增量。本文件锁定「它们能穿过流式解码到达上层」。
ChatRequestOptions _options() => const ChatRequestOptions(
      providerId: 'deepseek',
      apiKey: 'test-key',
      model: 'deepseek-flash',
      messages: <ChatMessage>[],
      enableWebSearch: true,
      enableReadUrl: true,
    );

String _sse(Map<String, Object?> payload) =>
    'data: ${jsonEncode(payload)}\n\n';

Map<String, Object?> _chunk(Map<String, Object?> choice) =>
    <String, Object?>{'choices': <Object?>[choice]};

Future<List<ChatStreamEvent>> _collect(String body) async {
  final MockClient client = MockClient((http.Request request) async {
    return http.Response.bytes(
      utf8.encode(body),
      200,
      headers: <String, String>{'content-type': 'text/event-stream'},
    );
  });
  return ChatService.streamChat(_options(), clientFactory: () => client)
      .toList();
}

void main() {
  test('工具事件/引用/签名即使没有正文增量也能到达上层', () async {
    final String body = <String>[
      _sse(_chunk(<String, Object?>{
        'delta': <String, Object?>{'content': '稍等'},
        'finish_reason': null,
      })),
      // call_started：整个 chunk 没有 delta 键（末块形态也可能是这样）。
      _sse(<String, Object?>{
        'choices': <Object?>[
          <String, Object?>{
            'server_tool_event': <String, Object?>{
              'type': 'call_started',
              'step': 0,
              'call': <String, Object?>{
                'index': 0,
                'id': 'c1',
                'type': 'deepseek_web_search',
                'kind': 'search',
                'action': <String, Object?>{
                  'type': 'search',
                  'queries': <String>['今天天气'],
                },
              },
            },
          },
        ],
      }),
      _sse(_chunk(<String, Object?>{
        'delta': <String, Object?>{},
        'server_tool_event': <String, Object?>{
          'type': 'call_completed',
          'step': 0,
          'call': <String, Object?>{
            'index': 0,
            'id': 'c1',
            'status': 'completed',
            'sources': <Object?>[
              <String, Object?>{
                'type': 'url',
                'url': 'https://example.com/a',
                'title': '示例站点',
                'snippet': '摘要',
                'site_name': 'Example',
                'published_at': '2026-01-02T03:04:05+00:00',
              },
            ],
          },
        },
      })),
      // 末块：只有 annotations / server_tool_calls，没有正文。
      _sse(_chunk(<String, Object?>{
        'delta': <String, Object?>{
          'annotations': <Object?>[
            <String, Object?>{
              'type': 'url_citation',
              'url_citation': <String, Object?>{
                'url': 'https://example.com/a',
                'title': '示例站点',
                'start_index': 0,
                'end_index': 2,
              },
            },
          ],
          'server_tool_calls': <Object?>[
            <String, Object?>{
              'index': 0,
              'reasoning_content': '',
              'calls': <Object?>[
                <String, Object?>{
                  'index': 0,
                  'id': 'r1',
                  'type': 'deepseek_read_url',
                  'kind': 'read_link',
                  'action': <String, Object?>{
                    'type': 'read_link',
                    'url': 'https://example.com/a',
                  },
                  'status': 'completed',
                  'page': <String, Object?>{
                    'url': 'https://example.com/a',
                    'title': '示例站点',
                    'published_at': null,
                  },
                  'signature': 'sig-abc',
                },
              ],
            },
          ],
        },
        'finish_reason': 'stop',
      })),
      'data: [DONE]\n\n',
    ].join();

    final List<ChatStreamEvent> events = await _collect(body);

    expect(events.first.content, '稍等');
    expect(
      events.any((ChatStreamEvent e) => e.searchHint == '正在联网搜索「今天天气」…'),
      isTrue,
      reason: 'call_started 的进度提示不能被正文过滤丢掉',
    );
    final List<SearchSource> sources =
        events.expand((ChatStreamEvent e) => e.sources).toList();
    expect(sources.map((SearchSource s) => s.url), contains('https://example.com/a'));
    expect(events.any((ChatStreamEvent e) => e.citations.isNotEmpty), isTrue);
    expect(
      events.any(
        (ChatStreamEvent e) => e.serverToolCallsJson.contains('sig-abc'),
      ),
      isTrue,
      reason: '阅读链接的 signature 必须留存，否则多轮回传失效',
    );
    expect(events.last.done, isTrue);
  });
}
