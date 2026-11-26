import 'dart:convert';

import 'package:balance_app/data/models/chat_models.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> _step(String signature, {int index = 0}) {
  return <String, Object?>{
    'index': index,
    'reasoning_content': '',
    'calls': <Object?>[
      <String, Object?>{
        'index': 0,
        'id': 'srvtoolu_$index',
        'type': 'deepseek_read_url',
        'kind': 'read_link',
        'action': <String, Object?>{
          'type': 'read_link',
          'url': 'https://example.com/$index',
        },
        'status': 'completed',
        'signature': signature,
      },
    ],
  };
}

void main() {
  test('单个超长 signature 只丢自己，不丢同轮其他网页', () {
    final Object raw = <Object?>[
      _step('s' * 16, index: 0),
      _step('h' * maxServerToolCallsChars, index: 1),
    ];
    final String encoded = encodeServerToolCalls(raw);
    expect(encoded, isNotEmpty);
    expect(encoded, contains('ssss'));
    expect(encoded, isNot(contains('hhhh')));
    expect(jsonDecode(encoded), isA<List<Object?>>());
  });

  test('未超限时两步都原样保留', () {
    final String encoded = encodeServerToolCalls(<Object?>[
      _step('a' * 16, index: 0),
      _step('b' * 16, index: 1),
    ]);
    final List<Object?> steps = jsonDecode(encoded) as List<Object?>;
    expect(steps.length, 2);
    expect(encoded, contains('aaaaaaaa'));
    expect(encoded, contains('bbbbbbbb'));
  });

  test('不是 server_tool_calls 结构时返回空串', () {
    expect(encodeServerToolCalls(null), '');
    expect(encodeServerToolCalls('not-a-list'), '');
    expect(encodeServerToolCalls(<Object?>[<String, Object?>{'calls': 'x'}]), '');
  });
}
