import 'package:balance_app/core/utils/session_groups.dart';
import 'package:balance_app/data/models/chat_models.dart';
import 'package:flutter_test/flutter_test.dart';

ChatSession _session(String id, DateTime updatedAt) => ChatSession(
      id: id,
      title: id,
      characterId: '',
      providerId: 'deepseek',
      modelId: 'deepseek-flash',
      updatedAt: updatedAt.millisecondsSinceEpoch,
    );

void main() {
  test('groups sessions by natural day and sorts newest first', () {
    final DateTime now = DateTime(2026, 11, 23, 9);
    final List<SessionGroup> groups = groupSessions(
      <ChatSession>[
        _session('old', DateTime(2026, 9, 3, 12)),
        _session('today-early', DateTime(2026, 11, 23, 0, 5)),
        _session('yesterday', DateTime(2026, 11, 22, 23, 55)),
        _session('week', DateTime(2026, 11, 18)),
        _session('month', DateTime(2026, 10, 30)),
        _session('today-late', DateTime(2026, 11, 23, 8)),
      ],
      now: now,
    );

    expect(
      groups.map((SessionGroup g) => g.label).toList(),
      <String>['今天', '昨天', '7 天内', '30 天内', '2026年9月'],
    );
    expect(
      groups.first.sessions.map((ChatSession s) => s.id).toList(),
      <String>['today-late', 'today-early'],
    );
  });

  test('23:59 and 00:01 fall into different groups', () {
    final DateTime now = DateTime(2026, 11, 23, 0, 1);
    final List<SessionGroup> groups = groupSessions(
      <ChatSession>[
        _session('just-now', DateTime(2026, 11, 23, 0, 0)),
        _session('late-night', DateTime(2026, 11, 22, 23, 59)),
      ],
      now: now,
    );

    expect(groups.first.label, '今天');
    expect(groups.last.label, '昨天');
  });
}
