import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/app_colors.dart';
import '../../core/utils/markdown_utils.dart';
import '../../data/models/chat_models.dart';
import '../../data/services/file_upload_service.dart';
import '../../data/services/tts_service.dart';
import '../../state/chat_controller.dart';
import 'markdown_theme.dart';
import 'search_sources.dart';

class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.message,
    required this.controller,
    required this.identityName,
    required this.speakerName,
    required this.onLongPress,
    required this.onBranchChange,
  });

  final ChatMessage message;
  final ChatController controller;
  final String identityName;
  final String speakerName;
  final VoidCallback onLongPress;
  final ValueChanged<int> onBranchChange;

  @override
  Widget build(BuildContext context) {
    final AppColors c = context.colors;
    final bool streaming = message.status == MessageStatus.streaming;
    final bool user = message.isUser;
    final Widget body = user
        ? _UserBubble(message: message, identityName: identityName)
        : _AssistantBubble(
            message: message,
            controller: controller,
            speakerName: speakerName,
            streaming: streaming,
          );

    return Align(
      alignment: user ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onLongPress: onLongPress,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: user
                ? MediaQuery.sizeOf(context).width * 0.82
                : MediaQuery.sizeOf(context).width,
          ),
          child: Column(
            crossAxisAlignment:
                user ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: <Widget>[
              body,
              if (controller.branchCount(message) > 1)
                _BranchBar(
                  index: controller.branchIndex(message) + 1,
                  count: controller.branchCount(message),
                  onPrevious: () => onBranchChange(-1),
                  onNext: () => onBranchChange(1),
                  color: c,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _UserBubble extends StatelessWidget {
  const _UserBubble({required this.message, required this.identityName});

  final ChatMessage message;
  final String identityName;

  @override
  Widget build(BuildContext context) {
    final AppColors c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: <Widget>[
        if (identityName.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 4, right: 4),
            child: Text(
              identityName,
              style: TextStyle(fontSize: 10, color: c.textFaint),
            ),
          ),
        if (message.attachments.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 6, right: 2),
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: 6,
              runSpacing: 6,
              children: <Widget>[
                for (final MessageAttachment att in message.attachments)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                    decoration: BoxDecoration(
                      color: c.fill,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Icon(
                          FileUploadService.isImage(att.fileName)
                              ? Icons.image_outlined
                              : Icons.description_outlined,
                          size: 13,
                          color: c.textMuted,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          att.fileName,
                          style:
                              TextStyle(fontSize: 11, color: c.textSecondary),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        if (message.content.isNotEmpty)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: c.accentSoftSelected,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(20),
                topRight: Radius.circular(6),
                bottomLeft: Radius.circular(20),
                bottomRight: Radius.circular(20),
              ),
              border: Border.all(color: c.accentOutline),
            ),
            child: Text(
              message.content,
              style: TextStyle(
                fontSize: 15,
                height: 1.55,
                color: c.userBubbleText,
              ),
            ),
          ),
      ],
    );
  }
}

class _AssistantBubble extends StatelessWidget {
  const _AssistantBubble({
    required this.message,
    required this.controller,
    required this.speakerName,
    required this.streaming,
  });

  final ChatMessage message;
  final ChatController controller;
  final String speakerName;
  final bool streaming;

  @override
  Widget build(BuildContext context) {
    final AppColors c = context.colors;
    final String reasoning = message.reasoningContent ?? '';
    final bool collapsed = controller.isReasonCollapsed(message.id);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (speakerName.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 6, left: 4),
            child: Text(
              speakerName,
              style: TextStyle(
                fontSize: 11,
                color: c.accent,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        if (reasoning.isNotEmpty)
          _ReasoningBlock(
            text: reasoning,
            title: controller.reasonTitle(message),
            expanded: !collapsed,
            streaming: streaming,
            onToggle: () => controller.toggleReason(message.id),
          ),
        if (message.content.isNotEmpty)
          Padding(
            padding: EdgeInsets.only(
              top: reasoning.isNotEmpty ? 10 : 0,
              left: 2,
              right: 2,
            ),
            child: GptMarkdown(
              rewriteCitations(
                message.content,
                maxIndex: message.sources.length,
              ),
              style: TextStyle(
                fontSize: 15,
                height: 1.62,
                color: c.textPrimary,
              ),
              isStreaming: streaming,
              styleSheet: markdownStyleSheet(c),
              // 角标芯片：`[N]` 由 rewriteCitations 生成，点开来源面板并高亮。
              onSourceTagTap: (String id) {
                final int? number = int.tryParse(id.trim());
                if (number != null && number >= 1) {
                  showSourcePanel(context, message.sources, highlight: number);
                }
              },
              onLinkTap: (String url, String? title) =>
                  _openLink(context, url, sources: message.sources),
              onImageTap: (String url) => _previewImage(context, url),
            ),
          ),
        if (message.truncated)
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 2),
            child: Text(
              '回答达到长度上限，可能不完整',
              style: TextStyle(fontSize: 12, color: c.textMuted),
            ),
          ),
        if (message.content.isEmpty &&
            (message.searching || (message.searchHint ?? '').isNotEmpty))
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 2),
            child: Text(
              message.searchHint ?? '正在联网搜索…',
              style: TextStyle(fontSize: 13, color: c.textMuted),
            ),
          ),
        if (message.sources.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8, left: 2),
            child: SearchSummaryBar(
              sources: message.sources,
              onTap: () => showSourcePanel(context, message.sources),
            ),
          ),        if (controller.featureTts &&
            controller.currentProviderId == 'deepseek' &&
            !streaming &&
            message.content.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 2),
            child: _ReadAloudButton(
              messageId: message.id,
              text: message.content,
              apiKey: controller.currentApiKey,
              voice: controller.ttsVoice,
            ),
          ),        if (!streaming &&
            message.status != MessageStatus.error &&
            message.content.isEmpty &&
            reasoning.isEmpty &&
            message.imageState == null &&
            message.imageUrls.isEmpty &&
            message.serverToolCallsJson.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 2),
            child: Text(
              '本轮没有返回内容，长按可重新生成',
              style: TextStyle(fontSize: 12, color: c.textMuted),
            ),
          ),
        if (message.status == MessageStatus.error)
          Padding(
            padding: const EdgeInsets.only(top: 8, left: 2),
            child: Text(
              message.errorMessage ?? '生成失败',
              style: TextStyle(
                fontSize: 13,
                height: 1.5,
                color: c.dangerText,
              ),
            ),
          ),
        if (message.imageState == 'generating')
          Padding(
            padding: const EdgeInsets.only(top: 8, left: 2),
            child: Row(
              children: <Widget>[
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
                Text(
                  message.imageHint ?? '正在生成图片…',
                  style: TextStyle(fontSize: 12, color: c.textSecondary),
                ),
              ],
            ),
          ),
        if (message.imageState == 'failed')
          Padding(
            padding: const EdgeInsets.only(top: 8, left: 2),
            child: Text(
              '生图失败：${message.imageHint ?? '未知原因'}',
              style: TextStyle(fontSize: 12, color: c.dangerText),
            ),
          ),
        if (message.imageUrls.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8, left: 2, right: 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                if (message.imageMeta != null && message.imageMeta!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(
                      message.imageMeta!,
                      style: TextStyle(fontSize: 11, color: c.textMuted),
                    ),
                  ),
                for (final String url in message.imageUrls)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: GestureDetector(
                      onTap: () => _previewImage(context, url),
                      child: AspectRatio(
                        aspectRatio: message.imageAspect ?? 1,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: Image.network(
                            url,
                            fit: BoxFit.contain,
                            errorBuilder: (BuildContext context, Object error,
                                    StackTrace? stack) =>
                                Container(
                              alignment: Alignment.center,
                              color: c.fill,
                              child: Text(
                                '图片已过期或加载失败',
                                style:
                                    TextStyle(fontSize: 12, color: c.textMuted),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),        if (streaming && message.content.isEmpty && reasoning.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4, left: 2),
            child: Text(
              '正在生成…',
              style: TextStyle(fontSize: 13, color: c.textMuted),
            ),
          ),
      ],
    );
  }
}

class _ReasoningBlock extends StatefulWidget {
  const _ReasoningBlock({
    required this.text,
    required this.title,
    required this.expanded,
    required this.streaming,
    required this.onToggle,
  });

  final String text;
  final String title;
  final bool expanded;
  final bool streaming;
  final VoidCallback onToggle;

  @override
  State<_ReasoningBlock> createState() => _ReasoningBlockState();
}

class _ReasoningBlockState extends State<_ReasoningBlock> {
  final ScrollController _scroll = ScrollController();

  @override
  void didUpdateWidget(covariant _ReasoningBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.streaming && widget.text.length != oldWidget.text.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppColors c = context.colors;
    return Container(
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(14),
        border: Border(
          left: BorderSide(color: c.reasoningBar, width: 2),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          InkWell(
            onTap: widget.onToggle,
            child: Row(
              children: <Widget>[
                Icon(
                  widget.expanded
                      ? Icons.keyboard_arrow_up_rounded
                      : Icons.keyboard_arrow_down_rounded,
                  size: 18,
                  color: c.reasoningMuted,
                ),
                const SizedBox(width: 4),
                Text(
                  widget.title,
                  style: TextStyle(
                    fontSize: 12,
                    color: c.reasoningMuted,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          if (widget.expanded)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: SingleChildScrollView(
                controller: _scroll,
                padding: const EdgeInsets.only(top: 6),
                child: GptMarkdown(
                  widget.text,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.6,
                    color: c.reasoningText,
                  ),
                  styleSheet: markdownStyleSheet(c),
                  // 思考内容里的链接不可点，避免误触跳出对话。
                  onLinkTap: (String url, String? title) {},
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _BranchBar extends StatelessWidget {
  const _BranchBar({
    required this.index,
    required this.count,
    required this.onPrevious,
    required this.onNext,
    required this.color,
  });

  final int index;
  final int count;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final AppColors color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _BranchButton(
          label: '‹',
          onTap: index > 1 ? onPrevious : null,
          color: color,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            '$index/$count',
            style: TextStyle(fontSize: 11, color: color.textFaint),
          ),
        ),
        _BranchButton(
          label: '›',
          onTap: index < count ? onNext : null,
          color: color,
        ),
      ],
    );
  }
}

class _BranchButton extends StatelessWidget {
  const _BranchButton({
    required this.label,
    required this.onTap,
    required this.color,
  });

  final String label;
  final VoidCallback? onTap;
  final AppColors color;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 16,
            color: onTap == null ? color.textFaint : color.accent,
          ),
        ),
      ),
    );
  }
}

Future<void> _openLink(
  BuildContext context,
  String href, {
  List<SearchSource>? sources,
}) async {
  final int? cite = citationIndex(href);
  if (cite != null) {
    final List<SearchSource> list = sources ?? const <SearchSource>[];
    if (cite >= 1 && cite <= list.length) {
      // 移动端没有 hover：点角标先看来源卡片（可继续点开原文），不直接跳浏览器。
      await showSourcePanel(context, list, highlight: cite);
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('引用来源不在来源列表中')),
    );
    return;
  }
  if (!isSafeExternalUrl(href)) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('该链接暂不支持打开')),
    );
    return;
  }
  final bool ok = await launchUrl(
    Uri.parse(href),
    mode: LaunchMode.externalApplication,
  );
  if (!ok && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('无法打开链接')),
    );
  }
}

void _previewImage(BuildContext context, String url) {
  final AppColors c = context.colors;
  showDialog<void>(
    context: context,
    barrierColor: c.overlayScrim,
    builder: (BuildContext context) {
      return Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 480),
                child: Image.network(
                  url,
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      '图片加载失败',
                      style: TextStyle(color: c.heroText),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text('关闭', style: TextStyle(color: c.heroText)),
            ),
          ],
        ),
      );
    },
  );
}

/// 朗读按钮：合成 + 播放；全局同一时刻只有一条在播，播放中显示跳动的音柱。
class _ReadAloudButton extends StatefulWidget {
  const _ReadAloudButton({
    required this.messageId,
    required this.text,
    required this.apiKey,
    required this.voice,
  });

  final String messageId;
  final String text;
  final String apiKey;
  final String voice;

  @override
  State<_ReadAloudButton> createState() => _ReadAloudButtonState();
}

class _ReadAloudButtonState extends State<_ReadAloudButton> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final AppColors c = context.colors;
    return ValueListenableBuilder<String?>(
      valueListenable: TtsService.playingOwner,
      builder: (BuildContext context, String? owner, _) {
        final bool playing = owner == widget.messageId;
        return InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: _busy ? null : _toggle,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (_busy)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else if (playing)
                  _PlayingBars(color: c.accent)
                else
                  Icon(Icons.volume_up_outlined, size: 16, color: c.textMuted),
                const SizedBox(width: 4),
                Text(
                  playing ? '停止' : '朗读',
                  style: TextStyle(fontSize: 11, color: c.textMuted),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _toggle() async {
    if (TtsService.playingOwner.value == widget.messageId) {
      await TtsService.stop();
      return;
    }
    setState(() => _busy = true);
    try {
      await TtsService.speak(
        text: widget.text,
        apiKey: widget.apiKey,
        voiceId: widget.voice,
        ownerId: widget.messageId,
      );
    } on TtsException catch (error) {
      _snack(error.message);
    } catch (error) {
      _snack('朗读失败：$error');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  void _snack(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }
}

/// 播放中的三根音柱：纯装饰动效，相位错开形成「跳动」感。
class _PlayingBars extends StatefulWidget {
  const _PlayingBars({required this.color});

  final Color color;

  @override
  State<_PlayingBars> createState() => _PlayingBarsState();
}

class _PlayingBarsState extends State<_PlayingBars>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 16,
      height: 14,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (BuildContext context, _) {
          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              for (int i = 0; i < 3; i++)
                Container(
                  width: 3,
                  height: 4 + 9 * (0.5 + 0.5 * math.sin(_controller.value * 2 * math.pi + i)),
                  decoration: BoxDecoration(
                    color: widget.color,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}


