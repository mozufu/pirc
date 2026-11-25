import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:pirc_client/pirc_client.dart';
import 'package:pirc_render/pirc_render.dart';
import 'package:pirc_ui/pirc_ui.dart';

import '../../l10n/app_localizations.dart';

/// Builds one timeline entry; the conversation adds its own kinds (results,
/// pot instructions) through [WorkTimeline.messageBuilder].
typedef MessageBuilder =
    Widget? Function(BuildContext context, Message message);

/// The work timeline: a reversed list (newest at the bottom). It follows new
/// output only while the view is at the bottom; otherwise it keeps what the
/// reader sees and offers "New content ↓" (or "A question waits for you ↓").
class WorkTimeline extends StatefulWidget {
  const WorkTimeline({
    super.key,
    required this.messages,
    this.footer = const [],
    this.questionWaiting = false,
    this.messageBuilder,
  });

  final List<Message> messages;

  /// Widgets below the last message (question cards), newest last.
  final List<Widget> footer;
  final bool questionWaiting;
  final MessageBuilder? messageBuilder;

  @override
  State<WorkTimeline> createState() => _WorkTimelineState();
}

class _WorkTimelineState extends State<WorkTimeline> {
  static const _bottomSlack = 48.0;

  final _controller = ScrollController();
  bool _atBottom = true;
  bool _unseen = false;
  double? _extent;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onScroll);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onScroll() {
    final atBottom = _controller.offset <= _bottomSlack;
    if (atBottom != _atBottom) {
      setState(() {
        _atBottom = atBottom;
        if (atBottom) _unseen = false;
      });
    }
  }

  @override
  void didUpdateWidget(WorkTimeline old) {
    super.didUpdateWidget(old);
    final grew =
        !identical(old.messages, widget.messages) ||
        old.footer.length != widget.footer.length;
    if (!grew || !_controller.hasClients) return;
    if (_atBottom) return;
    // Keep what the reader sees: content grew below them.
    _extent = _controller.position.maxScrollExtent;
    _unseen = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_controller.hasClients || _extent == null) return;
      final delta = _controller.position.maxScrollExtent - _extent!;
      _extent = null;
      if (delta > 0) _controller.jumpTo(_controller.offset + delta);
    });
  }

  void _toBottom() {
    _controller.animateTo(
      0,
      duration: PircMotion.sheet,
      curve: PircMotion.ease,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final entries = <Widget>[
      for (final message in widget.messages)
        if (widget.messageBuilder?.call(context, message) ??
                _defaultEntry(context, message)
            case final Widget entry)
          entry,
      ...widget.footer,
    ];
    final showJump = !_atBottom && (_unseen || widget.questionWaiting);
    return Stack(
      children: [
        ListView.builder(
          controller: _controller,
          reverse: true,
          padding: const EdgeInsets.fromLTRB(
            PircSpacing.gutterPhone,
            PircSpacing.stackLg,
            PircSpacing.gutterPhone,
            PircSpacing.stackLg,
          ),
          itemCount: entries.length,
          itemBuilder: (context, index) => Padding(
            padding: const EdgeInsets.only(bottom: PircSpacing.stackLg),
            child: entries[entries.length - 1 - index],
          ),
        ),
        if (showJump)
          Positioned(
            bottom: PircSpacing.stackMd,
            left: 0,
            right: 0,
            child: Center(
              child: FilledButton.tonalIcon(
                onPressed: _toBottom,
                icon: const Icon(LucideIcons.arrowDown, size: 16),
                label: Text(
                  widget.questionWaiting ? l10n.questionWaits : l10n.newContent,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

Widget? _defaultEntry(BuildContext context, Message message) =>
    switch (message.role) {
      'user' => UserMessage(message: message),
      'assistant' => AssistantMessage(message: message),
      _ => SystemEvent(message: message),
    };

/// `c-user`: the user's message in a soft bubble, right-aligned.
class UserMessage extends StatelessWidget {
  const UserMessage({super.key, required this.message, this.tag, this.source});

  final Message message;

  /// Shown above the bubble ("From `pot`").
  final Widget? tag;

  /// Shown under the bubble ("Not sent by you").
  final String? source;

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        ?tag,
        LayoutBuilder(
          builder: (context, constraints) => ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: tag == null
                  ? constraints.maxWidth * 0.82
                  : constraints.maxWidth,
            ),
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: PircSpacing.stackLg,
                vertical: PircSpacing.stackMd,
              ),
              decoration: BoxDecoration(
                color: colors['surface.bubble'],
                borderRadius: BorderRadius.circular(PircRadius.xl),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (message.images.isNotEmpty)
                    InlineImages(images: message.images),
                  if (message.content.trim().isNotEmpty)
                    NativeMarkdown(
                      source: message.content,
                      lineHeight: 24 / 16,
                    ),
                ],
              ),
            ),
          ),
        ),
        if (source != null)
          Padding(
            padding: const EdgeInsets.only(top: PircSpacing.stackXs),
            child: Text(
              source!,
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: colors['text.muted']),
              textAlign: TextAlign.end,
            ),
          ),
      ],
    );
  }
}

/// `c-asst`: the assistant's text without a container, then its tool steps.
class AssistantMessage extends StatelessWidget {
  const AssistantMessage({super.key, required this.message});

  final Message message;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = PircColorTokens.of(context);
    final failed = message.stopReason == 'error';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (message.content.trim().isNotEmpty)
          NativeMarkdown(source: message.content, streaming: message.isPartial),
        if (message.images.isNotEmpty) InlineImages(images: message.images),
        if (message.tools.isNotEmpty) ...[
          const SizedBox(height: PircSpacing.stackSm),
          RunCard(tools: message.tools),
        ],
        if (failed || message.stopReason == 'aborted')
          Padding(
            padding: const EdgeInsets.only(top: PircSpacing.stackXs),
            child: Text(
              failed
                  ? (message.errorMessage ?? l10n.turnFailed)
                  : l10n.turnStopped,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: failed ? colors['status.danger'] : colors['text.muted'],
              ),
            ),
          ),
      ],
    );
  }
}

/// `c-run`: tool steps folded into one card: "n tool steps", failures with
/// ✕ and text; expanded, one row per step with its output.
class RunCard extends StatefulWidget {
  const RunCard({super.key, required this.tools});

  final List<ToolCall> tools;

  @override
  State<RunCard> createState() => _RunCardState();
}

class _RunCardState extends State<RunCard> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = PircColorTokens.of(context);
    final text = Theme.of(context).textTheme;
    final tools = widget.tools;
    final failed = tools.where((tool) => tool.status == 'failed').length;
    final running = tools.any((tool) => tool.status == 'running');
    return Material(
      color: colors['surface.subtle'],
      borderRadius: BorderRadius.circular(PircRadius.md),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _open = !_open),
            child: SizedBox(
              height: 44,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: PircSpacing.stackMd,
                ),
                child: Row(
                  children: [
                    Icon(
                      _open
                          ? LucideIcons.chevronDown
                          : LucideIcons.chevronRight,
                      size: PircSize.iconInline,
                    ),
                    const SizedBox(width: PircSpacing.stackSm),
                    Text(l10n.toolSteps(tools.length), style: text.bodyMedium),
                    if (running) ...[
                      const SizedBox(width: PircSpacing.stackSm),
                      const StateDot(DotState.running),
                      const SizedBox(width: 4),
                      Text(l10n.stateRunning, style: text.bodySmall),
                    ],
                    if (failed > 0) ...[
                      const SizedBox(width: PircSpacing.stackSm),
                      Icon(
                        LucideIcons.x,
                        size: 14,
                        color: colors['status.danger'],
                      ),
                      Text(
                        l10n.toolFailures(failed),
                        style: text.bodySmall?.copyWith(
                          color: colors['status.danger'],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          if (_open)
            for (final tool in tools) _ToolStep(tool: tool)
          else if (tools.any((tool) => tool.images.isNotEmpty))
            // Image results stay visible while the steps are folded.
            Padding(
              padding: const EdgeInsets.fromLTRB(
                PircSpacing.stackMd,
                0,
                PircSpacing.stackMd,
                PircSpacing.stackSm,
              ),
              child: InlineImages(
                images: [for (final tool in tools) ...tool.images],
              ),
            ),
        ],
      ),
    );
  }
}

class _ToolStep extends StatelessWidget {
  const _ToolStep({required this.tool});
  final ToolCall tool;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = PircColorTokens.of(context);
    final text = Theme.of(context).textTheme;
    final (icon, color, label) = switch (tool.status) {
      'failed' => (LucideIcons.x, colors['status.danger'], l10n.stepFailed),
      'running' => (
        LucideIcons.loader,
        colors['accent.default'],
        l10n.stateRunning,
      ),
      _ => (LucideIcons.check, colors['status.success'], l10n.stepDone),
    };
    final output = tool.output?.trim() ?? '';
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        PircSpacing.stackMd,
        0,
        PircSpacing.stackMd,
        PircSpacing.stackSm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: color, semanticLabel: label),
              const SizedBox(width: PircSpacing.stackSm),
              Expanded(
                child: Text(
                  tool.title ?? tool.name,
                  style: text.bodySmall,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          if (output.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(top: PircSpacing.stackXs),
              padding: const EdgeInsets.all(PircSpacing.stackSm),
              decoration: BoxDecoration(
                color: colors['code.bg'],
                borderRadius: BorderRadius.circular(PircRadius.sm),
              ),
              child: Text(
                output.length > 4000 ? '${output.substring(0, 4000)}…' : output,
                style: PircType.monoCode.style(color: colors['code.text']),
              ),
            ),
          if (tool.images.isNotEmpty) InlineImages(images: tool.images),
        ],
      ),
    );
  }
}

/// A system notice in the timeline (compaction, branch, runner notices).
class SystemEvent extends StatelessWidget {
  const SystemEvent({super.key, required this.message});

  final Message message;

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    final color = switch (message.level) {
      'error' => colors['status.danger'],
      'warning' => colors['text.warning'],
      _ => colors['text.muted'],
    };
    final label = message.label;
    final content = message.content.trim();
    return Center(
      child: Text(
        [?label, if (content.isNotEmpty) content].join(' · '),
        textAlign: TextAlign.center,
        maxLines: 4,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: color),
      ),
    );
  }
}

/// Images in a message or a tool result: thumbnails up to 240 high; a tap
/// shows one whole. Data that does not decode shows a note instead.
class InlineImages extends StatelessWidget {
  const InlineImages({super.key, required this.images});

  final List<InlineImage> images;

  static Uint8List? _bytes(InlineImage image) {
    try {
      return base64Decode(image.base64);
    } on FormatException {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = PircColorTokens.of(context);
    Widget unreadable() => Text(
      l10n.imageUnreadable,
      style: Theme.of(
        context,
      ).textTheme.bodySmall?.copyWith(color: colors['text.muted']),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: PircSpacing.stackXs),
      child: Wrap(
        spacing: PircSpacing.stackSm,
        runSpacing: PircSpacing.stackSm,
        children: [
          for (final image in images)
            if (_bytes(image) case final bytes?)
              Semantics(
                image: true,
                button: true,
                label: l10n.imageLabel,
                child: GestureDetector(
                  onTap: () => showDialog<void>(
                    context: context,
                    builder: (context) => Dialog(
                      clipBehavior: Clip.antiAlias,
                      child: InteractiveViewer(
                        child: Image.memory(
                          bytes,
                          errorBuilder: (_, _, _) => unreadable(),
                        ),
                      ),
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(PircRadius.sm),
                    child: ConstrainedBox(
                      // At least a tap target, however small the image.
                      constraints: const BoxConstraints(
                        minWidth: 48,
                        minHeight: 48,
                        maxHeight: 240,
                        maxWidth: 320,
                      ),
                      child: Image.memory(
                        bytes,
                        fit: BoxFit.contain,
                        excludeFromSemantics: true,
                        errorBuilder: (_, _, _) => unreadable(),
                      ),
                    ),
                  ),
                ),
              )
            else
              unreadable(),
        ],
      ),
    );
  }
}
