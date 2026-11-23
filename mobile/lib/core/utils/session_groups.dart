import '../../data/models/chat_models.dart';

/// 侧边栏会话分组（对齐官方 chat-demo 的时间线分组）。
class SessionGroup {
  const SessionGroup({
    required this.key,
    required this.label,
    required this.sessions,
  });

  final String key;
  final String label;
  final List<ChatSession> sessions;
}

/// 按最后更新时间分组：今天 / 昨天 / 7 天内 / 30 天内 / 年月。
///
/// Business Rule: 分组只看「自然日」差值（本地时区），不看小时数，
/// 否则 23:59 与 00:01 的两条会被分到同一天；输入不保证有序，这里先按时间倒序。
List<SessionGroup> groupSessions(List<ChatSession> sessions, {DateTime? now}) {
  final DateTime reference = now ?? DateTime.now();
  final List<ChatSession> sorted = List<ChatSession>.from(sessions)
    ..sort((ChatSession a, ChatSession b) => b.updatedAt.compareTo(a.updatedAt));

  final List<SessionGroup> groups = <SessionGroup>[];
  for (final ChatSession session in sorted) {
    final DateTime updated = DateTime.fromMillisecondsSinceEpoch(session.updatedAt);
    final int days = _dayDiff(reference, updated);
    final String key;
    final String label;
    if (days <= 0) {
      key = 'today';
      label = '今天';
    } else if (days == 1) {
      key = 'yesterday';
      label = '昨天';
    } else if (days < 7) {
      key = 'week';
      label = '7 天内';
    } else if (days < 30) {
      key = 'month';
      label = '30 天内';
    } else {
      key = 'ym-${updated.year}-${updated.month}';
      label = '${updated.year}年${updated.month}月';
    }
    if (groups.isNotEmpty && groups.last.key == key) {
      groups.last.sessions.add(session);
    } else {
      groups.add(SessionGroup(
        key: key,
        label: label,
        sessions: <ChatSession>[session],
      ));
    }
  }
  return groups;
}

int _dayDiff(DateTime now, DateTime then) {
  final DateTime today = DateTime(now.year, now.month, now.day);
  final DateTime day = DateTime(then.year, then.month, then.day);
  return today.difference(day).inDays;
}
