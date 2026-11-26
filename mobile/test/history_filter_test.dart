import 'package:balance_app/data/models/chat_models.dart';
import 'package:balance_app/data/services/chat_service.dart';
import 'package:balance_app/state/chat_controller.dart';
import 'package:flutter_test/flutter_test.dart';

ChatMessage _message(
  MessageRole role,
  String content, {
  List<MessageAttachment> attachments = const <MessageAttachment>[],
  String serverToolCalls = '',
  int createdAt = 0,
}) {
  return ChatMessage(
    id: 'm_${role.name}_$createdAt',
    role: role,
    content: content,
    createdAt: createdAt,
    status: MessageStatus.success,
    attachments: attachments,
    serverToolCallsJson: serverToolCalls,
  );
}

void main() {
  test('只带附件或只带工具调用的消息仍进入历史', () {    expect(
      isReplayableMessage(
        _message(
          MessageRole.user,
          '',
          attachments: const <MessageAttachment>[
            MessageAttachment(
              fileId: 'file-1',
              fileName: 'report.pdf',
              purpose: 'text_recognition',
              bytes: 10,
            ),
          ],
        ),
      ),
      isTrue,
    );
    expect(
      isReplayableMessage(
        _message(MessageRole.assistant, '', serverToolCalls: '[]'),
      ),
      isTrue,
    );
    expect(isReplayableMessage(_message(MessageRole.assistant, '')), isFalse);
    expect(isReplayableMessage(_message(MessageRole.system, 'x')), isFalse);
  });

  test('历史按 60 条上限截断（旧值 20 会丢附件/签名轮次）', () {
    final List<ChatMessage> messages = List<ChatMessage>.generate(
      70,
      (int i) => _message(
        i.isEven ? MessageRole.user : MessageRole.assistant,
        'x',
        createdAt: i,
      ),
    );
    final List<Map<String, dynamic>> out =
        ChatService.buildApiMessages(messages, null, false);
    expect(out.length, 60);
  });

  test('历史按 100000 字预算截断，且保留的是最近的消息', () {
    final List<ChatMessage> messages = List<ChatMessage>.generate(
      60,
      (int i) => _message(
        i.isEven ? MessageRole.user : MessageRole.assistant,
        'y' * 2001,
        createdAt: i,
      ),
    );
    final List<Map<String, dynamic>> out =
        ChatService.buildApiMessages(messages, null, false);
    expect(out.length, lessThan(60));
    expect(out.length, greaterThan(40));
    // 最新一条必须在，最老一条应被预算裁掉。
    expect(out.last['content'], 'y' * 2001);
  });

  test('纯附件消息只生成 file 块，不拼空 text 块', () {
    final ChatMessage message = _message(
      MessageRole.user,
      '',
      attachments: const <MessageAttachment>[
        MessageAttachment(
          fileId: 'file-1',
          fileName: 'report.pdf',
          purpose: 'text_recognition',
          bytes: 10,
        ),
      ],
    );
    final List<Map<String, dynamic>> out =
        ChatService.buildApiMessages(<ChatMessage>[message], null, true);
    final List<Map<String, String>> parts =
        (out.single['content'] as List<Object?>).cast<Map<String, String>>();
    expect(parts.length, 1);
    expect(parts.single['type'], 'file');
    expect(parts.single['file_id'], 'file-1');
  });
}
