import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/app_colors.dart';
import '../../data/models/provider.dart';
import '../../state/assets_controller.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/provider_logo.dart';

class AssetsPage extends StatefulWidget {
  const AssetsPage({super.key});

  @override
  State<AssetsPage> createState() => _AssetsPageState();
}

class _AssetsPageState extends State<AssetsPage> {
  int _addTab = 0;
  String _addQuery = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AssetsController>().load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final AppColors c = context.colors;
    final AssetsController assets = context.watch<AssetsController>();
    return Scaffold(
      backgroundColor: c.pageBg,
      body: SafeArea(
        child: Column(
          children: <Widget>[
            _buildHeader(context),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Row(
                children: <Widget>[
                  const Spacer(),
                  if (assets.records.isNotEmpty) ...<Widget>[
                    SizedBox(
                      height: 40,
                      child: OutlinedButton(
                        onPressed: assets.refreshingAll
                            ? null
                            : assets.refreshAll,
                        child: const Text(
                          '刷新全部',
                          style: TextStyle(fontSize: 14),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  SizedBox(
                    height: 40,
                    child: ElevatedButton(
                      onPressed: _openAddSheet,
                      child: const Text(
                        '＋ 添加',
                        style: TextStyle(fontSize: 14),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: assets.records.isEmpty
                  ? _buildEmpty(context)
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                      children: <Widget>[
                        _HeroCard(assets: assets),
                        ...assets.records.map((ProviderRecord record) {
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: _ProviderCard(
                              record: record,
                              onTap: record.loading
                                  ? null
                                  : () => assets.refreshOne(record.defId),
                              onLongPress: () =>
                                  _showCardActions(record.defId),
                              onCheckin: () => _openCheckin(record.defId),
                            ),
                          );
                        }),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final AppColors c = context.colors;
    final DateTime now = DateTime.now();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
      child: Row(
        children: <Widget>[
          InkWell(
            borderRadius: BorderRadius.circular(21),
            onTap: () => Navigator.of(context).maybePop(),
            child: Container(
              width: 42,
              height: 42,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: c.surfaceAlt,
                borderRadius: BorderRadius.circular(21),
              ),
              child: Text(
                '‹',
                style: TextStyle(
                  fontSize: 28,
                  height: 1,
                  color: c.textPrimary,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Text(
            '资产监控',
            style: TextStyle(
              fontSize: 19,
              fontWeight: FontWeight.w600,
              color: c.textTitle,
            ),
          ),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: c.surfaceAlt,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Text(
              '${now.month}月${now.day}日',
              style: TextStyle(fontSize: 13, color: c.textMuted),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty(BuildContext context) {
    final AppColors c = context.colors;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: 60,
            height: 60,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: c.iconTile,
              borderRadius: BorderRadius.circular(30),
              border: Border.all(color: c.accentOutline),
            ),
            child: Text(
              'B',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w500,
                color: c.accent,
              ),
            ),
          ),
          const SizedBox(height: 24),
          Text(
            '暂无服务商',
            style: TextStyle(
              fontSize: 21,
              fontWeight: FontWeight.w500,
              color: c.textTitle,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '添加 API 供应商并填写 Key，即可透视多家余额',
            style: TextStyle(fontSize: 14, color: c.textMuted),
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: 220,
            height: 48,
            child: ElevatedButton(
              onPressed: _openAddSheet,
              child: const Text('添加服务商'),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openAddSheet() async {
    final AppColors c = context.colors;
    _addTab = 0;
    _addQuery = '';
    final String? picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: c.surface,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setState) {
            return FractionallySizedBox(
              heightFactor: 0.72,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 4, 18, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      '添加服务商',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: c.textTitle,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      onChanged: (String value) =>
                          setState(() => _addQuery = value),
                      decoration: const InputDecoration(
                        hintText: '搜索服务商...',
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: <Widget>[
                        _TabChip(
                          label: '未添加',
                          selected: _addTab == 0,
                          onTap: () => setState(() => _addTab = 0),
                        ),
                        const SizedBox(width: 8),
                        _TabChip(
                          label: '已添加',
                          selected: _addTab == 1,
                          onTap: () => setState(() => _addTab = 1),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: _buildProviderPicker(
                        context,
                        context.read<AssetsController>(),
                        onPick: (String id) =>
                            Navigator.of(context).pop(id),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
    if (picked == null || !mounted) {
      return;
    }
    await _showKeyDialog(picked);
  }

  Widget _buildProviderPicker(
    BuildContext context,
    AssetsController assets, {
    required ValueChanged<String> onPick,
  }) {
    final AppColors c = context.colors;
    final String query = _addQuery.trim().toLowerCase();
    final List<Widget> groups = <Widget>[];
    for (final ProviderCategory category in ProviderCategory.values) {
      final List<ProviderDefinition> items = providers.where((
        ProviderDefinition p,
      ) {
        if (p.category != category) {
          return false;
        }
        final bool added = assets.isAdded(p.id);
        if (_addTab == 0 && added) {
          return false;
        }
        if (_addTab == 1 && !added) {
          return false;
        }
        if (query.isEmpty) {
          return true;
        }
        return p.name.toLowerCase().contains(query) ||
            p.id.toLowerCase().contains(query);
      }).toList(growable: false);
      if (items.isEmpty) {
        continue;
      }
      groups.add(
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 4),
          child: Text(
            category == ProviderCategory.cnOfficial ? '国内官方' : 'API聚合',
            style: TextStyle(fontSize: 12, color: c.textMuted),
          ),
        ),
      );
      for (final ProviderDefinition p in items) {
        final bool added = assets.isAdded(p.id);
        groups.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => onPick(p.id),
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: c.surfaceRow,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: <Widget>[
                    ProviderLogo(providerId: p.id, size: 40, radius: 10),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        p.name,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                          color: c.textPrimary,
                        ),
                      ),
                    ),
                    if (added)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: c.accentSoft,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: c.accentOutline),
                        ),
                        child: Text(
                          '已添加',
                          style: TextStyle(
                            fontSize: 11,
                            color: c.statusGood,
                          ),
                        ),
                      )
                    else
                      Icon(
                        Icons.chevron_right_rounded,
                        size: 20,
                        color: c.iconMuted,
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      }
    }
    if (groups.isEmpty) {
      return Center(
        child: Text(
          '没有匹配的服务商',
          style: TextStyle(fontSize: 13, color: c.textMuted),
        ),
      );
    }
    return ListView(children: groups);
  }

  /// Opens the provider's manual check-in page.
  ///
  /// Business Rule: the check-in endpoint triggers a captcha, so only the user
  /// in a browser can complete it — the app just jumps out and never signs in
  /// on the user's behalf.
  Future<void> _openCheckin(String providerId) async {
    final ProviderDefinition? def = findProvider(providerId);
    final String? url = def?.checkinUrl;
    if (url == null || url.isEmpty) {
      return;
    }
    bool ok = false;
    try {
      ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {
      ok = false;
    }
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('无法打开签到页，请手动在浏览器访问 $url')),
      );
    }
  }

  Future<void> _showKeyDialog(String providerId) async {
    final AppColors c = context.colors;
    final AssetsController assets = context.read<AssetsController>();
    final ProviderDefinition? def = findProvider(providerId);
    final bool isCookie = def?.credentialKind == CredentialKind.cookie;
    final String noun = isCookie ? 'Cookie' : 'Key';
    final TextEditingController controller =
        TextEditingController(text: assets.apiKeyOf(providerId));
    bool obscure = true;
    String? errorText;
    final bool? saved = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setState) {
            void submit() {
              final String text = controller.text.trim();
              // Business Rule: reject bad credentials at the boundary, never
              // send them to the network.
              if (text.isEmpty) {
                setState(() => errorText = isCookie ? '请粘贴 Cookie' : '请粘贴 API Key');
                return;
              }
              if (text.length < 4) {
                setState(() => errorText = isCookie
                    ? 'Cookie 太短，请复制完整内容'
                    : 'API Key 至少需要 4 个字符');
                return;
              }
              final String? fragment = def?.credentialRequiredFragment;
              if (fragment != null && !text.contains(fragment)) {
                setState(() => errorText =
                    'Cookie 需包含 $fragment，请从浏览器开发者工具复制完整 Cookie');
                return;
              }
              Navigator.of(context).pop(true);
            }

            return AlertDialog(
              title: Text('设置 ${def?.name ?? providerId} 的$noun'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    isCookie ? 'Cookie 等同账号登录权限，仅存本地安全存储，请勿外传' : 'Key 仅存储在本地设备安全存储中',
                    style: TextStyle(fontSize: 12, color: c.accent),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: controller,
                    obscureText: obscure,
                    autofocus: true,
                    decoration: InputDecoration(
                      hintText: isCookie ? '粘贴 Cookie（需含 baizhi_session=...）' : '粘贴 API Key',
                      errorText: errorText,
                      suffixIcon: TextButton(
                        onPressed: () => setState(() => obscure = !obscure),
                        child: Text(
                          obscure ? '显示' : '隐藏',
                          style: TextStyle(fontSize: 12, color: c.accent),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('取消'),
                ),
                TextButton(
                  onPressed: submit,
                  child: const Text('保存'),
                ),
              ],
            );
          },
        );
      },
    );
    final String key = controller.text.trim();
    controller.dispose();
    if (saved != true || !mounted) {
      return;
    }
    if (key.length < 4) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$noun 至少需要 4 个字符')),
      );
      return;
    }
    await assets.saveProviderKey(providerId, key);
  }

  Future<void> _showCardActions(String providerId) async {
    final AppColors c = context.colors;
    final AssetsController assets = context.read<AssetsController>();
    final ProviderDefinition? def = findProvider(providerId);
    final String? action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: c.surface,
      builder: (BuildContext context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  def?.name ?? providerId,
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    color: c.textTitle,
                  ),
                ),
                const SizedBox(height: 12),
                _AssetActionRow(
                  badge: '刷',
                  title: '刷新余额',
                  description: '重新查询该服务商的最新余额',
                  onTap: () => Navigator.of(context).pop('refresh'),
                ),
                _AssetActionRow(
                  badge: '键',
                  title: def?.credentialKind == CredentialKind.cookie
                      ? '更新 Cookie'
                      : '更换 Key',
                  description: def?.credentialKind == CredentialKind.cookie
                      ? '更新本地保存的浏览器 Cookie'
                      : '更新本地保存的 API Key',
                  onTap: () => Navigator.of(context).pop('key'),
                ),
                if (def?.checkinUrl != null)
                  _AssetActionRow(
                    badge: '签',
                    title: '去签到',
                    description: '打开浏览器完成人机验证（应用不代签）',
                    onTap: () => Navigator.of(context).pop('checkin'),
                  ),
                _AssetActionRow(
                  badge: '删',
                  title: '移除服务商',
                  description: '删除卡片与本地保存的凭据',
                  danger: true,
                  onTap: () => Navigator.of(context).pop('remove'),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (!mounted || action == null) {
      return;
    }
    if (action == 'refresh') {
      await assets.refreshOne(providerId);
    } else if (action == 'key') {
      await _showKeyDialog(providerId);
    } else if (action == 'checkin') {
      await _openCheckin(providerId);
    } else if (action == 'remove') {
      final bool ok = await showConfirmDialog(
        context,
        title: '移除服务商',
        message: '「${def?.name ?? providerId}」的卡片与本地凭据将被删除。',
        confirmText: '移除',
        danger: true,
      );
      if (ok) {
        await assets.removeProvider(providerId);
      }
    }
  }
}

class _TabChip extends StatelessWidget {
  const _TabChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppColors c = context.colors;
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? c.accentSolid : c.fill,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            color: selected ? c.accentContrast : c.textPrimary,
          ),
        ),
      ),
    );
  }
}

class _HeroCard extends StatelessWidget {
  const _HeroCard({required this.assets});

  final AssetsController assets;

  @override
  Widget build(BuildContext context) {
    final AppColors c = context.colors;
    final List<CurrencyGroup> groups = assets.heroGroups;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 8, bottom: 14),
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 20),
      decoration: BoxDecoration(
        color: c.heroBg,
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: const Color(0x38D9BC83)),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x28231E14),
            blurRadius: 20,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '总资产',
            style: TextStyle(fontSize: 13, color: c.heroMuted),
          ),
          const SizedBox(height: 12),
          if (groups.isEmpty)
            Text(
              '查询后此处汇总可用余额',
              style: TextStyle(fontSize: 15, color: c.heroMuted),
            )
          else if (groups.length > 1) ...<Widget>[
            Text(
              // Currency and credits never mix into one number, so say
              // 「多单位」 instead of pretending it is all money.
              groups.any((CurrencyGroup g) => isCreditUnit(g.currency))
                  ? '多单位组合'
                  : '多币种组合',
              style: TextStyle(
                fontSize: 27,
                fontWeight: FontWeight.w700,
                color: c.heroAccent,
              ),
            ),
            const SizedBox(height: 8),
            ...groups.map(
              (CurrencyGroup g) => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  '可用 ${currencySymbol(g.currency)}'
                  '${formatAmountText(g.currency, g.available)} '
                  '${unitLabel(g.currency)}',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: c.heroText,
                  ),
                ),
              ),
            ),
          ] else
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                Text(
                  '${currencySymbol(groups.first.currency)}'
                  '${formatAmountText(groups.first.currency, groups.first.available)}',
                  style: TextStyle(
                    fontSize: 36,
                    fontWeight: FontWeight.w700,
                    color: c.heroAccent,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 5, left: 4),
                  child: Text(
                    unitLabel(groups.first.currency),
                    style: TextStyle(fontSize: 14, color: c.heroMuted),
                  ),
                ),
              ],
            ),
          const SizedBox(height: 8),
          ...assets.records.map((ProviderRecord record) {
            final BalanceInfo? info = record.info;
            final String value;
            if (info != null) {
              value = '${currencySymbol(info.currency)}'
                  '${formatAmountText(info.currency, info.available)}'
                  '${isCreditUnit(info.currency) ? ' 积分' : ''}';
            } else if (record.loading) {
              value = '查询中…';
            } else if (record.error != null) {
              value = '失败';
            } else {
              value = '未查询';
            }
            return Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                children: <Widget>[
                  Text(
                    record.definition?.name ?? record.defId,
                    style: TextStyle(fontSize: 13, color: c.heroMuted),
                  ),
                  const Spacer(),
                  Text(
                    value,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: info != null
                          ? c.heroText
                          : (record.error != null
                              ? c.dangerText
                              : c.heroMuted),
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }
}

class _ProviderCard extends StatelessWidget {
  const _ProviderCard({
    required this.record,
    required this.onTap,
    required this.onLongPress,
    required this.onCheckin,
  });

  final ProviderRecord record;
  final VoidCallback? onTap;
  final VoidCallback onLongPress;
  final VoidCallback onCheckin;

  @override
  Widget build(BuildContext context) {
    final AppColors c = context.colors;
    final ProviderDefinition? def = record.definition;
    final BalanceInfo? info = record.info;
    final CreditDetail? credit = info?.credit;
    final bool claimed = credit?.dailyClaimed ?? false;
    return InkWell(
      borderRadius: BorderRadius.circular(22),
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: c.borderSoft),
          boxShadow: const <BoxShadow>[
            BoxShadow(
              color: Color(0x12231E14),
              blurRadius: 14,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                ProviderLogo(providerId: record.defId, size: 48),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        def?.name ?? record.defId,
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w500,
                          color: c.textTitle,
                        ),
                      ),
                      if (record.updatedAt.isNotEmpty)
                        Text(
                          record.updatedAt,
                          style: TextStyle(
                            fontSize: 12,
                            color: c.textMuted,
                          ),
                        ),
                    ],
                  ),
                ),
                if (record.loading)
                  SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: c.accent,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            if (info != null)
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: <Widget>[
                  Text(
                    '${currencySymbol(info.currency)}'
                    '${formatAmountText(info.currency, info.available)}',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      color: c.textTitle,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2, left: 4),
                    child: Text(
                      unitLabel(info.currency),
                      style: TextStyle(fontSize: 13, color: c.textMuted),
                    ),
                  ),
                ],
              )
            else if (record.error != null)
              Text(
                record.error!,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.45,
                  color: c.dangerText,
                ),
              )
            else if (!record.loading)
              Text(
                '尚未查询，点击卡片刷新获取余额',
                style: TextStyle(fontSize: 14, color: c.textFaint),
              ),
            if (info != null && credit != null) ...<Widget>[
              const SizedBox(height: 4),
              Text(
                '临时 ${formatCredit(credit.temporary)} · '
                '永久 ${formatCredit(credit.permanent)} · '
                '冻结 ${formatCredit(credit.frozen)}',
                style: TextStyle(fontSize: 12, color: c.textMuted),
              ),
            ],
            if (def?.checkinUrl != null) ...<Widget>[
              const SizedBox(height: 10),
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      claimed
                          ? '今日已领取每日积分，明天再来'
                          : '签到需在浏览器完成人机验证，完成后回来点卡片刷新',
                      style: TextStyle(fontSize: 11, color: c.textMuted),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    height: 34,
                    child: ElevatedButton(
                      onPressed: claimed ? null : onCheckin,
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        textStyle: const TextStyle(fontSize: 13),
                      ),
                      child: Text(claimed ? '今日已签到' : '去签到'),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _AssetActionRow extends StatelessWidget {
  const _AssetActionRow({
    required this.badge,
    required this.title,
    required this.description,
    required this.onTap,
    this.danger = false,
  });

  final String badge;
  final String title;
  final String description;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final AppColors c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: c.surfaceRow,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: <Widget>[
              Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: danger ? c.dangerText : c.accent,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  badge,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                        color: danger ? c.dangerText : c.textPrimary,
                      ),
                    ),
                    Text(
                      description,
                      style: TextStyle(fontSize: 12, color: c.textMuted),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: c.iconMuted,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
