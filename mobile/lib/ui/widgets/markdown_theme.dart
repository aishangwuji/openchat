import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import '../../core/theme/app_colors.dart';

/// 作者态 Markdown 的统一外观：代码块（语言标签 + 复制）、表格、引用、行内代码。
///
/// 官方 chat-demo 的排版要点：代码块自带语言与复制按钮、表格有描边与表头底色、
/// 引用块左侧描边、行内代码浅底。gpt_markdown 已内置这些能力，这里只负责把
/// 颜色/圆角接到本项目语义 token 上，避免深色皮肤下出现生硬的黑底白字。
GptMarkdownStyleSheet markdownStyleSheet(AppColors c) {
  return GptMarkdownStyleSheet(
    blockSpacing: 10,
    codeBlock: CodeBlockStyle(
      backgroundColor: c.surfaceAlt,
      borderColor: c.borderSoft,
      borderWidth: 1,
      borderRadius: const Radius.circular(12),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      headerPadding: const EdgeInsets.fromLTRB(12, 8, 6, 0),
      fontSize: 13,
      textColor: c.textPrimary,
      showLanguageLabel: true,
      languageStyle: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w500,
        color: c.textMuted,
      ),
      showCopyButton: true,
      copyLabel: '复制代码',
      copiedLabel: '已复制',
      highlightWhileStreaming: false,
    ),
    inlineCode: InlineCodeStyle(
      backgroundColor: c.fill,
      color: c.textPrimary,
      fontSizeFactor: 0.94,
      borderRadius: const Radius.circular(5),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
    ),
    link: LinkStyle(
      color: c.accent,
      decoration: TextDecoration.none,
      fontWeight: FontWeight.w500,
    ),
    table: TableStyle(
      borderColor: c.borderSoft,
      borderWidth: 1,
      borderRadius: const Radius.circular(10),
      cellPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      headerBackground: c.surfaceAlt,
      headerTextStyle: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: c.textPrimary,
      ),
      rowStripeColor: c.surfaceAlt.withValues(alpha: 0.4),
      overflow: TableOverflow.scroll,
    ),
    // 引用角标：`[N]` 芯片，浅强调底 + 强调色数字，与来源面板序号一致。
    sourceTag: SourceTagStyle(
      backgroundColor: c.accentSoft,
      textStyle: TextStyle(
        fontSize: 9.5,
        height: 1.15,
        fontWeight: FontWeight.w600,
        color: c.accent,
      ),
      size: 18,
      shape: BoxShape.circle,
      padding: const EdgeInsets.all(1),
    ),
    blockQuote: BlockQuoteStyle(      barColor: c.borderCard,
      barWidth: 3,
      barRadius: const Radius.circular(2),
      backgroundColor: c.surfaceAlt,
      padding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
      textStyle: TextStyle(fontSize: 14, height: 1.6, color: c.textSecondary),
    ),
    heading: HeadingStyle(
      textStyle: TextStyle(
        fontSize: 16,
        height: 1.4,
        fontWeight: FontWeight.w600,
        color: c.textTitle,
      ),
      padding: const EdgeInsets.only(top: 6, bottom: 4),
      showDivider: false,
    ),
    hr: HrStyle(color: c.borderSoft, thickness: 1),
  );
}
