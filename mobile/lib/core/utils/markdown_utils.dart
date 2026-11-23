/// Rewrites inline citation tokens into clickable superscript links.
///
/// DeepSeek answers carry `[citation:N]` markers (official chat-demo format);
/// older recordings in this app used `[ref_N]`, so both are accepted.
///
/// Business Rule: fenced and inline code must be left untouched, otherwise a
/// code sample containing `[citation:1]` would unexpectedly become a link.
/// A token without a matching source is dropped: showing a dangling number is
/// worse than showing nothing (same rule as the official client).
String rewriteCitations(String source, {int maxIndex = 0}) {
  final StringBuffer out = StringBuffer();
  int index = 0;
  bool inFence = false;
  bool inInlineCode = false;

  // 返回 (序号, 标记结束位置)；识别 `[citation:N]` 与历史 `[ref_N]`。
  (int, int)? tokenAt(int at) {
    String? digits;
    int end = -1;
    if (source.startsWith('[citation:', at)) {
      final int close = source.indexOf(']', at + 10);
      if (close > at) {
        digits = source.substring(at + 10, close);
        end = close + 1;
      }
    } else if (source.startsWith('[ref_', at)) {
      final int close = source.indexOf(']', at + 5);
      if (close > at) {
        digits = source.substring(at + 5, close);
        end = close + 1;
      }
    }
    if (digits == null) {
      return null;
    }
    final int? value = int.tryParse(digits);
    if (value == null || value <= 0) {
      return null;
    }
    return (value, end);
  }

  while (index < source.length) {
    if (source.startsWith('```', index)) {
      inFence = !inFence;
      out.write('```');
      index += 3;
      continue;
    }
    if (!inFence && source[index] == '`') {
      inInlineCode = !inInlineCode;
      out.write('`');
      index++;
      continue;
    }
    if (!inFence && !inInlineCode) {
      final (int, int)? token = tokenAt(index);
      if (token != null) {
        // 有对应来源时换成 `[N]`：gpt_markdown 的 source tag 会渲染成角标芯片，
        // 由 onSourceTagTap 打开来源面板；没有来源或越界的整段丢掉。
        if (maxIndex > 0 && token.$1 <= maxIndex) {
          out.write('[${token.$1}]');
        }
        index = token.$2;
        continue;
      }
    }
    out.write(source[index]);
    index++;
  }
  return out.toString();
}

/// Returns the citation number for `#cite-N`, otherwise null.
int? citationIndex(String href) {
  if (!href.startsWith('#cite-')) {
    return null;
  }
  return int.tryParse(href.substring(6));
}

/// 正文里是否已经带 `[citation:N]` 标记（有标记就不再按 annotations 偏移补角标）。
bool hasCitationTokens(String content) =>
    RegExp(r'\[(?:citation:\d+|ref_\d+)\]').hasMatch(content);

bool isSafeExternalUrl(String href) {
  final Uri? uri = Uri.tryParse(href);
  if (uri == null) {
    return false;
  }
  return uri.scheme == 'http' || uri.scheme == 'https' || uri.scheme == 'mailto';
}
