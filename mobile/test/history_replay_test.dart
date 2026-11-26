import 'package:balance_app/data/models/chat_models.dart';
import 'package:balance_app/data/services/chat_service.dart';
import 'package:balance_app/state/chat_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('replayMessage keeps attachments so file_id survives multi-turn', () {
    final ChatMessage message = ChatMessage(
      id: 'm1',
      role: MessageRole.user,
      content: '这份文档讲了什么',
      createdAt: 1,
      status: MessageStatus.success,
      attachments: <MessageAttachment>[
        const MessageAttachment(
          fileId: 'file-123',
          fileName: 'report.pdf',
          purpose: 'text_recognition',
          bytes: 10,
        ),
      ],
    );

    final ChatMessage replay = replayMessage(message, '小明');

    expect(replay.content, '小明：这份文档讲了什么');
    expect(replay.attachments.single.fileId, 'file-123');
  });

  test('replayMessage leaves assistant replies untouched', () {
    final ChatMessage message = ChatMessage(
      id: 'm2',
      role: MessageRole.assistant,
      content: '文档讲了 A。',
      createdAt: 2,
      status: MessageStatus.success,
      reasoningContent: '先看目录',
    );

    final ChatMessage replay = replayMessage(message, '小明');

    expect(replay.content, '文档讲了 A。');
    expect(replay.reasoningContent, '先看目录');
  });

  /// 官方 Chat Completions 的 assistant 消息只应回传正文与 server_tool_calls；
  /// DeepSeek 回传 reasoning_content 会把上一轮的计划带进新问题（鸿蒙端实测「串味」）。
  List<ChatMessage> sampleHistory() => <ChatMessage>[
        ChatMessage(
          id: 'u1',
          role: MessageRole.user,
          content: '帮我查下今天的新闻',
          createdAt: 1,
          status: MessageStatus.success,
        ),
        ChatMessage(
          id: 'a1',
          role: MessageRole.assistant,
          content: '',
          reasoningContent: '先联网检索，再总结',
          createdAt: 2,
          status: MessageStatus.success,
        ),
      ];

  test('buildApiMessages 不回传 DeepSeek 的 reasoning_content，空的思考回合被丢弃', () {
    final List<Map<String, dynamic>> wire =
        ChatService.buildApiMessages(sampleHistory(), null, false);

    expect(wire.length, 1);
    expect(wire.single['role'], 'user');
    expect(wire.single.containsKey('reasoning_content'), isFalse);
  });
}
