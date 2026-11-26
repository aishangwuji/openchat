import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_colors.dart';
import '../../data/models/chat_models.dart';
import '../../data/models/provider.dart';
import '../../state/chat_controller.dart';
import '../widgets/confirm_dialog.dart';

Future<void> showModelPicker(BuildContext context) async {
  final AppColors c = context.colors;
  final ChatController chat = context.read<ChatController>();
  await chat.loadConfiguredProviders();
  if (!context.mounted) {
    return;
  }
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: c.surface,
    builder: (BuildContext context) {
      return FractionallySizedBox(
        heightFactor: 0.68,
        child: Consumer<ChatController>(
          builder: (BuildContext context, ChatController chat, _) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Text(
                        '选择服务商与模型',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                          color: c.textTitle,
                        ),
                      ),
                      const Spacer(),
                      chat.fetchingModels
                          ? Text(
                              '拉取中...',
                              style: TextStyle(
                                fontSize: 12,
                                color: c.accent,
                              ),
                            )
                          : InkWell(
                              onTap: chat.refreshModelList,
                              child: Text(
                                '刷新列表',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: c.accent,
                                ),
                              ),
                            ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  if (chat.configuredProviders.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        '尚未配置 DeepSeek API Key，请到「设置 > 资产监控」添加',
                        style: TextStyle(fontSize: 13, color: c.textMuted),
                      ),
                    ),
                  const SizedBox(height: 12),
                  Divider(color: c.divider, height: 1),
                  const SizedBox(height: 8),
                  Expanded(
                    child: chat.availableModels.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                Text(
                                  chat.fetchingModels
                                      ? '正在拉取模型列表...'
                                      : '未探测到可用模型',
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: c.textMuted,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  '请确认已在「设置 > 资产监控」配置对应厂商的正确 API Key',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: c.textFaint,
                                  ),
                                ),
                              ],
                            ),
                          )
                        : ListView.builder(
                            itemCount: chat.availableModels.length,
                            itemBuilder: (BuildContext context, int index) {
                              final ModelInfo model =
                                  chat.availableModels[index];
                              final bool selected =
                                  model.id == chat.currentModelId;
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 4),
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(14),
                                  onTap: () async {
                                    await chat.selectModel(model.id);
                                    if (context.mounted) {
                                      Navigator.of(context).pop();
                                    }
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 14,
                                      vertical: 13,
                                    ),
                                    decoration: BoxDecoration(
                                      color: selected
                                          ? c.accentSoftSelected
                                          : c.surface,
                                      borderRadius: BorderRadius.circular(14),
                                      border: Border.all(
                                        color: selected
                                            ? c.accentOutline
                                            : Colors.transparent,
                                      ),
                                    ),
                                    child: Row(
                                      children: <Widget>[
                                        Expanded(
                                          child: Text(
                                            model.id,
                                            style: TextStyle(
                                              fontSize: 14,
                                              fontWeight: selected
                                                  ? FontWeight.w600
                                                  : FontWeight.w400,
                                              color: selected
                                                  ? c.accent
                                                  : c.textPrimary,
                                            ),
                                          ),
                                        ),
                                        if (isThinkingSupported(
                                          chat.currentProviderId,
                                          model.id,
                                        ))
                                          _Pill(
                                            text: '深度思考',
                                            color: c.accent,
                                            background: c.accentSoft,
                                          ),
                                        if (selected)
                                          Padding(
                                            padding:
                                                const EdgeInsets.only(left: 8),
                                            child: Text(
                                              '已选',
                                              style: TextStyle(
                                                fontSize: 12,
                                                color: c.accent,
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            );
          },
        ),
      );
    },
  );
}

Future<void> showSessionActions(
  BuildContext context,
  ChatSession session,
) async {
  final AppColors c = context.colors;
  final ChatController chat = context.read<ChatController>();
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
                session.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: c.textTitle,
                ),
              ),
              const SizedBox(height: 12),
              _ActionRow(
                badge: '改',
                title: '重命名',
                description: '修改该会话在历史中的名称',
                onTap: () => Navigator.of(context).pop('rename'),
              ),
              _ActionRow(
                badge: session.isPrivate ? '开' : '密',
                title: session.isPrivate ? '取消保密' : '设为保密',
                description: session.isPrivate
                    ? '取消后打开该会话不再需要身份验证'
                    : '打开该会话前需要人脸 / 指纹验证',
                onTap: () => Navigator.of(context).pop('privacy'),
              ),
              _ActionRow(
                badge: '删',
                title: '删除会话',
                description: '删除该会话及其全部消息',
                danger: true,
                onTap: () => Navigator.of(context).pop('delete'),
              ),
            ],
          ),
        ),
      );
    },
  );
  if (!context.mounted || action == null) {
    return;
  }
  if (action == 'rename') {
    await _renameSession(context, session);
  } else if (action == 'privacy') {
    await chat.toggleSessionPrivacy(session.id);
  } else if (action == 'delete') {
    final bool ok = await showConfirmDialog(
      context,
      title: '删除会话',
      message: '「${session.title}」及其全部消息将被删除，且无法恢复。',
      confirmText: '删除',
      danger: true,
    );
    if (ok) {
      await chat.deleteSession(session.id);
    }
  }
}

Future<void> _renameSession(BuildContext context, ChatSession session) async {
  final TextEditingController controller =
      TextEditingController(text: session.title);
  final String? value = await showDialog<String>(
    context: context,
    builder: (BuildContext context) {
      return AlertDialog(
        title: const Text('重命名会话'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 40,
          decoration: const InputDecoration(hintText: '输入新的会话名称'),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('保存'),
          ),
        ],
      );
    },
  );
  controller.dispose();
  if (value != null && context.mounted) {
    await context.read<ChatController>().renameSession(session.id, value);
  }
}

Future<void> showMessageActions(
  BuildContext context,
  ChatMessage message,
) async {
  final AppColors c = context.colors;
  final ChatController chat = context.read<ChatController>();
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
                message.isUser ? '用户消息' : '助手回复',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: c.textTitle,
                ),
              ),
              const SizedBox(height: 12),
              _ActionRow(
                badge: '复',
                title: '复制内容',
                description: '复制该条消息的正文',
                onTap: () => Navigator.of(context).pop('copy'),
              ),
              if (message.isUser)
                _ActionRow(
                  badge: '编',
                  title: '编辑并重发',
                  description: '保留原消息，从该节点生成新的分支',
                  onTap: () => Navigator.of(context).pop('edit'),
                ),
              if (message.isAssistant)
                _ActionRow(
                  badge: '再',
                  title: '重新生成',
                  description: '基于同一条提问生成新的回复分支',
                  onTap: () => Navigator.of(context).pop('regenerate'),
                ),
            ],
          ),
        ),
      );
    },
  );
  if (!context.mounted || action == null) {
    return;
  }
  if (action == 'copy') {
    await Clipboard.setData(ClipboardData(text: message.content));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已复制到剪贴板')),
      );
    }
  } else if (action == 'edit') {
    await _editMessage(context, message);
  } else if (action == 'regenerate') {
    await chat.regenerate(message.id);
  }
}

Future<void> _editMessage(BuildContext context, ChatMessage message) async {
  final TextEditingController controller =
      TextEditingController(text: message.content);
  final String? value = await showDialog<String>(
    context: context,
    builder: (BuildContext context) {
      return AlertDialog(
        title: const Text('编辑并重发'),
        content: TextField(
          controller: controller,
          autofocus: true,
          minLines: 3,
          maxLines: 8,
          decoration: const InputDecoration(hintText: '修改消息内容'),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('发送'),
          ),
        ],
      );
    },
  );
  controller.dispose();
  if (value != null && context.mounted) {
    await context.read<ChatController>().editAndResend(message.id, value);
  }
}

Future<void> showBindSheet(BuildContext context) async {
  await showCharacterSheet(context);
}

Future<void> showCharacterSheet(
  BuildContext context, {
  bool manage = false,
}) async {
  final AppColors c = context.colors;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: c.surface,
    builder: (BuildContext context) {
      return FractionallySizedBox(
        heightFactor: manage ? 0.82 : 0.72,
        child: _CharacterSheet(manage: manage),
      );
    },
  );
}

class _CharacterSheet extends StatefulWidget {
  const _CharacterSheet({required this.manage});

  final bool manage;

  @override
  State<_CharacterSheet> createState() => _CharacterSheetState();
}

class _CharacterSheetState extends State<_CharacterSheet> {
  String _selectedCharacter = '';
  String _selectedIdentity = '';

  @override
  Widget build(BuildContext context) {
    final AppColors c = context.colors;
    final ChatController chat = context.watch<ChatController>();
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(
                widget.manage ? '角色管理' : '选择角色',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: c.textTitle,
                ),
              ),
              const Spacer(),
              InkWell(
                onTap: () async {
                  final CharacterCard? created =
                      await _showCharacterEdit(context);
                  if (created != null && mounted) {
                    setState(() => _selectedCharacter = created.id);
                  }
                },
                child: Text(
                  '+ 新建角色',
                  style: TextStyle(fontSize: 12, color: c.accent),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: ListView(
              children: <Widget>[
                if (chat.characters.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Center(
                      child: Text(
                        '还没有角色卡，点击右上角新建',
                        style: TextStyle(fontSize: 13, color: c.textMuted),
                      ),
                    ),
                  )
                else
                  ...chat.characters.map((CharacterCard card) {
                    final bool selected = _selectedCharacter == card.id;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: () async {
                          if (widget.manage) {
                            await _showCharacterEdit(context, card: card);
                          } else {
                            setState(() => _selectedCharacter = card.id);
                          }
                        },
                        onLongPress: widget.manage
                            ? () => _confirmDeleteCharacter(context, card)
                            : null,
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: selected && !widget.manage
                                ? c.accentSoftSelected
                                : c.surfaceRow,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: selected && !widget.manage
                                  ? c.accentOutline
                                  : Colors.transparent,
                            ),
                          ),
                          child: Row(
                            children: <Widget>[
                              CircleAvatar(
                                radius: 18,
                                backgroundColor: c.iconTile,
                                child: Text(
                                  card.name.characters.first,
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: c.accent,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: <Widget>[
                                    Text(
                                      card.name,
                                      style: TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w500,
                                        color: c.textPrimary,
                                      ),
                                    ),
                                    if (card.systemPrompt.isNotEmpty)
                                      Text(
                                        card.systemPrompt,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: c.textMuted,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                              if (!widget.manage)
                                Icon(
                                  selected
                                      ? Icons.radio_button_checked_rounded
                                      : Icons.radio_button_off_rounded,
                                  size: 20,
                                  color: selected ? c.accent : c.iconMuted,
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
                    );
                  }),
                const SizedBox(height: 18),
                Row(
                  children: <Widget>[
                    Text(
                      '我的身份（可选）',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: c.textSecondary,
                      ),
                    ),
                    const Spacer(),
                    InkWell(
                      onTap: () => _showIdentityEdit(context),
                      child: Text(
                        '+ 新建身份',
                        style: TextStyle(fontSize: 12, color: c.accent),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (chat.identities.isEmpty)
                  Text(
                    '未设置身份时，按普通用户对话',
                    style: TextStyle(fontSize: 12, color: c.textMuted),
                  )
                else
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: <Widget>[
                      _ChoiceChip(
                        label: '不扮演',
                        selected: _selectedIdentity.isEmpty,
                        onTap: () =>
                            setState(() => _selectedIdentity = ''),
                      ),
                      ...chat.identities.map((UserIdentityCard identity) {
                        final bool selected =
                            _selectedIdentity == identity.id;
                        return GestureDetector(
                          onLongPress: widget.manage
                              ? () => _confirmDeleteIdentity(
                                    context,
                                    identity,
                                  )
                              : null,
                          child: _ChoiceChip(
                            label: identity.name,
                            selected: selected,
                            onTap: () => setState(
                              () => _selectedIdentity = identity.id,
                            ),
                          ),
                        );
                      }),
                    ],
                  ),
              ],
            ),
          ),
          if (!widget.manage)
            Row(
              children: <Widget>[
                Expanded(
                  child: SizedBox(
                    height: 46,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: c.fill,
                        foregroundColor: c.textPrimary,
                      ),
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('跳过'),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: SizedBox(
                    height: 46,
                    child: ElevatedButton(
                      onPressed: _selectedCharacter.isEmpty
                          ? null
                          : () async {
                              await chat.bindDraftParticipants(
                                characterId: _selectedCharacter,
                                identityId: _selectedIdentity,
                              );
                              if (context.mounted) {
                                Navigator.of(context).pop();
                              }
                            },
                      child: const Text('开始对话'),
                    ),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Future<CharacterCard?> _showCharacterEdit(
    BuildContext context, {
    CharacterCard? card,
  }) async {
    final ChatController chat = context.read<ChatController>();
    final TextEditingController name =
        TextEditingController(text: card?.name ?? '');
    final TextEditingController prompt = TextEditingController(
      text: card?.systemPrompt ?? '',
    );
    final TextEditingController first = TextEditingController(
      text: card?.firstMessage ?? '',
    );
    double temperature = card?.temperature ?? 0.7;
    final bool? saved = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setState) {
            return AlertDialog(
              title: Text(card == null ? '新建角色' : '编辑角色'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    TextField(
                      controller: name,
                      autofocus: true,
                      decoration: const InputDecoration(
                        labelText: '角色名称',
                        hintText: '',
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: prompt,
                      minLines: 3,
                      maxLines: 6,
                      decoration: const InputDecoration(
                        labelText: '系统设定',
                        hintText: '角色的身份、语气与行为边界',
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: first,
                      minLines: 2,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        labelText: '开场白（可选）',
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: <Widget>[
                        Text(
                          '温度 ${temperature.toStringAsFixed(1)}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        Expanded(
                          child: Slider(
                            value: temperature,
                            min: 0,
                            max: 1.5,
                            divisions: 15,
                            onChanged: (double value) =>
                                setState(() => temperature = value),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('取消'),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('保存'),
                ),
              ],
            );
          },
        );
      },
    );
    CharacterCard? result;
    if (saved == true) {
      try {
        result = await chat.saveCharacter(
          id: card?.id,
          name: name.text,
          systemPrompt: prompt.text,
          firstMessage: first.text,
          temperature: temperature,
        );
      } on FormatException catch (error) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(error.message)),
          );
        }
      }
    }
    name.dispose();
    prompt.dispose();
    first.dispose();
    return result;
  }

  Future<void> _showIdentityEdit(
    BuildContext context, {
    UserIdentityCard? identity,
  }) async {
    final ChatController chat = context.read<ChatController>();
    final TextEditingController name =
        TextEditingController(text: identity?.name ?? '');
    final TextEditingController persona =
        TextEditingController(text: identity?.persona ?? '');
    final bool? saved = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text(identity == null ? '新建身份' : '编辑身份'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                TextField(
                  controller: name,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: '身份名称'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: persona,
                  minLines: 3,
                  maxLines: 6,
                  decoration: const InputDecoration(
                    labelText: '身份背景 / 性格',
                  ),
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('保存'),
            ),
          ],
        );
      },
    );
    if (saved == true) {
      await chat.saveIdentity(
        id: identity?.id,
        name: name.text,
        persona: persona.text,
      );
    }
    name.dispose();
    persona.dispose();
  }

  Future<void> _confirmDeleteCharacter(
    BuildContext context,
    CharacterCard card,
  ) async {
    final bool ok = await showConfirmDialog(
      context,
      title: '删除角色',
      message: '「${card.name}」将从角色列表中移除。',
      confirmText: '删除',
      danger: true,
    );
    if (ok && context.mounted) {
      await context.read<ChatController>().deleteCharacter(card.id);
    }
  }

  Future<void> _confirmDeleteIdentity(
    BuildContext context,
    UserIdentityCard identity,
  ) async {
    final bool ok = await showConfirmDialog(
      context,
      title: '删除身份',
      message: '「${identity.name}」将从身份列表中移除。',
      confirmText: '删除',
      danger: true,
    );
    if (ok && context.mounted) {
      await context.read<ChatController>().deleteIdentity(identity.id);
    }
  }
}

class _ChoiceChip extends StatelessWidget {
  const _ChoiceChip({
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
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? c.accentSolid : c.fill,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: selected ? c.accentContrast : c.textPrimary,
          ),
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({
    required this.text,
    required this.color,
    required this.background,
  });

  final String text;
  final Color color;
  final Color background;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 10, color: color),
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({
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
                      style: TextStyle(
                        fontSize: 12,
                        color: c.textMuted,
                      ),
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
