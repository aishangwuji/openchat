import 'package:balance_app/data/models/chat_models.dart';
import 'package:balance_app/data/services/chat_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // 2026-11-23 是星期一。
  final int monday = DateTime(2026, 11, 23, 10).millisecondsSinceEpoch;

  test('latest_reminder immediately precedes each user message', () {
    final List<Map<String, dynamic>> out = ChatService.buildApiMessages(
      <ChatMessage>[
        ChatMessage(
          id: 'u1',
          role: MessageRole.user,
          content: '今天有什么新闻',
          createdAt: monday,
          status: MessageStatus.success,
        ),
        ChatMessage(
          id: 'a1',
          role: MessageRole.assistant,
          content: '稍等。',
          createdAt: monday + 1,
          status: MessageStatus.success,
        ),
      ],
      null,
      true,
      reminder: const ChatReminder(location: '新加坡', language: 'zh-CN'),
    );

    expect(out.length, 3);
    expect(out[0]['role'], 'latest_reminder');
    expect(out[0]['content'], '2026-11-23,星期一,新加坡,App,中文');
    expect(out[1]['role'], 'user');
    expect(out[2]['role'], 'assistant');
  });

  test('location is optional and English weekday follows the language', () {
    final List<Map<String, dynamic>> out = ChatService.buildApiMessages(
      <ChatMessage>[
        ChatMessage(
          id: 'u1',
          role: MessageRole.user,
          content: 'Any news today?',
          createdAt: monday,
          status: MessageStatus.success,
        ),
      ],
      null,
      true,
      reminder: const ChatReminder(location: '', language: 'en-US'),
    );

    expect(out.first['role'], 'latest_reminder');
    expect(out.first['content'], '2026-11-23,Monday,,App,English');
  });

  test('no reminder when the caller does not pass one', () {
    final List<Map<String, dynamic>> out = ChatService.buildApiMessages(
      <ChatMessage>[
        ChatMessage(
          id: 'u1',
          role: MessageRole.user,
          content: 'hi',
          createdAt: monday,
          status: MessageStatus.success,
        ),
      ],
      null,
      true,
    );

    expect(out.single['role'], 'user');
  });

  test('sanitizeLocation strips newlines and caps the length', () {
    expect(sanitizeLocation('  上海\n浦东  '), '上海 浦东');
    expect(sanitizeLocation('x' * 60).length, 40);
  });
}
