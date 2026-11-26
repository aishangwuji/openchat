import 'package:balance_app/state/chat_controller.dart';
import 'package:flutter_test/flutter_test.dart';

/// 官方《联网工具》《文件解析》《模型内容安全》《会话标题》都要求 deepseek-flash；
/// 这条规则决定发送前是否把用户选的 v4-pro 切回 flash。
void main() {
  test('DeepSeek 任一服务端能力开启时要求 flash', () {
    expect(
      requiresDeepSeekFlash(
        providerId: 'deepseek',
        webSearch: true,
        files: false,
        readUrl: false,
        safety: false,
        title: false,
      ),
      isTrue,
    );
    expect(
      requiresDeepSeekFlash(
        providerId: 'deepseek',
        webSearch: false,
        files: true,
        readUrl: false,
        safety: false,
        title: false,
      ),
      isTrue,
    );
    expect(
      requiresDeepSeekFlash(
        providerId: 'deepseek',
        webSearch: false,
        files: false,
        readUrl: false,
        safety: false,
        title: true,
      ),
      isTrue,
    );
  });

  test('DeepSeek 全部扩展关闭时不强制 flash（可继续用 v4-pro）', () {
    expect(
      requiresDeepSeekFlash(
        providerId: 'deepseek',
        webSearch: false,
        files: false,
        readUrl: false,
        safety: false,
        title: false,
      ),
      isFalse,
    );
  });
}
