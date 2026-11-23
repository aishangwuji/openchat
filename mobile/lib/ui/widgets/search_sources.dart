import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/app_colors.dart';
import '../../data/models/chat_models.dart';

/// 站点图标：圆形底 + 服务端 site_icon；加载失败或缺失时回退首字母。
///
/// Business Rule: site_icon 可能为 null、可能 403/失效，界面不能因此空一块，
/// 所以统一走 errorBuilder 回退，且图标尺寸固定，避免列表抖动。
class SiteIcon extends StatelessWidget {
  const SiteIcon({super.key, required this.source, this.size = 18});

  final SearchSource source;
  final double size;

  @override
  Widget build(BuildContext context) {
    final AppColors c = context.colors;
    final String? icon = source.siteIcon;
    final String label = _initial(source);
    final Widget fallback = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: c.fill,
        borderRadius: BorderRadius.circular(size / 2),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: size * 0.55,
          fontWeight: FontWeight.w600,
          color: c.textSecondary,
        ),
      ),
    );
    if (icon == null || icon.isEmpty) {
      return fallback;
    }
    return ClipOval(
      child: Image.network(
        icon,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => fallback,
      ),
    );
  }

  static String _initial(SearchSource source) {
    final String? name = source.siteName;
    if (name != null && name.trim().isNotEmpty) {
      return name.trim().substring(0, 1).toUpperCase();
    }
    final String host = Uri.tryParse(source.url)?.host ?? '';
    final String bare = host.startsWith('www.') ? host.substring(4) : host;
    return bare.isEmpty ? '?' : bare.substring(0, 1).toUpperCase();
  }
}

/// 正文下方的搜索摘要行：「4 个重叠站点图标 + 参考了 N 个网页 + 箭头」。
///
/// 对齐官方客户端：摘要行只负责入口，完整结果在面板里看，避免正文被来源卡片挤占。
class SearchSummaryBar extends StatelessWidget {
  const SearchSummaryBar({
    super.key,
    required this.sources,
    required this.onTap,
  });

  final List<SearchSource> sources;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppColors c = context.colors;
    final int shown = sources.length > 4 ? 4 : sources.length;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            SizedBox(
              width: 18.0 + (shown - 1) * 12.0,
              height: 18,
              child: Stack(
                children: <Widget>[
                  for (int i = 0; i < shown; i++)
                    Positioned(
                      left: i * 12.0,
                      child: Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: c.surface, width: 1.5),
                        ),
                        child: SiteIcon(source: sources[i], size: 18),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '参考了 ${sources.length} 个网页',
              style: TextStyle(fontSize: 12, color: c.textSecondary),
            ),
            const SizedBox(width: 2),
            Icon(Icons.chevron_right_rounded, size: 16, color: c.iconMuted),
          ],
        ),
      ),
    );
  }
}

/// 打开搜索结果面板；[highlight] 为引用角标序号（1 起），打开后滚到并高亮。
Future<void> showSourcePanel(
  BuildContext context,
  List<SearchSource> sources, {
  int? highlight,
}) {
  if (sources.isEmpty) {
    return Future<void>.value();
  }
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: context.colors.overlayScrim,
    builder: (BuildContext ctx) =>
        _SourcePanel(sources: sources, highlight: highlight),
  );
}

class _SourcePanel extends StatefulWidget {
  const _SourcePanel({required this.sources, this.highlight});

  final List<SearchSource> sources;
  final int? highlight;

  @override
  State<_SourcePanel> createState() => _SourcePanelState();
}

class _SourcePanelState extends State<_SourcePanel> {
  late final ScrollController _scroll = ScrollController(
    initialScrollOffset: _initialOffset(),
  );

  static const double _cardExtent = 104;

  double _initialOffset() {
    final int? index = widget.highlight;
    if (index == null || index <= 1) {
      return 0;
    }
    return (index - 1) * _cardExtent;
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppColors c = context.colors;
    final double maxHeight = MediaQuery.sizeOf(context).height * 0.78;
    return Container(
      constraints: BoxConstraints(maxHeight: maxHeight),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 12, 8),
              child: Row(
                children: <Widget>[
                  Text(
                    '搜索结果',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: c.textTitle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${widget.sources.length}',
                    style: TextStyle(fontSize: 13, color: c.textMuted),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: Icon(Icons.close_rounded, size: 20, color: c.iconMuted),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: c.borderSoft),
            Flexible(
              child: ListView.separated(
                controller: _scroll,
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
                itemCount: widget.sources.length,
                separatorBuilder: (_, _) => const SizedBox(height: 4),
                itemBuilder: (BuildContext context, int index) => _SourceCard(
                  source: widget.sources[index],
                  index: index + 1,
                  highlighted: widget.highlight == index + 1,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SourceCard extends StatelessWidget {
  const _SourceCard({
    required this.source,
    required this.index,
    required this.highlighted,
  });

  final SearchSource source;
  final int index;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final AppColors c = context.colors;
    final String date = formatPublishedAt(source.publishedAt);
    final String site = source.siteName?.trim().isNotEmpty == true
        ? source.siteName!.trim()
        : (Uri.tryParse(source.url)?.host ?? '');
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => _openUrl(context, source.url),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          color: highlighted ? c.accentSoftSelected : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: highlighted ? c.accentOutline : Colors.transparent,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Container(
              width: 22,
              height: 22,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: c.fill,
                borderRadius: BorderRadius.circular(11),
              ),
              child: Text(
                '$index',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: c.textSecondary,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      SiteIcon(source: source, size: 14),
                      const SizedBox(width: 5),
                      if (site.isNotEmpty)
                        Flexible(
                          child: Text(
                            site,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                              color: c.textSecondary,
                            ),
                          ),
                        ),
                      if (site.isNotEmpty && date.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: Text(
                            '·',
                            style: TextStyle(fontSize: 11, color: c.textFaint),
                          ),
                        ),
                      if (date.isNotEmpty)
                        Text(
                          date,
                          style: TextStyle(fontSize: 11, color: c.textMuted),
                        ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  Text(
                    source.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      height: 1.35,
                      fontWeight: FontWeight.w500,
                      color: c.textPrimary,
                    ),
                  ),
                  if (source.snippet?.trim().isNotEmpty == true) ...<Widget>[
                    const SizedBox(height: 4),
                    Text(
                      source.snippet!.trim(),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.45,
                        color: c.textMuted,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 服务端 published_at 可能是 RFC3339 或网页上的松散日期；统一成 YYYY/MM/DD。
String formatPublishedAt(String? value) {
  if (value == null || value.trim().isEmpty) {
    return '';
  }
  final DateTime? parsed = DateTime.tryParse(value.trim());
  if (parsed == null) {
    return value.trim();
  }
  final String month = parsed.month.toString().padLeft(2, '0');
  final String day = parsed.day.toString().padLeft(2, '0');
  return '${parsed.year}/$month/$day';
}

Future<void> _openUrl(BuildContext context, String url) async {
  final Uri? uri = Uri.tryParse(url);
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
    return;
  }
  final bool ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
  if (!ok && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('无法打开链接')),
    );
  }
}
