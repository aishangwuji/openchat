import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_colors.dart';
import '../../core/utils/session_groups.dart';
import '../../data/models/chat_models.dart';
import '../../state/chat_controller.dart';
import '../widgets/message_bubble.dart';
import 'dart:async';
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
  bool _showJumpBottom = false;
  final AudioRecorder _recorder = AudioRecorder();
  bool _recording = false;
  bool _recordBusy = false;
  /// 语音识别中（录音已结束、等转写返回）。
  bool _transcribing = false;
  /// 本次录音已录秒数，录音中每 500ms 刷新。
  int _recordSeconds = 0;
  /// 当前音量（0~1，由振幅 dBFS 归一化），驱动录音波形。
  double _recordLevel = 0;
  Timer? _recordTimer;
  StreamSubscription<Amplitude>? _amplitudeSub;
  /// 录音/转写操作代号：取消后旧回调按代号丢弃，避免晚到的结果污染输入框。
  int _recordOp = 0;
  DateTime _recordStartedAt = DateTime.now();
  int _lastPathLength = 0;

  @override
  void initState() {
    super.initState();
    // 输入内容变化时切换「语音 / 发送」按钮，并让输入卡高度自适应。
    _input.addListener(_onInputChanged);
  }

  void _onInputChanged() {
    if (mounted) {
      setState(() {});
    }
  }

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
    _input.removeListener(_onInputChanged);
    _input.dispose();
    _recordTimer?.cancel();
    _amplitudeSub?.cancel();
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
    final ChatController chat = context.read<ChatController>();
    // 允许「只发文件/图片」：有附件时文字可以留空，由服务端只拼 file 块。
    if (text.isEmpty && chat.pendingAttachments.isEmpty) {
      return;
    }
    _input.clear();
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

  /// 顶栏参考官方：左侧菜单、右侧模型选择，只有已有消息时才显示会话标题。
  Widget _buildHeader(BuildContext context, ChatController chat) {
    final AppColors c = context.colors;
    final bool hasModel =
        chat.currentModelId.isNotEmpty && chat.currentModelId != '选择模型';
    final bool hasMessages = chat.activePath.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      child: Row(
        children: <Widget>[
          InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: () => _scaffoldKey.currentState?.openDrawer(),
            child: SizedBox(
              width: 40,
              height: 40,
              child: Icon(
                Icons.menu_rounded,
                size: 24,
                color: c.textPrimary,
              ),
            ),
          ),
          Expanded(
            child: hasMessages
                ? Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text(
                      chat.sessionTitle,
                      maxLines: 1,
                      textAlign: TextAlign.center,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: c.textTitle,
                      ),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
          InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () => showModelPicker(context),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              constraints: const BoxConstraints(maxWidth: 150),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Flexible(
                    child: Text(
                      hasModel ? chat.currentModelId : '选择模型',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                        color: hasModel ? c.textSecondary : c.accent,
                      ),
                    ),
                  ),
                  const SizedBox(width: 2),
                  Icon(
                    Icons.keyboard_arrow_down_rounded,
                    size: 16,
                    color: c.textMuted,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

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

  /// 首屏问候：参考官方首页——品牌标记 + 一句话，不放标语/副标题。
  String _greeting() {
    final int hour = DateTime.now().hour;
    if (hour < 6) {
      return '夜深了，想聊点什么？';
    }
    if (hour < 12) {
      return '早上好，今天想做点什么？';
    }
    if (hour < 18) {
      return '下午好，今天想做点什么？';
    }
    return '晚上好，今天想做点什么？';
  }

  Widget _buildEmptyState(AppColors c) {
    return Align(
      alignment: const Alignment(0, -0.28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Image.asset(
            'assets/providers/deepseek.png',
            width: 44,
            height: 44,
          ),
          const SizedBox(height: 18),
          Text(
            _greeting(),
            style: TextStyle(
              fontSize: 16.5,
              fontWeight: FontWeight.w600,
              color: c.textTitle,
            ),
          ),
        ],
      ),
    );
  }

  /// 语音输入：点一下开始录音、再点一下停止并转写。
  Future<void> _toggleRecord(ChatController chat) async {
    if (_recordBusy && !_transcribing) {
      return;
    }
    if (_transcribing) {
      // 转写中再点一次 = 取消：递增代号让在途结果被丢弃。
      _recordOp++;
      setState(() => _transcribing = false);
      return;
    }
    if (_recording) {
      await _finishRecording(chat, cancel: false);
      return;
    }
    await _startRecording(chat);
  }

  Future<void> _startRecording(ChatController chat) async {
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
      final int op = ++_recordOp;
      _recordStartedAt = DateTime.now();
      setState(() {
        _recording = true;
        _recordSeconds = 0;
        _recordLevel = 0;
      });
      _recordTimer?.cancel();
      _recordTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
        if (!mounted || op != _recordOp || !_recording) {
          return;
        }
        final int seconds =
            DateTime.now().difference(_recordStartedAt).inSeconds;
        setState(() => _recordSeconds = seconds);
        if (seconds >= AsrService.maxDurationSeconds) {
          _recordTimer?.cancel();
          _recordTimer = null;
          _showSnack('录音已达 ${AsrService.maxDurationSeconds} 秒上限，正在识别');
          unawaited(_finishRecording(chat, cancel: false));
        }
      });
      await _amplitudeSub?.cancel();
      // 振幅用于录音波形：dBFS 常见 -60~0，归一到 0~1 再画。
      _amplitudeSub =
          _recorder.onAmplitudeChanged(const Duration(milliseconds: 120)).listen(
        (Amplitude amp) {
          if (!mounted || op != _recordOp) {
            return;
          }
          final double level = ((amp.current + 60) / 60).clamp(0.0, 1.0);
          setState(() => _recordLevel = level);
        },
      );
    } catch (error) {
      _showSnack('录音启动失败：$error');
    }
  }

  /// 结束录音并转写；[cancel] 为真时只丢弃录音、不请求识别。
  Future<void> _finishRecording(
    ChatController chat, {
    required bool cancel,
  }) async {
    if (!_recording) {
      return;
    }
    final int op = ++_recordOp;
    _recordTimer?.cancel();
    _recordTimer = null;
    await _amplitudeSub?.cancel();
    _amplitudeSub = null;
    if (mounted) {
      setState(() {
        _recording = false;
        _recordLevel = 0;
      });
    }
    String? path;
    try {
      path = await _recorder.stop();
    } catch (_) {
      path = null;
    }
    if (cancel) {
      if (path != null) {
        try {
          await File(path).delete();
        } catch (_) {
          // 临时文件删不掉不影响对话。
        }
      }
      return;
    }
    if (path == null) {
      _showSnack('录音失败，请重试');
      return;
    }
    if (mounted) {
      setState(() {
        _transcribing = true;
        _recordBusy = true;
      });
    }
    try {
      final Uint8List bytes = await File(path).readAsBytes();
      final String text = await AsrService.transcribe(
        apiKey: chat.currentApiKey,
        wavBytes: bytes,
      );
      if (!mounted || op != _recordOp) {
        return;
      }
      if (text.trim().isEmpty) {
        _showSnack('没有识别到语音内容');
        return;
      }
      setState(() {
        final String current = _input.text.trim();
        // 识别结果追加在已有草稿后面（此前会把草稿整体替换成一个空格）。
        _input.text = current.isEmpty ? text.trim() : '$current ${text.trim()}';
        _input.selection =
            TextSelection.collapsed(offset: _input.text.length);
      });
    } on AsrException catch (error) {
      if (op == _recordOp) {
        _showSnack(error.message);
      }
    } catch (error) {
      if (op == _recordOp) {
        _showSnack('语音识别失败：$error');
      }
    } finally {
      if (mounted) {
        setState(() {
          _recordBusy = false;
          _transcribing = false;
        });
      }
      try {
        await File(path).delete();
      } catch (_) {
        // 忽略清理失败。
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
  /// 输入区内联小图标按钮：统一 40×44 点击区、22 图标、无多余底色。
  Widget _composerButton({
    required IconData icon,
    required String tooltip,
    required Color color,
    VoidCallback? onTap,
    bool busy = false,
  }) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onTap,
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 40, minHeight: 44),
      icon: busy
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(icon, size: 22, color: color),
    );
  }

  Widget _buildInputArea(BuildContext context, ChatController chat) {
    final AppColors c = context.colors;
    // Edge-to-edge 下底部手势条会盖住内容：SafeArea(bottom:false) 之后，
    // 由输入卡片自己补 viewPadding。键盘弹出时底部 inset 已被键盘占据，不再叠加。
    final MediaQueryData mq = MediaQuery.of(context);
    final double bottomInset =
        mq.viewInsets.bottom > 0 ? 0 : mq.viewPadding.bottom;
    final bool hasText = _input.text.trim().isNotEmpty;
    final bool canSend = hasText || chat.pendingAttachments.isNotEmpty;
    return Padding(
      padding: EdgeInsets.fromLTRB(12, 6, 12, 8 + bottomInset),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 12, 10),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: c.borderSoft),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 18,
              offset: const Offset(0, 4),
            ),
          ],
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
                        label: Text(
                          att.fileName,
                          style: const TextStyle(fontSize: 12),
                        ),
                        onDeleted: () =>
                            chat.removePendingAttachment(att.fileId),
                        visualDensity: VisualDensity.compact,
                      ),
                  ],
                ),
              ),
            if (_recording)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _RecordStatusBar(
                  seconds: _recordSeconds,
                  level: _recordLevel,
                  onCancel: () => _finishRecording(chat, cancel: true),
                ),
              ),
            if (_transcribing)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _TranscribingBar(
                  onCancel: () {
                    _recordOp++;
                    setState(() => _transcribing = false);
                  },
                ),
              ),
            TextField(
              controller: _input,
              minLines: 2,
              maxLines: 6,
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.newline,
              style: TextStyle(
                fontSize: 15,
                height: 1.5,
                color: c.textPrimary,
              ),
              decoration: InputDecoration(
                hintText: '输入您的问题...',
                hintStyle: TextStyle(
                  fontSize: 14,
                  color: c.textFaint,
                ),
                isDense: true,
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: 6),
              ),
            ),
            const SizedBox(height: 4),
            Row(
              children: <Widget>[
                ThinkingButton(
                  enabled: chat.enableThinking,
                  providerId: chat.currentProviderId,
                  modelId: chat.currentModelId,
                  onToggle: chat.setEnableThinking,
                ),
                const SizedBox(width: 6),
                WebSearchButton(
                  enabled: chat.enableWebSearch,
                  providerId: chat.currentProviderId,
                  onToggle: chat.setEnableWebSearch,
                ),
                const Spacer(),
                _composerButton(
                  icon: Icons.add_rounded,
                  tooltip: '添加文件或图片',
                  color: c.textPrimary,
                  busy: chat.attachmentBusy,
                  onTap: chat.attachmentBusy
                      ? null
                      : () => _pickAttachment(context, chat),
                ),
                if (chat.isGenerating)
                  _composerButton(
                    icon: Icons.stop_rounded,
                    tooltip: '停止生成',
                    color: c.dangerText,
                    onTap: chat.stopGenerating,
                  )
                else if (canSend)
                  SizedBox(
                    width: 36,
                    height: 36,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        shape: const CircleBorder(),
                        elevation: 0,
                        padding: EdgeInsets.zero,
                      ),
                      onPressed: _send,
                      child: const Icon(
                        Icons.arrow_upward_rounded,
                        size: 18,
                      ),
                    ),
                  )
                else if (chat.featureAsr)
                  _composerButton(
                    icon: _recording
                        ? Icons.stop_circle_outlined
                        : _transcribing
                            ? Icons.close_rounded
                            : Icons.graphic_eq_rounded,
                    tooltip: _recording
                        ? '停止录音'
                        : _transcribing
                            ? '取消识别'
                            : '语音输入',
                    color: _recording ? c.dangerText : c.textPrimary,
                    busy: _recordBusy && !_transcribing,
                    onTap: _recordBusy && !_transcribing
                        ? null
                        : () => _toggleRecord(chat),
                  ),
              ],
            ),
          ],
        ),
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

/// 录音中的状态条：呼吸红点 + 计时 + 音量波形 + 取消。
///
/// 对齐官方客户端的「录音中 Ns」语义：录音是显式进行中的状态，
/// 必须有停止之外的取消出口，否则误触只能等识别完。
class _RecordStatusBar extends StatefulWidget {
  const _RecordStatusBar({
    required this.seconds,
    required this.level,
    required this.onCancel,
  });

  final int seconds;
  final double level;
  final VoidCallback onCancel;

  @override
  State<_RecordStatusBar> createState() => _RecordStatusBarState();
}

class _RecordStatusBarState extends State<_RecordStatusBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppColors c = context.colors;
    final int minutes = widget.seconds ~/ 60;
    final int seconds = widget.seconds % 60;
    final String clock =
        '$minutes:${seconds.toString().padLeft(2, '0')}';
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: c.borderSoft),
      ),
      child: Row(
        children: <Widget>[
          FadeTransition(
            opacity: _pulse.drive(Tween<double>(begin: 0.35, end: 1)),
            child: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: c.dangerText,
                shape: BoxShape.circle,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '录音中 $clock',
            style: TextStyle(fontSize: 12.5, color: c.textPrimary),
          ),
          const SizedBox(width: 10),
          _LevelBars(level: widget.level),
          const Spacer(),
          TextButton(
            onPressed: widget.onCancel,
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              minimumSize: const Size(0, 30),
              padding: const EdgeInsets.symmetric(horizontal: 10),
            ),
            child: Text(
              '取消',
              style: TextStyle(fontSize: 12, color: c.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

/// 识别中的状态条：转圈 + 提示 + 取消（取消后晚到的结果会被丢弃）。
class _TranscribingBar extends StatelessWidget {
  const _TranscribingBar({required this.onCancel});

  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final AppColors c = context.colors;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: c.borderSoft),
      ),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2, color: c.accent),
          ),
          const SizedBox(width: 8),
          Text(
            '正在识别语音…',
            style: TextStyle(fontSize: 12.5, color: c.textPrimary),
          ),
          const Spacer(),
          TextButton(
            onPressed: onCancel,
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              minimumSize: const Size(0, 30),
              padding: const EdgeInsets.symmetric(horizontal: 10),
            ),
            child: Text(
              '取消',
              style: TextStyle(fontSize: 12, color: c.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

/// 录音音量条：五根柱子，高度由当前振幅（0~1）与固定相位权重决定。
class _LevelBars extends StatelessWidget {
  const _LevelBars({required this.level});

  final double level;

  static const List<double> _weights = <double>[0.5, 0.85, 1.0, 0.7, 0.45];

  @override
  Widget build(BuildContext context) {
    final AppColors c = context.colors;
    return SizedBox(
      width: 46,
      height: 16,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          for (int i = 0; i < _weights.length; i++)
            AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: 4,
              height: 3 + 13 * (_weights[i] * level).clamp(0.0, 1.0),
              decoration: BoxDecoration(
                color: c.accent,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
        ],
      ),
    );
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
