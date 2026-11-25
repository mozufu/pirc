import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:pirc_client/pirc_client.dart';
import 'package:pirc_render/pirc_render.dart';
import 'package:pirc_ui/pirc_ui.dart';
import 'package:share_plus/share_plus.dart';

import '../../l10n/app_localizations.dart';
import 'artifacts.dart';
import 'session_controller.dart';
import 'timeline.dart';
import 'work_side.dart';
import 'labels.dart';

/// The `side` query value that opens result [id] beside its conversation.
String resultSide(String id) => 'result:$id';

/// Where each reader is: the selected version (state) and the reading
/// position of every version (kept aside: scrolling rebuilds nothing),
/// while the app runs (P1, 3A).
final readerMemoryProvider =
    NotifierProvider<ReaderMemoryNotifier, Map<String, int>>(
      ReaderMemoryNotifier.new,
    );

class ReaderMemoryNotifier extends Notifier<Map<String, int>> {
  /// `<session>:<artifact>:<version>` → scroll offset.
  final offsets = <String, double>{};

  /// `<session>:<artifact>` → selected version.
  @override
  Map<String, int> build() => const {};

  void select(String key, int version) => state = {...state, key: version};
}

/// An assistant message with result blocks: its prose, then a card per
/// result.
MessageBuilder artifactEntry(String sessionId) => (context, message) {
  final artifacts = messageArtifacts(message);
  if (artifacts.isEmpty) return null;
  final prose = artifactProse(message);
  return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (prose.isNotEmpty || message.tools.isNotEmpty)
        AssistantMessage(message: message.copyWith(content: prose)),
      for (final artifact in artifacts)
        Padding(
          padding: const EdgeInsets.only(top: PircSpacing.stackMd),
          child: ResultCard(sessionId: sessionId, artifact: artifact),
        ),
    ],
  );
};

/// `ResultCard`: kind, version, state, title, summary; copy, share, open.
class ResultCard extends StatelessWidget {
  const ResultCard({
    super.key,
    required this.sessionId,
    required this.artifact,
  });

  final String sessionId;
  final Artifact artifact;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = PircColorTokens.of(context);
    final text = Theme.of(context).textTheme;
    final state = switch (artifact.status) {
      'generating' => l10n.resultGenerating,
      'failed' => l10n.resultFailed,
      _ => null,
    };
    return Container(
      padding: const EdgeInsets.all(PircSpacing.stackLg),
      decoration: BoxDecoration(
        color: colors['surface.layer'],
        borderRadius: BorderRadius.circular(PircRadius.lg),
        boxShadow: Theme.of(context).extension<PircElevationTokens>()?.card,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                LucideIcons.fileText,
                size: PircSize.iconRow,
                color: colors['accent.default'],
              ),
              const SizedBox(width: PircSpacing.stackSm),
              Expanded(
                child: Text(
                  '${l10n.resultKind(artifact.kind)} · v${artifact.version}',
                  style: text.labelSmall,
                ),
              ),
              if (state != null)
                Text(
                  state,
                  style: text.labelSmall?.copyWith(
                    color: artifact.status == 'failed'
                        ? colors['status.danger']
                        : colors['text.secondary'],
                  ),
                ),
            ],
          ),
          const SizedBox(height: PircSpacing.stackSm),
          Text(artifact.title, style: text.titleMedium),
          if (artifact.summary.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: PircSpacing.stackXs),
              child: Text(
                artifact.summary,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: text.bodySmall,
              ),
            ),
          const SizedBox(height: PircSpacing.stackSm),
          Row(
            children: [
              TextButton.icon(
                onPressed: () => context.go(
                  workLocation(
                    sessionId,
                    side: resultSide(artifact.id),
                    context: context,
                  ),
                ),
                icon: const Icon(LucideIcons.arrowUpRight, size: 18),
                label: Text(
                  artifact.status == 'generating'
                      ? l10n.resultReadSoFar
                      : l10n.resultOpen,
                ),
              ),
              const Spacer(),
              _CopyShare(artifact: artifact),
            ],
          ),
        ],
      ),
    );
  }
}

class _CopyShare extends StatelessWidget {
  const _CopyShare({required this.artifact});
  final Artifact artifact;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: l10n.copy,
          icon: const Icon(LucideIcons.copy, size: 18),
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: artifact.shareText));
            if (context.mounted) {
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(SnackBar(content: Text(l10n.copied)));
            }
          },
        ),
        IconButton(
          tooltip: l10n.share,
          icon: const Icon(LucideIcons.share2, size: 18),
          onPressed: () => SharePlus.instance.share(
            ShareParams(text: artifact.shareText, subject: artifact.title),
          ),
        ),
      ],
    );
  }
}

/// `ResultReader`: one result, by version. A newer version shows a note
/// with "Switch to vN"; the reader never switches by itself, and each
/// version keeps its own reading position.
class ResultReader extends ConsumerStatefulWidget {
  const ResultReader({
    super.key,
    required this.sessionId,
    required this.artifactId,
    required this.onClose,
  });

  final String sessionId;
  final String artifactId;
  final VoidCallback onClose;

  @override
  ConsumerState<ResultReader> createState() => _ResultReaderState();
}

class _ResultReaderState extends ConsumerState<ResultReader> {
  ScrollController? _scroll;
  int? _scrollVersion;

  String get _key => '${widget.sessionId}:${widget.artifactId}';

  @override
  void dispose() {
    _scroll?.dispose();
    super.dispose();
  }

  /// A controller per version, starting at that version's saved position
  /// and saving it as the reader scrolls.
  ScrollController _controllerFor(int version) {
    if (_scrollVersion == version && _scroll != null) return _scroll!;
    final offsets = ref.read(readerMemoryProvider.notifier).offsets;
    final key = '$_key:$version';
    _scroll?.dispose();
    _scrollVersion = version;
    final scroll = ScrollController(initialScrollOffset: offsets[key] ?? 0);
    scroll.addListener(() => offsets[key] = scroll.offset);
    return _scroll = scroll;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = PircColorTokens.of(context);
    final text = Theme.of(context).textTheme;
    final messages =
        ref
            .watch(sessionControllerProvider(widget.sessionId))
            .state
            ?.messages ??
        const <Message>[];
    final versions = artifactVersions(messages, widget.artifactId);
    if (versions.isEmpty) {
      return Scaffold(
        appBar: AppBar(
          leading: IconButton(
            tooltip: l10n.close,
            icon: const Icon(LucideIcons.x),
            onPressed: widget.onClose,
          ),
        ),
        body: Center(child: Text(l10n.resultMissing)),
      );
    }
    final memory = ref.watch(readerMemoryProvider);
    final latest = versions.last;
    // The first time: the latest, or the last good one when it failed.
    final remembered = memory[_key];
    final selected =
        versions.where((a) => a.version == remembered).firstOrNull ??
        (latest.status == 'failed'
            ? versions.lastWhere(
                (a) => a.status == 'complete',
                orElse: () => latest,
              )
            : latest);
    if (remembered == null) {
      Future.microtask(
        () => ref
            .read(readerMemoryProvider.notifier)
            .select(_key, selected.version),
      );
    }
    final newer = latest.version > selected.version ? latest : null;
    void select(Artifact a) {
      ref.read(readerMemoryProvider.notifier).select(_key, a.version);
    }

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: l10n.close,
          icon: const Icon(LucideIcons.x),
          onPressed: widget.onClose,
        ),
        title: Text(
          '${selected.title} · v${selected.version}',
          style: text.titleSmall,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (versions.length > 1)
            PopupMenuButton<int>(
              tooltip: l10n.resultVersions,
              icon: const Icon(LucideIcons.history),
              initialValue: selected.version,
              onSelected: (v) =>
                  select(versions.firstWhere((a) => a.version == v)),
              itemBuilder: (_) => [
                for (final a in versions)
                  CheckedPopupMenuItem(
                    value: a.version,
                    checked: a.version == selected.version,
                    child: Text('v${a.version}'),
                  ),
              ],
            ),
          _CopyShare(artifact: selected),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (newer != null)
            Material(
              color: colors['accent.soft'],
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        l10n.resultNewer(newer.version),
                        style: text.bodySmall,
                      ),
                    ),
                    TextButton(
                      onPressed: () => select(newer),
                      child: Text(l10n.resultSwitch(newer.version)),
                    ),
                  ],
                ),
              ),
            ),
          if (selected.status == 'generating')
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                l10n.resultGenerating,
                textAlign: TextAlign.center,
                style: text.bodySmall,
              ),
            ),
          if (latest.status == 'failed' && selected.version != latest.version)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                l10n.resultFailedShowingLast(latest.version),
                textAlign: TextAlign.center,
                style: text.bodySmall?.copyWith(color: colors['status.danger']),
              ),
            ),
          Expanded(
            child: ListView(
              key: ValueKey('reader-${selected.version}'),
              controller: _controllerFor(selected.version),
              padding: const EdgeInsets.all(PircSpacing.stackXl),
              children: [_Body(artifact: selected)],
            ),
          ),
        ],
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.artifact});
  final Artifact artifact;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = PircColorTokens.of(context);
    switch (artifact.kind) {
      case 'markdown':
        return NativeMarkdown(
          source: artifact.content,
          streaming: artifact.status == 'generating',
        );
      case 'code':
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SelectableText(
            artifact.content,
            style: PircType.monoCode.style(color: colors['code.text']),
          ),
        );
      case 'table':
        final columns = artifact.columns;
        if (columns.isEmpty) return Text(l10n.resultNoColumns);
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            columns: [for (final c in columns) DataColumn(label: Text(c))],
            rows: [
              for (final row in artifact.rows)
                DataRow(
                  cells: [
                    for (var i = 0; i < columns.length; i++)
                      DataCell(SelectableText(i < row.length ? row[i] : '')),
                  ],
                ),
            ],
          ),
        );
      default:
        // Not supported here: the summary (or the text) as Markdown.
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.resultUnsupported,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            NativeMarkdown(
              source: artifact.summary.isNotEmpty
                  ? artifact.summary
                  : artifact.content,
            ),
          ],
        );
    }
  }
}
