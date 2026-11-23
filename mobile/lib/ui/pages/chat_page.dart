import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_colors.dart';
import '../../core/utils/session_groups.dart';
import '../../data/models/chat_models.dart';
import '../../state/chat_controller.dart';
import '../widgets/message_bubble.dart';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../../data/services/asr_service.dart';

import '../widgets/thinking_button.dart';
import '../widgets/web_search_button.dart';
import 'chat_sheets.dart';
import 'settings_page.dart';

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  ChatController? _chat;
  bool _inputExpanded = false;
  bool _showJumpBottom = false;
  final AudioRecorder _recorder = AudioRecorder();
  bool _recording = false;
  bool _recordBusy = false;
  int _lastPathLength = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ChatController chat = context.read<ChatController>();
    if (!identical(_chat, chat)) {
      _chat?.removeListener(_onChatChanged);
      _chat = chat;
      _chat!.addListener(_onChatChanged);
      _scroll.addListener(_onScroll);
    }
  }

  @override
  void dispose() {
    _chat?.removeListener(_onChatChanged);
    _scroll
      ..removeListener(_onScroll)
      ..dispose();
    _input.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) {
      return;
    }
    final bool away = _scroll.offset <
        _scroll.position.maxScrollExtent - 80;
    if (away != _showJumpBottom) {
      setState(() => _showJumpBottom = away);
    }
  }

  void _onChatChanged() {
    final ChatController? chat = _chat;
    if (chat == null) {
      return;
    }
    final int length = chat.activePath.length;
    final bool grew = length > _lastPathLength;
    _lastPathLength = length;
    if (!_scroll.hasClients) {
      return;
    }
    final bool nearBottom =
        _scroll.offset >= _scroll.position.maxScrollExtent - 200;
    if (grew || (chat.isGenerating && nearBottom)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    }
  }

  void _scrollToBottom() {
    if (!_scroll.hasClients) {
      return;
    }
    _scroll.animateTo(
      _scroll.position.maxScrollExtent,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
    );
  }

  Future<void> _send() async {
    final String text = _input.text.trim();
    if (text.isEmpty) {
      return;
    }
    final ChatController chat = context.read<ChatController>();
    _input.clear();
    setState(() => _inputExpanded = false);
    await chat.sendMessage(text);
    _scrollToBottom();
  }

  @override
  Widget build(BuildContext context) {
    final AppColors c = context.colors;
    final ChatController chat = context.watch<ChatController>();
    final List<ChatMessage> path = chat.activePath;
    _lastPathLength = path.length;
    final ChatSession? session = chat.currentSession;
    final String identityName = session == null
        ? ''
        : (chat.identityById(session.userIdentityId)?.name ?? '');

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: c.surface,
      drawer: _SessionDrawer(
        onNewSession: _startNewSession,
        onOpenSettings: () => _openSettings(context),
        onOpenCharacters: () => showCharacterSheet(context, manage: true),
      ),
      body: SafeArea(
        bottom: false,
        child: Column(
          children: <Widget>[
            _buildHeader(context, chat),
            if (chat.noticeText.isNotEmpty) _buildNotice(c, chat),
            Divider(color: c.borderSoft, height: 1),
            Expanded(
              child: Stack(
                children: <Widget>[
                  path.isEmpty
                      ? _buildEmptyState(c)
                      : ListView.builder(
                          controller: _scroll,
                          padding: const EdgeInsets.fromLTRB(18, 12, 18, 12),
                          itemCount: path.length,
                          itemBuilder: (BuildContext context, int index) {
                            final ChatMessage message = path[index];
                            return Padding(
                              padding:
                                  const EdgeInsets.symmetric(vertical: 10),
                              child: MessageBubble(
                                key: ValueKey<String>(message.id),
                                message: message,
                                controller: chat,
                                identityName:
                                    message.isUser ? identityName : '',
                                speakerName: message.isAssistant
                                    ? (chat.characterById(message.speakerId)
                                            ?.name ??
                                        '')
                                    : '',
                                onLongPress: () =>
                                    showMessageActions(context, message),
                                onBranchChange: (int delta) => chat
                                    .switchBranch(message.id, delta),
                              ),
                            );
                          },
                        ),
                  if (_showJumpBottom)
                    Positioned(
                      right: 16,
                      bottom: 12,
                      child: _JumpBottomButton(
                        onTap: () {
                          _scrollToBottom();
                          setState(() => _showJumpBottom = false);
                        },
                      ),
                    ),
                ],
              ),
            ),
            _buildInputArea(context, chat),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, ChatController chat) {
    final AppColors c = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
      child: Row(
        children: <Widget>[
          InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: () => _scaffoldKey.currentState?.openDrawer(),
            child: Container(
              width: 36,
              height: 36,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: c.fill,
                borderRadius: BorderRadius.circular(18),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  _bar(c.textPrimary),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: _bar(c.textPrimary),
                  ),
                  _bar(c.textPrimary),
                ],
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Column(
                children: <Widget>[
                  Text(
                    chat.sessionTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: c.textTitle,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    chat.providerName,
                    style: TextStyle(fontSize: 10, color: c.textMuted),
                  ),
                ],
              ),
            ),
          ),
          InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () => showModelPicker(context),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: c.accentSoft,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: c.accentOutline),
              ),
              constraints: const BoxConstraints(maxWidth: 150),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Flexible(
                    child: Text(
                      chat.currentModelId.isEmpty
                          ? '选择模型'
                          : chat.currentModelId,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: c.accent,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '选模型',
                    style: TextStyle(fontSize: 10, color: c.textMuted),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _bar(Color color) => Container(
        width: 16,
        height: 2,
        color: color,
      );

  Widget _buildNotice(AppColors c, ChatController chat) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: chat.clearNotice,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: c.dangerFill,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Text(
            chat.noticeText,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: c.dangerText),
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState(AppColors c) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(width: 24, height: 1, color: c.accent),
              Text(
                '  BALANCE  /  AI',
                style: TextStyle(
                  fontSize: 10,
                  letterSpacing: 1.2,
                  fontWeight: FontWeight.w500,
                  color: c.accent,
                ),
              ),
              Container(width: 24, height: 1, color: c.accent),
            ],
          ),
          const SizedBox(height: 20),
          Text(
            '让想法慢慢展开',
            style: TextStyle(
              fontSize: 27,
              fontWeight: FontWeight.w500,
              color: c.textTitle,
            ),
          ),
          const SizedBox(height: 9),
          Text(
            '从一个问题开始，开启一段清晰的对话。',
            style: TextStyle(
              fontSize: 14,
              height: 1.64,
              color: c.textMuted,
            ),
          ),
        ],
      ),
    );
  }

  /// 语音输入：点一下开始录音、再点一下停止并转写。
  Future<void> _toggleRecord(ChatController chat) async {
    if (_recordBusy) {
      return;
    }
    if (!_recording) {
      try {
        if (!await _recorder.hasPermission()) {
          _showSnack('没有麦克风权限，请在系统设置中开启');
          return;
        }
        final Directory dir = await getTemporaryDirectory();
        final String path =
            '${dir.path}/asr_${DateTime.now().millisecondsSinceEpoch}.wav';
        await _recorder.start(
          const RecordConfig(
            encoder: AudioEncoder.wav,
            sampleRate: 16000,
            numChannels: 1,
          ),
          path: path,
        );
        if (!mounted) {
          return;
        }
        setState(() => _recording = true);
      } catch (error) {
        _showSnack('录音启动失败：');
      }
      return;
    }
    setState(() {
      _recording = false;
      _recordBusy = true;
    });
    try {
      final String? path = await _recorder.stop();
      if (path == null) {
        return;
      }
      final Uint8List bytes = await File(path).readAsBytes();
      final String text = await AsrService.transcribe(
        apiKey: chat.currentApiKey,
        wavBytes: bytes,
      );
      if (!mounted) {
        return;
      }
      if (text.isEmpty) {
        _showSnack('没有识别到语音内容');
        return;
      }
      setState(() {
        final String current = _input.text.trim();
        _input.text = current.isEmpty ? text : ' ';
        _input.selection =
            TextSelection.collapsed(offset: _input.text.length);
      });
    } on AsrException catch (error) {
      _showSnack(error.message);
    } catch (error) {
      _showSnack('语音识别失败：');
    } finally {
      if (mounted) {
        setState(() => _recordBusy = false);
      }
    }
  }

  void _showSnack(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }
  /// 选择并上传附件：文件 / 相册 / 拍照，统一走 FileUploadService。
  Future<void> _pickAttachment(
    BuildContext context,
    ChatController chat,
  ) async {
    final String? kind = await showModalBottomSheet<String>(
      context: context,
      builder: (BuildContext ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              leading: const Icon(Icons.description_outlined),
              title: const Text('选择文件'),
              onTap: () => Navigator.of(ctx).pop('file'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('从相册选择'),
              onTap: () => Navigator.of(ctx).pop('gallery'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('拍照'),
              onTap: () => Navigator.of(ctx).pop('camera'),
            ),
          ],
        ),
      ),
    );
    if (kind == null) {
      return;
    }
    String? fileName;
    Uint8List? bytes;
    try {
      if (kind == 'file') {
        final PlatformFile? file = await FilePicker.pickFile();
        if (file == null) {
          return;
        }
        fileName = file.name;
        bytes = await file.readAsBytes();
      } else {
        final XFile? picked = await ImagePicker().pickImage(
          source: kind == 'camera' ? ImageSource.camera : ImageSource.gallery,
          imageQuality: 90,
        );
        if (picked == null) {
          return;
        }
        fileName = picked.name;
        bytes = await picked.readAsBytes();
      }
    } catch (error) {
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('选择附件失败：$error')),
      );
      return;
    }
    await chat.uploadPendingAttachment(fileName: fileName, bytes: bytes);
  }
  Widget _buildInputArea(BuildContext context, ChatController chat) {
    final AppColors c = context.colors;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(top: BorderSide(color: c.borderSoft)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (chat.pendingAttachments.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: <Widget>[
                  for (final MessageAttachment att in chat.pendingAttachments)
                    InputChip(
                      label:
                          Text(att.fileName, style: const TextStyle(fontSize: 12)),
                      onDeleted: () => chat.removePendingAttachment(att.fileId),
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
            ),
          Row(
            crossAxisAlignment: _inputExpanded
                ? CrossAxisAlignment.end
                : CrossAxisAlignment.center,
            children: <Widget>[
              if (chat.featureAsr)
                Padding(
                  padding: const EdgeInsets.only(right: 4, bottom: 6),
                  child: IconButton(
                    tooltip: _recording ? '停止录音' : '语音输入',
                    onPressed: _recordBusy ? null : () => _toggleRecord(chat),
                    icon: _recordBusy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(
                            _recording
                                ? Icons.stop_circle_outlined
                                : Icons.mic_none_rounded,
                            color: _recording ? c.dangerText : c.accent,
                          ),
                  ),
                ),              if (chat.attachmentBusy)
                const Padding(
                  padding: EdgeInsets.only(right: 8, bottom: 12),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.only(right: 8, bottom: 6),
                  child: IconButton(
                    tooltip: '添加文件或图片',
                    onPressed: () => _pickAttachment(context, chat),
                    icon: Icon(Icons.add_circle_outline_rounded, color: c.accent),
                  ),
                ),
              Expanded(
                child: Stack(
                  alignment: Alignment.bottomRight,
                  children: <Widget>[
                    TextField(
                      controller: _input,
                      minLines: _inputExpanded ? 4 : 2,
                      maxLines: _inputExpanded ? 10 : 2,
                      keyboardType: TextInputType.multiline,
                      textInputAction: TextInputAction.newline,
                      style: TextStyle(
                        fontSize: 15,
                        height: 1.5,
                        color: c.textPrimary,
                      ),
                      decoration: InputDecoration(
                        hintText: '输入您的问题...',
                        contentPadding: const EdgeInsets.fromLTRB(
                          16,
                          12,
                          46,
                          12,
                        ),
                        border: OutlineInputBorder(
                          borderRadius:
                              BorderRadius.circular(_inputExpanded ? 20 : 24),
                          borderSide: BorderSide(color: c.borderCard),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius:
                              BorderRadius.circular(_inputExpanded ? 20 : 24),
                          borderSide: BorderSide(color: c.borderCard),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius:
                              BorderRadius.circular(_inputExpanded ? 20 : 24),
                          borderSide: BorderSide(color: c.accentOutline),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(right: 10, bottom: 10),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(13),
                        onTap: () =>
                            setState(() => _inputExpanded = !_inputExpanded),
                        child: Container(
                          width: 26,
                          height: 26,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: c.iconTile,
                            borderRadius: BorderRadius.circular(13),
                            border: Border.all(color: c.accentOutline),
                          ),
                          child: Icon(
                            _inputExpanded
                                ? Icons.close_fullscreen_rounded
                                : Icons.open_in_full_rounded,
                            size: 14,
                            color: c.accent,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (chat.isGenerating)
                SizedBox(
                  width: 60,
                  height: 48,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: c.dangerText,
                      foregroundColor: Colors.white,
                      padding: EdgeInsets.zero,
                    ),
                    onPressed: chat.stopGenerating,
                    child: const Text(
                      '停止',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                )
              else
                SizedBox(
                  width: 48,
                  height: 48,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      shape: const CircleBorder(),
                      padding: EdgeInsets.zero,
                    ),
                    onPressed: _send,
                    child: const Icon(Icons.arrow_upward_rounded, size: 21),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              ThinkingButton(
                enabled: chat.enableThinking,
                providerId: chat.currentProviderId,
                modelId: chat.currentModelId,
                onToggle: chat.setEnableThinking,
              ),
              const SizedBox(width: 8),
              WebSearchButton(
                enabled: chat.enableWebSearch,
                providerId: chat.currentProviderId,
                onToggle: chat.setEnableWebSearch,
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _openSettings(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const SettingsPage()),
    );
  }

  /// Creates the draft, closes the drawer, then offers character binding on
  /// the page's own context (the drawer context is unmounted by then).
  void _startNewSession() {
    _scaffoldKey.currentState?.closeDrawer();
    context.read<ChatController>().createNewSession();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        showBindSheet(context);
      }
    });
  }
}

class _JumpBottomButton extends StatelessWidget {
  const _JumpBottomButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppColors c = context.colors;
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: c.accentOutline),
          boxShadow: const <BoxShadow>[
            BoxShadow(
              color: Color(0x1F231E14),
              blurRadius: 12,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              '↓',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: c.accent,
              ),
            ),
            const SizedBox(width: 4),
            Text(
              '回到底部',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: c.accent,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SessionDrawer extends StatefulWidget {
  const _SessionDrawer({
    required this.onNewSession,
    required this.onOpenSettings,
    required this.onOpenCharacters,
  });

  final VoidCallback onNewSession;
  final VoidCallback onOpenSettings;
  final VoidCallback onOpenCharacters;

  @override
  State<_SessionDrawer> createState() => _SessionDrawerState();
}

class _SessionDrawerState extends State<_SessionDrawer> {
  /// 会话标题过滤关键词（对齐鸿蒙端的「搜索会话内容」）。
  final TextEditingController _queryController = TextEditingController();

  @override
  void dispose() {
    _queryController.dispose();
    super.dispose();
  }

  /// 按标题过滤（大小写不敏感）；关键词为空时原样返回全量。
  List<ChatSession> _filteredSessions(List<ChatSession> sessions) {
    final String keyword = _queryController.text.trim().toLowerCase();
    if (keyword.isEmpty) {
      return sessions;
    }
    return sessions
        .where((ChatSession s) => s.title.toLowerCase().contains(keyword))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final AppColors c = context.colors;
    final ChatController chat = context.watch<ChatController>();
    final List<ChatSession> sessions = _filteredSessions(chat.sessions);
    return Drawer(
      width: MediaQuery.sizeOf(context).width * 0.82,
      backgroundColor: c.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.horizontal(right: Radius.circular(28)),
      ),
      child: SafeArea(
        child: Column(
          children: <Widget>[
            // 头部：搜索会话 + 新会话（与鸿蒙端同版式，对齐官方侧栏）
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Container(
                      height: 38,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        color: c.fill,
                        borderRadius: BorderRadius.circular(19),
                      ),
                      child: Row(
                        children: <Widget>[
                          Icon(
                            Icons.search_rounded,
                            size: 16,
                            color: c.iconMuted,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: TextField(
                              controller: _queryController,
                              onChanged: (String _) => setState(() {}),
                              textInputAction: TextInputAction.search,
                              style: TextStyle(
                                fontSize: 13,
                                color: c.textPrimary,
                              ),
                              decoration: InputDecoration(
                                isDense: true,
                                border: InputBorder.none,
                                hintText: '搜索会话内容',
                                hintStyle: TextStyle(
                                  fontSize: 13,
                                  color: c.textMuted,
                                ),
                                contentPadding: EdgeInsets.zero,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    height: 36,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(18),
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                      ),
                      onPressed: widget.onNewSession,
                      child: const Text(
                        '+ 新会话',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Divider(color: c.borderSoft, height: 1),
            Expanded(
              child: sessions.isEmpty
                  ? Center(
                      child: Text(
                        _queryController.text.trim().isEmpty
                            ? '还没有历史会话'
                            : '没有匹配的会话',
                        style: TextStyle(fontSize: 13, color: c.textMuted),
                      ),
                    )
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(4, 2, 4, 10),
                      children: _buildSessionList(context, c, chat, sessions),
                    ),
            ),
            Divider(color: c.borderSoft, height: 1),
            _DrawerRow(
              icon: Icons.people_outline_rounded,
              label: '角色管理',
              onTap: () {
                Navigator.of(context).pop();
                widget.onOpenCharacters();
              },
            ),
            _DrawerRow(
              icon: Icons.settings_outlined,
              label: '设置',
              onTap: () {
                Navigator.of(context).pop();
                widget.onOpenSettings();
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// 按时间线分组渲染：组标题 + 会话行（对齐官方侧栏的信息密度）。
  List<Widget> _buildSessionList(
    BuildContext context,
    AppColors c,
    ChatController chat,
    List<ChatSession> sessions,
  ) {
    final List<Widget> out = <Widget>[];
    for (final SessionGroup group in groupSessions(sessions)) {
      out.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
          child: Text(
            group.label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.2,
              color: c.textMuted,
            ),
          ),
        ),
      );
      for (final ChatSession session in group.sessions) {
        out.add(_sessionTile(context, c, chat, session));
      }
    }
    return out;
  }

  Widget _sessionTile(
    BuildContext context,
    AppColors c,
    ChatController chat,
    ChatSession session,
  ) {
    final bool selected = session.id == chat.currentSessionId;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () async {
          Navigator.of(context).pop();
          await chat.openSessionWithPrivacy(session);
        },
        onLongPress: () => showSessionActions(context, session),
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
          // 与官方一致：扁平行，只有选中项用色块浮起。
          decoration: BoxDecoration(
            color: selected ? c.accentSoftSelected : Colors.transparent,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: <Widget>[
              if (session.isPrivate)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Icon(
                    Icons.lock_outline_rounded,
                    size: 13,
                    color: c.accent,
                  ),
                ),
              Expanded(
                child: Text(
                  session.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    color: selected ? c.accent : c.textPrimary,
                  ),
                ),
              ),
              IconButton(
                tooltip: '更多',
                visualDensity: VisualDensity.compact,
                iconSize: 18,
                color: c.iconMuted,
                onPressed: () => showSessionActions(context, session),
                icon: const Icon(Icons.more_horiz_rounded),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DrawerRow extends StatelessWidget {
  const _DrawerRow({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppColors c = context.colors;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
        child: Row(
          children: <Widget>[
            Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: c.iconTile,
                borderRadius: BorderRadius.circular(17),
              ),
              child: Icon(icon, size: 18, color: c.accent),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  color: c.textPrimary,
                ),
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
    );
  }
}
