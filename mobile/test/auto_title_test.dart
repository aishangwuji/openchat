import 'package:balance_app/data/models/chat_models.dart';
import 'package:balance_app/data/services/chat_storage_service.dart';
import 'package:balance_app/data/services/preferences_service.dart';
import 'package:balance_app/state/chat_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('autoTitleFor keeps short text and truncates long text', () {
    expect(autoTitleFor('  北京明天会下雨吗  '), '北京明天会下雨吗');
    expect(autoTitleFor('一二三四五六七八九十一二三四五六'), '一二三四五六七八九十一二三四...');
  });

  test('autoTitled survives a storage round-trip', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final PreferencesService prefs = await PreferencesService.load();
    final ChatStorageService storage = ChatStorageService(prefs);
    final ChatSession session = ChatSession(
      id: 's1',
      title: '新对话',
      characterId: '',
      providerId: 'deepseek',
      modelId: 'deepseek-flash',
      updatedAt: 1,
    )..autoTitled = true;

    await storage.saveSessions(<ChatSession>[session]);
    final List<ChatSession> loaded = await storage.loadSessions();

    expect(loaded.single.autoTitled, true);
    expect(loaded.single.title, '新对话');
  });
}
