import 'package:balance_app/core/utils/markdown_utils.dart';
import 'package:balance_app/data/models/chat_models.dart';
import 'package:balance_app/ui/widgets/search_sources.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('rewriteCitations', () {
    test('turns [citation:N] into a superscript link', () {
      expect(
        rewriteCitations('冰岛人口约 39 万[citation:1]。', maxIndex: 3),
        '冰岛人口约 39 万[1](#cite-1)。',
      );
    });

    test('keeps legacy [ref_N] working', () {
      expect(rewriteCitations('正文[ref_2]', maxIndex: 2), '正文[2](#cite-2)');
    });

    test('drops tokens without a matching source', () {
      expect(rewriteCitations('正文[citation:5]结尾', maxIndex: 2), '正文结尾');
      expect(rewriteCitations('正文[citation:1]', maxIndex: 0), '正文');
    });

    test('leaves code fences and inline code untouched', () {
      const String source = '```\nprint("[citation:1]")\n```\n行内 `[citation:1]` 保留';
      expect(rewriteCitations(source, maxIndex: 3), source);
    });
  });

  test('hasCitationTokens detects both token formats', () {
    expect(hasCitationTokens('a[citation:2]b'), isTrue);
    expect(hasCitationTokens('a[ref_1]b'), isTrue);
    expect(hasCitationTokens('a[citation:x]b'), isFalse);
    expect(hasCitationTokens('plain'), isFalse);
  });

  test('SearchSource keeps siteIcon only for http(s)', () {
    final SearchSource? ok = SearchSource.tryParse(<String, Object?>{
      'url': 'https://a.com',
      'siteIcon': 'https://cdn.deepseek.com/site-icons/a.com',
    });
    expect(ok?.siteIcon, 'https://cdn.deepseek.com/site-icons/a.com');

    final SearchSource? bad = SearchSource.tryParse(<String, Object?>{
      'url': 'https://a.com',
      'siteIcon': 'javascript:alert(1)',
    });
    expect(bad?.siteIcon, isNull);
    expect(bad?.toJson().containsKey('siteIcon'), isFalse);
  });

  test('formatPublishedAt normalizes RFC3339 and keeps loose dates', () {
    expect(formatPublishedAt('2026-01-02T03:04:05+00:00'), isNotEmpty);
    expect(formatPublishedAt('2026-01-02'), '2026/01/02');
    expect(formatPublishedAt('2026年1月2日'), '2026年1月2日');
    expect(formatPublishedAt(null), '');
  });
}
