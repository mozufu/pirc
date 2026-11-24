import '../l10n/app_i18n.dart';
import 'dart:async';
import 'dart:convert';
import 'package:pirc_render/src/svg_dimensions.dart';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show OverflowBoxFit;
import 'package:flutter_svg/flutter_svg.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:pirc_render/src/code_block.dart';
import 'package:pirc_render/src/file_links.dart';
import 'common.dart';
import 'gateway.dart';
import 'files_state.dart';
import 'web_controls.dart';

String fileSize(dynamic bytes) {
  if (bytes is! num) return '';
  if (bytes < 1024) return tr("{0} B", [bytes]);
  if (bytes < 1024 * 1024) {
    return tr("{0} KB", [(bytes / 1024).toStringAsFixed(1)]);
  }
  return tr("{0} MB", [(bytes / (1024 * 1024)).toStringAsFixed(1)]);
}

double _measurePanelText(BuildContext context, String value, TextStyle style) {
  if (value.isEmpty) return 0;
  final painter = TextPainter(
    text: TextSpan(text: value, style: style),
    textDirection: TextDirection.ltr,
    textScaler: MediaQuery.textScalerOf(context),
  )..layout();
  return painter.width;
}

String? fileLanguage(String path) {
  final name = path.split('/').last;
  if (name == 'Makefile' || name == 'GNUmakefile') return 'makefile';
  if (name == 'Dockerfile') return 'dockerfile';
  return {
    'ts': 'typescript',
    'tsx': 'typescript',
    'mts': 'typescript',
    'cts': 'typescript',
    'js': 'javascript',
    'jsx': 'javascript',
    'mjs': 'javascript',
    'cjs': 'javascript',
    'py': 'python',
    'rs': 'rust',
    'go': 'go',
    'rb': 'ruby',
    'java': 'java',
    'kt': 'kotlin',
    'swift': 'swift',
    'c': 'c',
    'h': 'c',
    'cc': 'cpp',
    'cpp': 'cpp',
    'hpp': 'cpp',
    'cs': 'csharp',
    'php': 'php',
    'sh': 'bash',
    'bash': 'bash',
    'zsh': 'bash',
    'json': 'json',
    'yaml': 'yaml',
    'yml': 'yaml',
    'toml': 'ini',
    'ini': 'ini',
    'md': 'markdown',
    'html': 'xml',
    'xml': 'xml',
    'svelte': 'xml',
    'vue': 'xml',
    'css': 'css',
    'scss': 'scss',
    'less': 'less',
    'sql': 'sql',
    'lua': 'lua',
    'diff': 'diff',
    'patch': 'diff',
    'graphql': 'graphql',
    'r': 'r',
    'pl': 'perl',
    'mk': 'makefile',
  }[name.contains('.') ? name.split('.').last.toLowerCase() : ''];
}

class FilesPane extends StatefulWidget {
  const FilesPane({super.key, required this.controller, this.initialPath = ''});
  final LiveController controller;
  final String initialPath;
  @override
  State<FilesPane> createState() => _FilesPaneState();
}

class _FilesPaneState extends State<FilesPane> {
  late final FilesState state = FilesState(
    widget.controller,
    initialPath: widget.initialPath,
  );
  Size? imageSize;
  String? imageKey;
  @override
  void initState() {
    super.initState();
    state;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    state.setActive(TickerMode.valuesOf(context).enabled);
  }

  @override
  void dispose() {
    state.dispose();
    super.dispose();
  }

  Widget empty(String text) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
    child: Text(
      text,
      style: webText(
        context,
        size: 13,
        color: 'text.muted',
      ).copyWith(height: 1.5),
    ),
  );
  Widget crumb(String label, String path, bool last) => TextButton(
    onPressed: () => state.list(path, navigate: true),
    style: TextButton.styleFrom(
      minimumSize: Size.zero,
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      foregroundColor: palette(
        context,
      )[last ? 'text.primary' : 'text.secondary'],
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      textStyle: webText(
        context,
        size: 12.5,
        weight: last ? FontWeight.w500 : FontWeight.w400,
      ).copyWith(height: 15 / 12.5),
    ),
    child: Text(label),
  );
  double _directoryRowsWidth(Iterable<Json> entries, double availableWidth) {
    var width = availableWidth;
    final nameStyle = webText(context, size: 13).copyWith(height: 15 / 13);
    final sizeStyle = webText(
      context,
      size: 12,
      color: 'text.muted',
    ).copyWith(height: 14 / 12);
    for (final item in entries) {
      final name = '${item['name']}';
      final size = fileSize(item['size']);
      final nameWidth = _measurePanelText(context, name, nameStyle);
      final sizeWidth = _measurePanelText(context, size, sizeStyle);
      // The Web list's auto grid track takes the widest row's max-content
      // width. Keep the row's own 70% name cap inside that shared track.
      final contentWidth =
          15 + 8 + nameWidth + (size.isEmpty ? 0 : 8 + sizeWidth);
      width = math.max(width, contentWidth + 16);
    }
    return width;
  }

  Widget entry(
    String name,
    String kind,
    dynamic size,
    double rowWidth,
    VoidCallback onTap,
  ) => OverflowBox(
    alignment: Alignment.centerLeft,
    fit: OverflowBoxFit.deferToChild,
    minWidth: rowWidth,
    maxWidth: rowWidth,
    child: SizedBox(
      width: rowWidth,
      child: Opacity(
        opacity: kind == 'other' ? .45 : 1,
        child: TextButton(
          onPressed: kind == 'other' ? null : onTap,
          style: TextButton.styleFrom(
            minimumSize: Size.zero,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            foregroundColor: palette(context)['text.primary'],
          ),
          child: LayoutBuilder(
            builder: (context, bounds) => Row(
              children: [
                Icon(
                  kind == 'dir' ? LucideIcons.folder : LucideIcons.file,
                  size: 15,
                  color: palette(context)['text.muted'],
                ),
                const SizedBox(width: 8),
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: math.max(0, bounds.maxWidth * .7),
                  ),
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: webText(context, size: 13).copyWith(height: 15 / 13),
                  ),
                ),
                if (fileSize(size).isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      fileSize(size),
                      textDirection: TextDirection.rtl,
                      textAlign: TextAlign.right,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: webText(
                        context,
                        size: 12,
                        color: 'text.muted',
                      ).copyWith(height: 14 / 12),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    ),
  );
  String modified(dynamic value) {
    final date = value is num
        ? DateTime.fromMillisecondsSinceEpoch(value.toInt())
        : DateTime.tryParse('$value');
    if (date == null) return '';
    final local = date.toLocal(), locale = Localizations.localeOf(context);
    if (locale.languageCode == 'en' &&
        (locale.countryCode == null || locale.countryCode == 'US')) {
      final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
      return '${local.month}/${local.day}/${local.year}, $hour:${local.minute.toString().padLeft(2, '0')}:${local.second.toString().padLeft(2, '0')} ${local.hour < 12 ? 'AM' : 'PM'}';
    }
    final l = MaterialLocalizations.of(context);
    return '${l.formatCompactDate(date.toLocal())}, ${l.formatTimeOfDay(TimeOfDay.fromDateTime(date.toLocal()), alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context))}';
  }

  @override
  Widget build(BuildContext context) {
    AppI18n.watch(context);
    return AnimatedBuilder(
      animation: state,
      builder: (context, _) {
        final file = state.file;
        final crumbs = state.dir.isEmpty ? <String>[] : state.dir.split('/');
        final isMarkdown =
            file != null &&
            RegExp(
              r'\.(md|markdown|mdx)$',
              caseSensitive: false,
            ).hasMatch('${file['path']}');
        final hasPreview =
            file != null &&
            file['binary'] != true &&
            (isMarkdown || file['image'] != null);
        final showImage =
            file?['image'] != null &&
            (state.rendered || file?['binary'] == true);
        final nextImageKey = obj(file?['image'])['dataBase64'] as String?;
        if (imageKey != nextImageKey) {
          imageKey = nextImageKey;
          imageSize = null;
        }
        return LayoutBuilder(
          builder: (context, constraints) {
            final rowWidth = _directoryRowsWidth(
              state.entries,
              math.max(0, constraints.maxWidth - 24),
            );
            return ListView(
              key: const PageStorageKey('native-files-scroll'),
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
              children: [
                if (file == null) ...[
                  Row(
                    children: [
                      Expanded(
                        child: Semantics(
                          label: tr("Folder"),
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              children: [
                                crumb('workspace', '', crumbs.isEmpty),
                                for (var i = 0; i < crumbs.length; i++) ...[
                                  const SizedBox(width: 2),
                                  Icon(
                                    LucideIcons.chevronRight,
                                    size: 12,
                                    color: palette(context)['text.muted'],
                                  ),
                                  const SizedBox(width: 2),
                                  crumb(
                                    crumbs[i],
                                    crumbs.take(i + 1).join('/'),
                                    i == crumbs.length - 1,
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      WebIconButton(
                        LucideIcons.refreshCw,
                        tr("Refresh"),
                        size: 28,
                        iconSize: 15,
                        onPressed: state.loading ? null : state.reload,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (state.error != null) ...[
                    Semantics(
                      liveRegion: true,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: palette(context)['status.dangerSoft'],
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          state.error!,
                          style: webText(
                            context,
                            size: 12.5,
                            color: 'status.danger',
                          ).copyWith(height: 1.45),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  if (state.dir.isNotEmpty) ...[
                    entry(
                      '..',
                      'dir',
                      null,
                      rowWidth,
                      () => state.list(
                        crumbs.take(crumbs.length - 1).join('/'),
                        navigate: true,
                      ),
                    ),
                    const SizedBox(height: 1),
                  ],
                  for (final e in state.entries) ...[
                    entry(
                      '${e['name']}',
                      '${e['kind']}',
                      e['size'],
                      rowWidth,
                      () {
                        final path =
                            '${state.dir.isEmpty ? '' : '${state.dir}/'}${e['name']}';
                        if (e['kind'] == 'dir') {
                          state.list(path, navigate: true);
                        } else {
                          state.open(FileTarget(path));
                        }
                      },
                    ),
                    const SizedBox(height: 1),
                  ],
                  if (!state.loading &&
                      state.entries.isEmpty &&
                      state.error == null)
                    empty(tr("Empty folder.")),
                  if (state.truncated)
                    empty(tr("Showing the first 2,000 entries.")),
                ] else ...[
                  Row(
                    children: [
                      WebIconButton(
                        LucideIcons.arrowLeft,
                        tr("Back to folder"),
                        size: 28,
                        iconSize: 16,
                        onPressed: state.closeFile,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Tooltip(
                          message: '${file['path']}',
                          child: Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(text: '${file['path']}'),
                                if (state.line != null)
                                  TextSpan(
                                    text:
                                        ':${state.line}${state.endLine! > state.line! ? '-${state.endLine}' : ''}',
                                    style: TextStyle(
                                      color: palette(context)['text.faint'],
                                    ),
                                  ),
                              ],
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textDirection: TextDirection.rtl,
                            textAlign: TextAlign.left,
                            style: webText(
                              context,
                              size: 13,
                              weight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                      if (hasPreview) ...[
                        const SizedBox(width: 6),
                        WebIconButton(
                          state.rendered ? LucideIcons.code : LucideIcons.eye,
                          state.rendered
                              ? tr("Show source")
                              : tr("Show rendered"),
                          size: 28,
                          iconSize: 15,
                          onPressed: state.toggle,
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    tr("{0}{1} · modified {2}", [
                      fileSize(file['size']),
                      showImage && imageSize != null
                          ? ' · ${imageSize!.width.toInt()} × ${imageSize!.height.toInt()}'
                          : '',
                      modified(file['modifiedAt']),
                    ]),
                    style: webText(
                      context,
                      size: 12,
                      color: 'text.muted',
                    ).copyWith(height: 14 / 12),
                  ),
                  const SizedBox(height: 8),
                  if (showImage)
                    NativeFileImage(
                      key: ValueKey(imageKey),
                      image: obj(file['image']),
                      alt: '${file['path']}',
                      onSize: (size) {
                        if (mounted && imageKey == nextImageKey) {
                          setState(() => imageSize = size);
                        }
                      },
                    )
                  else if (file['binary'] == true)
                    empty(
                      file['imageTooLarge'] == true
                          ? tr("Image too large to preview.")
                          : tr("Binary file — not shown."),
                    )
                  else if (isMarkdown && state.rendered)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 2,
                        vertical: 4,
                      ),
                      child: RichTextBody(
                        '${file['content'] ?? ''}',
                        gateway: widget.controller.gateway,
                        fontSize: 14,
                        linkBase: '${file['path']}'
                            .split('/')
                            .take('${file['path']}'.split('/').length - 1)
                            .join('/'),
                        onFile: (href) {
                          final target = parseFileTarget(href);
                          if (target != null) state.open(target);
                        },
                      ),
                    )
                  else
                    NativeFileSource(
                      key: ValueKey(file['path']),
                      file: file,
                      line: state.line,
                      endLine: state.endLine,
                      focusRevision: state.focusRevision,
                    ),
                  if (file['truncated'] == true &&
                      !showImage &&
                      file['binary'] != true) ...[
                    const SizedBox(height: 8),
                    empty(tr("Showing the first 1 MB.")),
                  ],
                ],
              ],
            );
          },
        );
      },
    );
  }
}

class NativeFileSource extends StatefulWidget {
  const NativeFileSource({
    super.key,
    required this.file,
    this.line,
    this.endLine,
    this.focusRevision = 0,
  });
  final Json file;
  final int? line, endLine;
  final int focusRevision;
  @override
  State<NativeFileSource> createState() => _NativeFileSourceState();
}

class _NativeFileSourceState extends State<NativeFileSource> {
  final vertical = ScrollController(), horizontal = ScrollController();
  String? cachedSource, cachedLanguage;
  Object? cachedColors;
  TextSpan? highlighted;
  @override
  void initState() {
    super.initState();
    focus();
  }

  @override
  void didUpdateWidget(covariant NativeFileSource old) {
    super.didUpdateWidget(old);
    if (old.focusRevision != widget.focusRevision) focus();
  }

  void focus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || widget.line == null || !vertical.hasClients) return;
      final height = 18.6 * MediaQuery.textScalerOf(context).scale(1);
      vertical.jumpTo(
        (8 +
                (widget.line! - 1) * height -
                vertical.position.viewportDimension / 3)
            .clamp(0, vertical.position.maxScrollExtent),
      );
      Scrollable.ensureVisible(
        context,
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      );
    });
  }

  @override
  void dispose() {
    vertical.dispose();
    horizontal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    AppI18n.watch(context);
    final source = '${widget.file['content'] ?? ''}',
        language = fileLanguage('${widget.file['path']}') ?? '';
    final colors = palette(context), scaler = MediaQuery.textScalerOf(context);
    final style = TextStyle(
      fontFamily: 'monospace',
      fontSize: 12,
      height: 1.55,
      letterSpacing: 0,
      color: colors['code.text'],
    );
    if (source != cachedSource ||
        language != cachedLanguage ||
        colors != cachedColors) {
      highlighted = highlightCode(source, language, colors, baseStyle: style);
      cachedSource = source;
      cachedLanguage = language;
      cachedColors = colors;
    }
    final count = source.replaceFirst(RegExp(r'\n$'), '').split('\n').length;
    final text = TextPainter(
      text: TextSpan(text: source, style: style),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
    )..layout();
    final textWidth = text.width + 1;
    text.dispose();
    final lineHeight = scaler.scale(12) * 1.55,
        height = count * lineHeight + 16;
    final gutter = TextPainter(
      text: TextSpan(text: '$count', style: style),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
    )..layout();
    final gutterWidth = gutter.width + 22;
    gutter.dispose();
    return Container(
      decoration: BoxDecoration(
        color: colors['code.bg'],
        borderRadius: BorderRadius.circular(12),
        boxShadow: [BoxShadow(color: colors['web.line'], spreadRadius: 1)],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          height: math.min(
            height,
            math.max(80, MediaQuery.sizeOf(context).height - 190),
          ),
          child: SingleChildScrollView(
            controller: vertical,
            child: SizedBox(
              height: height,
              child: Stack(
                children: [
                  if (widget.line != null)
                    Positioned(
                      left: 0,
                      right: 0,
                      top: 8 + (widget.line! - 1) * lineHeight,
                      height:
                          ((widget.endLine ?? widget.line!) -
                              widget.line! +
                              1) *
                          lineHeight,
                      child: ColoredBox(color: colors['web.accent-soft']),
                    ),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ExcludeSemantics(
                        child: SizedBox(
                          width: gutterWidth,
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
                            child: Text(
                              List.generate(
                                count,
                                (i) => '${i + 1}',
                              ).join('\n'),
                              textAlign: TextAlign.right,
                              style: style.copyWith(
                                color: colors['text.faint'],
                              ),
                            ),
                          ),
                        ),
                      ),
                      Expanded(
                        child: LayoutBuilder(
                          builder: (context, bounds) => SingleChildScrollView(
                            controller: horizontal,
                            scrollDirection: Axis.horizontal,
                            child: SizedBox(
                              width: math.max(textWidth + 12, bounds.maxWidth),
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(0, 8, 12, 8),
                                child: SelectableText.rich(
                                  highlighted!,
                                  style: style,
                                  textDirection: TextDirection.ltr,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class NativeFileImage extends StatefulWidget {
  const NativeFileImage({
    super.key,
    required this.image,
    required this.alt,
    required this.onSize,
  });
  final Json image;
  final String alt;
  final ValueChanged<Size?> onSize;
  @override
  State<NativeFileImage> createState() => _NativeFileImageState();
}

class _NativeFileImageState extends State<NativeFileImage> {
  Uint8List? bytes;
  Size? size;
  bool failed = false;
  bool get isSvg => widget.image['mimeType'] == 'image/svg+xml';
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      bytes = base64Decode('${widget.image['dataBase64']}');
      if (isSvg) {
        final picture = await vg.loadPicture(SvgBytesLoader(bytes!), null);
        try {
          size = svgImageSize(utf8.decode(bytes!));
        } finally {
          picture.picture.dispose();
        }
      } else {
        final codec = await ui.instantiateImageCodec(bytes!);
        try {
          final frame = await codec.getNextFrame();
          size = Size(
            frame.image.width.toDouble(),
            frame.image.height.toDouble(),
          );
          frame.image.dispose();
        } finally {
          codec.dispose();
        }
      }
    } catch (_) {
      failed = true;
    }
    if (size != null && (size!.width <= 0 || size!.height <= 0)) failed = true;
    if (!mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onSize(failed ? null : size);
    });
  }

  @override
  Widget build(BuildContext context) {
    AppI18n.watch(context);
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(color: palette(context)['web.line'], spreadRadius: 1),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: CustomPaint(
          painter: _Checkerboard(palette(context)['web.bg-hover']),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: math.max(80, MediaQuery.sizeOf(context).height - 190),
            ),
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: LayoutBuilder(
                  builder: (context, bounds) {
                    if (failed) {
                      return Text(
                        tr("Unable to preview {0}.", [widget.alt]),
                        style: webText(
                          context,
                          size: 13,
                          color: 'status.danger',
                        ),
                      );
                    }
                    if (size == null || bytes == null) {
                      return const SizedBox(height: 24);
                    }
                    final width = math.min(size!.width, bounds.maxWidth),
                        height = size!.height * width / size!.width;
                    return Center(
                      child: SizedBox(
                        width: width,
                        height: height,
                        child: isSvg
                            ? SvgPicture.memory(
                                bytes!,
                                semanticsLabel: widget.alt,
                                width: width,
                                height: height,
                                errorBuilder: (_, _, _) => Text(
                                  tr("Unable to preview {0}.", [widget.alt]),
                                ),
                              )
                            : Image.memory(
                                bytes!,
                                semanticLabel: widget.alt,
                                width: width,
                                height: height,
                                fit: BoxFit.contain,
                              ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Checkerboard extends CustomPainter {
  _Checkerboard(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    for (var y = 0.0; y < size.height; y += 8) {
      for (var x = 0.0; x < size.width; x += 8) {
        if ((x ~/ 8 + y ~/ 8).isEven) {
          canvas.drawRect(Rect.fromLTWH(x, y, 8, 8), paint);
        }
      }
    }
  }

  @override
  bool shouldRepaint(_Checkerboard old) => old.color != color;
}
