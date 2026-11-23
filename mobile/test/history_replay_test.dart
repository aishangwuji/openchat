import 'package:balance_app/data/models/chat_models.dart';
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
}
