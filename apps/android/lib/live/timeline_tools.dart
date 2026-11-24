import '../l10n/app_i18n.dart';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:pirc_render/src/code_block.dart';
import 'common.dart';
import 'gateway.dart';
import 'timeline_models.dart';
import 'interaction.dart';
import 'web_controls.dart';
import 'recording_player.dart';
import 'timeline_attachment_image.dart';
import 'timeline_image_wrap.dart';
import 'viewport_image_gate.dart';

class TimelineStatus extends StatelessWidget {
  const TimelineStatus(this.status, {super.key});
  final String status;
  @override
  Widget build(BuildContext context) {
    AppI18n.watch(context);
    return Tooltip(
      message: status == 'running'
          ? tr("Running")
          : status == 'failed'
          ? tr("Failed")
          : tr("Done"),
      child: status == 'running'
          ? WebSpinner(size: 15, color: palette(context)['accent.default'])
          : Icon(
              status == 'failed' ? LucideIcons.circleAlert : LucideIcons.check,
              size: 15,
              color: palette(
                context,
              )[status == 'failed' ? 'status.danger' : 'status.success'],
            ),
    );
  }
}

class TimelineImages extends StatelessWidget {
  const TimelineImages(
    this.images, {
    super.key,
    this.label = 'Attachment',
    this.gateway,
    this.retainOnSourceChange = false,
  });
  final List<Json> images;
  final String label;
  final Gateway? gateway;
  final bool retainOnSourceChange;
  @override
  Widget build(BuildContext context) {
    AppI18n.watch(context);
    return TimelineImageWrap(
      children: [
        for (final (index, entry) in images.indexed)
          ViewportImageGate(
            key: ValueKey(
              retainOnSourceChange
                  ? index
                  : (index, entry['url'], entry['base64']),
            ),
            preloadDistance: 1500,
            placeholder: const SizedBox.shrink(),
            builder: (_) => TimelineAttachmentImage(
              entry: entry,
              label: label,
              gateway: gateway,
            ),
          ),
      ],
    );
  }
}

class TimelineRun extends StatefulWidget {
  const TimelineRun({
    super.key,
    required this.tools,
    required this.child,
    this.forceOpen = false,
  });
  final List<Json> tools;
  final Widget child;
  final bool forceOpen;
  @override
  State<TimelineRun> createState() => _TimelineRunState();
}

class _TimelineRunState extends State<TimelineRun> {
  bool open = false, toggled = false;
  @override
  Widget build(BuildContext context) {
    AppI18n.watch(context);
    final summary = RunSummary(widget.tools), p = palette(context);
    if (!toggled) open = widget.forceOpen;
    if (widget.forceOpen) {
      open = true;
      toggled = true;
    }
    final phone = MediaQuery.sizeOf(context).width <= 650;
    final seconds = elapsedMs(summary.durationMs);
    final displayFiles = [
      ...summary.files.take(3),
      if (summary.files.length > 3) '+${summary.files.length - 3}',
    ];
    return LayoutBuilder(
      builder: (context, bounds) {
        final titleStyle = webText(
          context,
          size: 13,
          weight: FontWeight.w500,
        ).copyWith(height: kTextHeightNone);
        final metaText = tr("{0} tools{1}", [
          summary.count,
          seconds.isEmpty ? '' : ' · $seconds',
        ]);
        final metaStyle = webText(
          context,
          size: 12,
          color: 'text.muted',
        ).copyWith(height: kTextHeightNone);
        final fileStyle = webText(
          context,
          size: 11,
          color: 'text.secondary',
        ).copyWith(height: kTextHeightNone);
        Size textSize(String text, TextStyle style) {
          final painter = TextPainter(
            text: TextSpan(text: text, style: style),
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
            maxLines: 1,
          )..layout();
          final size = painter.size;
          painter.dispose();
          return size;
        }

        final titleSize = textSize(summary.title, titleStyle);
        final metaSize = textSize(metaText, metaStyle);
        final fileTextHeight = displayFiles.fold<double>(
          0,
          (height, file) =>
              math.max(height, textSize(file, fileStyle).height).toDouble(),
        );
        final fileChipHeight = displayFiles.isEmpty ? 0.0 : fileTextHeight + 4;
        final blocked = effectiveTools(
          widget.tools,
        ).any((t) => writeBlock(t) != null);
        final gaps = phone ? (blocked ? 4 : 3) : (blocked ? 5 : 4);
        final fixedWidth =
            14.0 +
            15 +
            metaSize.width +
            (phone ? 0 : titleSize.width) +
            (blocked ? 13 : 0) +
            gaps * 8.0;
        final availableWidth = bounds.hasBoundedWidth
            ? math.max(0.0, bounds.maxWidth - 26).toDouble()
            : 0.0;
        final rowWidth = math.max(availableWidth, fixedWidth).toDouble();
        final filesWidth = phone ? 0.0 : rowWidth - fixedWidth;
        final rowHeight = math
            .max(
              38.0,
              math.max(
                titleSize.height,
                math.max(metaSize.height, fileChipHeight),
              ),
            )
            .toDouble();
        return Container(
          margin: const EdgeInsets.only(top: 4, bottom: 12),
          decoration: BoxDecoration(
            color: p[open ? 'surface.page' : 'web.bg-subtle'],
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: summary.status == 'failed'
                  ? p['status.danger'].withValues(alpha: .3)
                  : p['web.line'],
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Semantics(
                expanded: open,
                child: InkWell(
                  onTap: () => setState(() {
                    toggled = true;
                    open = !open;
                  }),
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    constraints: const BoxConstraints(minHeight: 38),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: SizedBox(
                      height: rowHeight,
                      child: OverflowBox(
                        alignment: Alignment.centerLeft,
                        minWidth: 0,
                        maxWidth: double.infinity,
                        child: SizedBox(
                          width: rowWidth,
                          height: rowHeight,
                          child: Row(
                            children: [
                              Icon(
                                open
                                    ? LucideIcons.chevronDown
                                    : LucideIcons.chevronRight,
                                size: 14,
                                color: p['text.muted'],
                              ),
                              const SizedBox(width: 8),
                              if (phone)
                                Expanded(
                                  child: Text(
                                    summary.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: titleStyle,
                                  ),
                                )
                              else
                                Text(
                                  summary.title,
                                  maxLines: 1,
                                  softWrap: false,
                                  style: titleStyle,
                                ),
                              const SizedBox(width: 8),
                              Text(metaText, style: metaStyle),
                              if (!phone) ...[
                                const SizedBox(width: 8),
                                SizedBox(
                                  width: filesWidth,
                                  child: ClipRect(
                                    key: const ValueKey(
                                      'timeline-run-files-clip',
                                    ),
                                    child: OverflowBox(
                                      alignment: Alignment.centerRight,
                                      minWidth: 0,
                                      maxWidth: double.infinity,
                                      maxHeight: rowHeight,
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          for (final (index, file)
                                              in displayFiles.indexed) ...[
                                            if (index > 0)
                                              const SizedBox(width: 4),
                                            Container(
                                              key: ValueKey(file),
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 6,
                                                    vertical: 1,
                                                  ),
                                              decoration: BoxDecoration(
                                                color: p['surface.layer'],
                                                border: Border.all(
                                                  color: p['web.line'],
                                                ),
                                                borderRadius:
                                                    BorderRadius.circular(4),
                                              ),
                                              child: Text(
                                                file,
                                                maxLines: 1,
                                                softWrap: false,
                                                overflow: TextOverflow.clip,
                                                style: fileStyle,
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                              if (blocked) ...[
                                const SizedBox(width: 8),
                                Tooltip(
                                  message: tr(
                                    "A write was blocked by another session",
                                  ),
                                  child: Icon(
                                    LucideIcons.lock,
                                    size: 13,
                                    color: p['status.warning'],
                                  ),
                                ),
                              ],
                              const SizedBox(width: 8),
                              TimelineStatus(summary.status),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (open)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                  decoration: BoxDecoration(
                    border: Border(top: BorderSide(color: p['web.line'])),
                  ),
                  child: widget.child,
                ),
            ],
          ),
        );
      },
    );
  }
}

class TimelineTool extends StatefulWidget {
  const TimelineTool({
    super.key,
    required this.tool,
    required this.controller,
    this.embedInteractions = true,
  });
  final Json tool;
  final bool embedInteractions;
  final LiveController controller;
  @override
  State<TimelineTool> createState() => _TimelineToolState();
}

class _TimelineToolState extends State<TimelineTool> {
  bool open = false, toggled = false, hover = false;
  Widget snippet(String text, {String language = '', bool error = false}) {
    final highlighted = highlightCode(text, language, palette(context));
    return SelectableText.rich(
      style: const TextStyle(
        fontFamily: 'monospace',
        fontSize: 12.5,
        height: 1.6,
      ),
      TextSpan(
        style: webText(
          context,
          size: 12.5,
          color: error ? 'status.danger' : 'code.text',
        ).copyWith(fontFamily: 'monospace', height: 1.6),
        children: error
            ? [TextSpan(text: text)]
            : highlighted.children ?? [TextSpan(text: highlighted.text)],
      ),
    );
  }

  Widget section(String title, Widget child) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        title,
        style: webText(
          context,
          size: 11,
          color: 'text.muted',
          weight: FontWeight.w500,
        ).copyWith(height: 13 / 11),
      ),
      const SizedBox(height: 4),
      child,
    ],
  );
  Widget diff(String text) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final line in text.split('\n'))
        Container(
          color: line.startsWith('+')
              ? const Color.fromRGBO(34, 160, 107, .10)
              : line.startsWith('-')
              ? const Color.fromRGBO(220, 50, 50, .09)
              : null,
          child: SelectableText(
            line,
            style: webText(
              context,
              size: 12.5,
              color: line.startsWith('+')
                  ? 'status.success'
                  : line.startsWith('-')
                  ? 'status.danger'
                  : line.startsWith('@@')
                  ? 'text.muted'
                  : 'code.text',
            ).copyWith(fontFamily: 'monospace', height: 1.6),
          ),
        ),
    ],
  );
  @override
  Widget build(BuildContext context) {
    AppI18n.watch(context);
    final t = widget.tool,
        a = toolArgs(t['input']),
        p = palette(context),
        c = widget.controller;
    final operations = rows(t['operations']);
    final question = widget.embedInteractions
        ? pendingInteractionForTool(t, c.questions)
        : null;
    final waitingForReview =
        widget.embedInteractions && toolHasPendingInteraction(t, c.questions);
    if (!toggled) {
      open = waitingForReview;
    }
    if (waitingForReview) {
      open = true;
      toggled = true;
    }
    final name = value(t, 'name'),
        summary = toolDescription(t),
        duration = toolElapsed(t),
        extra = residualInput(t),
        blocked = writeBlock(t);
    final holder = blocked == null
        ? null
        : c.sessions
                  .where(
                    (s) =>
                        s['name'] == blocked.holderName &&
                        s['writeLease'] != null &&
                        s['writeLease'] != false,
                  )
                  .firstOrNull ??
              c.sessions
                  .where((s) => s['name'] == blocked.holderName)
                  .firstOrNull;
    final language = toolLanguage(a['path']);
    final contents = !open
        ? <Widget>[]
        : <Widget>[
            if (name == 'bash' && a['command'] is String)
              section(tr("Command"), snippet(a['command'], language: 'bash')),
            if (name == 'write' && a['content'] is String)
              section(
                tr("Content"),
                snippet(clipToolText(a['content']), language: language),
              ),
            if (value(t, 'diff').isNotEmpty)
              section(tr("Diff"), diff(value(t, 'diff')))
            else if (name == 'edit' && rows(a['edits']).isNotEmpty)
              section(
                tr("Edits"),
                diff(
                  rows(a['edits'])
                      .map(
                        (e) =>
                            '${value(e, 'oldText').split('\n').map((l) => '-$l').join('\n')}\n${value(e, 'newText').split('\n').map((l) => '+$l').join('\n')}\n',
                      )
                      .join('\n'),
                ),
              ),
            if (operations.isNotEmpty)
              section(
                tr("Operations"),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final (index, operation) in operations.indexed) ...[
                      if (index > 0) const SizedBox(height: 4),
                      TimelineTool(
                        key: ValueKey(operation['id']),
                        tool: operation,
                        controller: c,
                        embedInteractions: widget.embedInteractions,
                      ),
                    ],
                  ],
                ),
              ),
            if (extra != null)
              section(
                tr("Input"),
                snippet(
                  inputText(extra),
                  language: extra is String ? '' : 'json',
                ),
              ),
            if (value(t, 'output').isNotEmpty)
              section(
                t['status'] == 'failed' ? tr("Error") : tr("Output"),
                snippet(
                  clipToolText(value(t, 'output')),
                  language: name == 'read' && t['status'] != 'failed'
                      ? language
                      : '',
                  error: t['status'] == 'failed',
                ),
              ),
            if (rows(t['images']).isNotEmpty)
              TimelineImages(
                rows(t['images']),
                label: tr("Tool output"),
                gateway: widget.controller.gateway,
                retainOnSourceChange: true,
              ),
            if (value(t, 'output').isEmpty &&
                value(t, 'diff').isEmpty &&
                rows(t['images']).isEmpty)
              Text(
                t['status'] == 'running'
                    ? tr("Waiting for output…")
                    : tr("No output returned."),
                style: webText(context, size: 12, color: 'text.muted'),
              ),
          ];
    final expandedContents = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, child) in contents.indexed) ...[
          if (i > 0) const SizedBox(height: 10),
          child,
        ],
        if (question != null) ...[
          if (contents.isNotEmpty) const SizedBox(height: 12),
          QuestionSheet(
            key: ValueKey(question['id']),
            controller: c,
            question: question,
            embedded: true,
          ),
        ],
      ],
    );
    return LayoutBuilder(
      builder: (context, bounds) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            expanded: open,
            child: MouseRegion(
              onEnter: (_) => setState(() => hover = true),
              onExit: (_) => setState(() => hover = false),
              child: InkWell(
                onTap: () => setState(() {
                  toggled = true;
                  open = !open;
                }),
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  constraints: const BoxConstraints(minHeight: 40),
                  padding: const EdgeInsets.fromLTRB(0, 2, 8, 2),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 20,
                        height: 20,
                        child: Icon(
                          const {
                                'bash': LucideIcons.terminal,
                                'read': LucideIcons.fileText,
                                'edit': LucideIcons.filePen,
                                'write': LucideIcons.filePlus,
                                'grep': LucideIcons.search,
                                'find': LucideIcons.search,
                                'ls': LucideIcons.folderTree,
                              }[name] ??
                              LucideIcons.wrench,
                          size: 14,
                          color: p['text.muted'],
                        ),
                      ),
                      const SizedBox(width: 6),
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: bounds.maxWidth * .30,
                        ),
                        child: Text(
                          '${t['title'] ?? name}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: webText(
                            context,
                            size: 14,
                            color: t['status'] == 'failed'
                                ? 'status.danger'
                                : 'text.secondary',
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Tooltip(
                          message: summary,
                          child: Text(
                            summary.isEmpty
                                ? t['status'] == 'running'
                                      ? tr("Running")
                                      : t['status'] == 'failed'
                                      ? tr("Failed")
                                      : tr("Done")
                                : summary,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style:
                                webText(
                                  context,
                                  size: 12.5,
                                  color: 'text.muted',
                                ).copyWith(
                                  fontFamily: summary.isEmpty
                                      ? null
                                      : 'monospace',
                                ),
                          ),
                        ),
                      ),
                      if (duration.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        Text(
                          duration,
                          style: webText(
                            context,
                            size: 12,
                            color: 'text.muted',
                          ),
                        ),
                      ],
                      const SizedBox(width: 6),
                      TimelineStatus(value(t, 'status')),
                      const SizedBox(width: 6),
                      Opacity(
                        opacity: open || hover ? 1 : 0,
                        child: Icon(
                          open
                              ? LucideIcons.chevronUp
                              : LucideIcons.chevronDown,
                          size: 16,
                          color: p['text.faint'],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (blocked != null)
            Container(
              margin: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: p['status.warningSoft'],
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        LucideIcons.lock,
                        size: 15,
                        color: p['status.warning'],
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text: tr("Write blocked. "),
                                style: webText(
                                  context,
                                  size: 13,
                                  weight: FontWeight.w600,
                                ),
                              ),
                              TextSpan(
                                text: tr(
                                  "“{0}” is writing to {1} right now. The agent was told to wait until that run finishes.",
                                  [blocked.holderName, blocked.path],
                                ),
                                style: webText(
                                  context,
                                  size: 13,
                                  color: 'text.secondary',
                                ).copyWith(height: 1.45),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (holder != null && holder['id'] != c.sessionId)
                    Padding(
                      padding: const EdgeInsets.only(left: 25, top: 6),
                      child: WebButton(
                        '${holder['name']}',
                        onPressed: () => c.open('${holder['id']}'),
                      ),
                    ),
                ],
              ),
            ),
          if (t['recording'] != null && c.sessionId != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              child: NativeRecordingPlayer(
                key: ValueKey(
                  '${c.origin}:${c.clientId}:${c.sessionId}:${t['recording']}',
                ),
                gateway: c.gateway,
                session: c.sessionId!,
                path: '${t['recording']}',
                showDownload: false,
                maxHeight: 420,
              ),
            ),
          if (open)
            Container(
              margin: const EdgeInsets.fromLTRB(22, 4, 0, 8),
              decoration: BoxDecoration(
                color: p['code.bg'],
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: p['web.line']),
              ),
              // Pending answers must scroll with the conversation, rather than
              // being clipped inside several nested tool-output viewports.
              constraints: waitingForReview
                  ? null
                  : const BoxConstraints(maxHeight: 420),
              child: waitingForReview
                  ? Padding(
                      padding: const EdgeInsets.all(12),
                      child: expandedContents,
                    )
                  : SingleChildScrollView(
                      padding: const EdgeInsets.all(12),
                      child: expandedContents,
                    ),
            ),
        ],
      ),
    );
  }
}
