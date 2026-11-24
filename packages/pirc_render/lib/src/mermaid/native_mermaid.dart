import '../render_l10n.dart';
import 'package:flutter/material.dart';
import '../render_theme.dart';
import 'flowchart.dart';
import 'requirement_parser.dart';
import 'requirement_rendering.dart';
import 'c4_parser.dart';
import 'c4_layout.dart';
import 'c4_rendering.dart';
import 'mindmap_parser.dart';
import 'mindmap_rendering.dart';
import 'timeline_parser.dart';
import 'timeline_rendering.dart';
import 'sequence.dart';
import 'pie.dart';
import 'class_diagram.dart';
import 'state_diagram.dart';
import 'er_diagram.dart';
import 'er_rendering.dart';
import 'gantt_parser.dart';
import 'gantt_rendering.dart';
import 'quadrant_parser.dart';
import 'quadrant_rendering.dart';
import 'xy_parser.dart';
import 'xy_rendering.dart';
import 'journey_parser.dart';
import 'journey_rendering.dart';
import 'kanban_parser.dart';
import 'kanban_rendering.dart';
import 'sankey_parser.dart';
import 'sankey_rendering.dart';
import 'd3_sankey_layout.dart';
import 'block_parser.dart';
import 'block_layout.dart';
import 'block_rendering.dart';
import 'git_graph_parser.dart';
import 'git_graph_rendering.dart';
import 'packet_parser.dart';
import 'packet_rendering.dart';
import 'radar_parser.dart';
import 'radar_rendering.dart';
import 'architecture_parser.dart';
import 'architecture_rendering.dart';

/// Mermaid fences share the web container and defer diagrams until streaming
/// ends. Every successful figure is Flutter paint/layout; unsupported grammar
/// remains visibly identified, with its source intact.
class NativeMermaid extends StatelessWidget {
  const NativeMermaid({
    super.key,
    required this.source,
    this.ready = true,
    this.clock,
    this.fontSize = 15,
    this.lineHeight = 1.65,
  });
  final String source;
  final DateTime? clock;
  final bool ready;
  final double fontSize, lineHeight;

  @override
  Widget build(BuildContext context) {
    RenderL10n.watch(context);
    final colors = Theme.of(context).extension<RenderColors>()!;
    final dark = Theme.of(context).brightness == Brightness.dark;
    Widget? figure;
    String? error;
    if (ready) {
      try {
        final kind = source
            .split('\n')
            .map((line) => line.trim())
            .firstWhere(
              (line) => line.isNotEmpty && !line.startsWith('%%'),
              orElse: () => '',
            );
        if (RegExp(r'^(flowchart|graph)\s').hasMatch(kind)) {
          parseNativeMermaidFlowchart(source);
          figure = NativeMermaidFlowchart(source: source, dark: dark);
        } else if (RegExp(
          r'^requirementDiagram(?:\s|$)',
          caseSensitive: false,
        ).hasMatch(kind)) {
          final diagram = parseNativeMermaidRequirement(source);
          layoutNativeMermaidRequirement(diagram, dark: dark);
          figure = NativeMermaidRequirement(diagram: diagram, dark: dark);
        } else if (RegExp(r'^packet(?:-beta)?(?:\s|$)').hasMatch(kind)) {
          figure = NativeMermaidPacket(
            diagram: parseNativeMermaidPacket(source),
            dark: dark,
          );
        } else if (RegExp(r'^radar-beta(?:\s|$)').hasMatch(kind)) {
          figure = NativeMermaidRadar(
            diagram: parseNativeMermaidRadar(source),
            dark: dark,
          );
        } else if (RegExp(r'^architecture(?:-beta)?(?:\s|$)').hasMatch(kind)) {
          figure = NativeMermaidArchitecture(
            diagram: parseNativeMermaidArchitecture(source),
            dark: dark,
          );
        } else if (RegExp(
          r'^C4(?:Context|Container|Component|Dynamic|Deployment)(?:\s|$)',
        ).hasMatch(kind)) {
          final diagram = parseNativeMermaidC4(source);
          validateNativeC4Styles(diagram);
          layoutNativeMermaidC4(
            diagram,
            screenWidth: MediaQuery.sizeOf(context).width,
            resolveColor: nativeC4Color,
          );
          figure = NativeMermaidC4(diagram: diagram, dark: dark);
        } else if (RegExp(
          r'^gitGraph\b',
          caseSensitive: false,
        ).hasMatch(kind)) {
          final diagram = parseNativeMermaidGitGraph(source);
          figure = NativeMermaidGitGraph(diagram: diagram, dark: dark);
        } else if (kind.toLowerCase() == 'mindmap') {
          final diagram = parseNativeMermaidMindmap(source);
          layoutNativeMermaidMindmap(
            diagram,
            width: MediaQuery.sizeOf(context).width,
            dark: dark,
            fontFamily:
                Theme.of(
                  context,
                ).extension<NativeMindmapTypography>()?.fontFamily ??
                Theme.of(context).textTheme.bodyMedium?.fontFamily,
            letterSpacing:
                Theme.of(
                  context,
                ).extension<NativeMindmapTypography>()?.labelLetterSpacing ??
                0,
          );
          figure = NativeMermaidMindmap(diagram: diagram, dark: dark);
        } else if (kind.startsWith('timeline')) {
          final diagram = parseNativeMermaidTimeline(source);
          final typography =
              Theme.of(context).extension<NativeTimelineTypography>() ??
              const NativeTimelineTypography();
          layoutNativeMermaidTimeline(
            diagram,
            width: MediaQuery.sizeOf(context).width,
            dark: dark,
            fontFamily:
                typography.fontFamily ??
                Theme.of(context).textTheme.bodyMedium?.fontFamily,
            letterSpacing: typography.letterSpacing,
            titleFontSize: typography.titleFontSize,
            titleLetterSpacing: typography.titleLetterSpacing,
            svgXHeight: typography.svgXHeight,
          );
          figure = NativeMermaidTimeline(diagram: diagram, dark: dark);
        } else if (kind == 'sequenceDiagram') {
          parseNativeMermaidSequence(source);
          figure = NativeMermaidSequence(source: source, dark: dark);
        } else if (kind == 'classDiagram' || kind == 'classDiagram-v2') {
          parseNativeMermaidClassDiagram(source);
          figure = NativeMermaidClassDiagram(source: source, dark: dark);
        } else if (kind == 'erDiagram') {
          parseNativeMermaidErDiagram(source);
          figure = NativeMermaidErDiagram(source: source, dark: dark);
        } else if (kind == 'stateDiagram-v2') {
          parseNativeMermaidStateDiagram(source);
          figure = NativeMermaidStateDiagram(source: source, dark: dark);
        } else if (kind == 'quadrantChart') {
          final diagram = parseNativeMermaidQuadrant(source);
          layoutNativeMermaidQuadrant(
            diagram,
            width: MediaQuery.sizeOf(context).width,
            dark: dark,
            fontFamily: Theme.of(context).textTheme.bodyMedium?.fontFamily,
          );
          figure = NativeMermaidQuadrant(diagram: diagram, dark: dark);
        } else if (RegExp(r'^xychart(?:-beta)?(?:\s|$)').hasMatch(kind)) {
          final diagram = parseNativeMermaidXYChart(source);
          layoutNativeMermaidXYChart(
            diagram,
            width: MediaQuery.sizeOf(context).width,
            dark: dark,
            fontFamily: Theme.of(context).textTheme.bodyMedium?.fontFamily,
          );
          figure = NativeMermaidXYChart(diagram: diagram, dark: dark);
        } else if (kind == 'gantt') {
          final diagram = parseNativeMermaidGantt(source, clock: clock);
          final layout = layoutNativeMermaidGantt(
            diagram,
            width: MediaQuery.sizeOf(context).width,
            fontFamily: Theme.of(context).textTheme.bodyMedium?.fontFamily,
          );
          figure = NativeMermaidGantt(
            diagram: diagram,
            layout: layout,
            dark: dark,
            clock: clock,
          );
        } else if (RegExp(r'^pie(?:\s|$)').hasMatch(kind)) {
          figure = NativeMermaidPie(
            diagram: parseNativeMermaidPie(source),
            dark: dark,
          );
        } else if (RegExp(r'^block(?:-beta)?$').hasMatch(kind)) {
          final diagram = parseNativeMermaidBlock(source);
          layoutNativeMermaidBlock(
            diagram,
            width: MediaQuery.sizeOf(context).width,
            dark: dark,
            fontFamily: Theme.of(context).textTheme.bodyMedium?.fontFamily,
          );
          figure = NativeMermaidBlockChart(diagram: diagram, dark: dark);
        } else if (kind == 'kanban') {
          final board = parseNativeMermaidKanban(source);
          layoutNativeMermaidKanban(
            board,
            width: MediaQuery.sizeOf(context).width,
            dark: dark,
            fontFamily: Theme.of(context).textTheme.bodyMedium?.fontFamily,
          );
          figure = Align(
            alignment: Alignment.topCenter,
            child: NativeMermaidKanban(board: board, dark: dark),
          );
        } else if (RegExp(r'^sankey(?:-beta)?$').hasMatch(kind)) {
          final diagram = parseNativeMermaidSankey(source);
          layoutNativeMermaidSankey(
            diagram,
            dark: dark,
            fontFamily: Theme.of(context).textTheme.bodyMedium?.fontFamily,
          );
          figure = Align(
            alignment: Alignment.topCenter,
            child: NativeMermaidSankey(diagram: diagram, dark: dark),
          );
        } else if (kind.toLowerCase() == 'journey') {
          figure = NativeMermaidJourney(
            diagram: parseNativeMermaidJourney(source),
            dark: dark,
          );
        } else {
          throw FormatException(
            tr(
              "This diagram type is not yet supported by the native Mermaid renderer",
            ),
          );
        }
      } on FormatException catch (e) {
        error = 'Mermaid: ${e.message.split('\n').first}';
      }
    }
    return Container(
      key: const ValueKey('native-mermaid-block'),
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors['web.bg'],
        border: Border.all(color: colors['web.line-dark']),
        borderRadius: BorderRadius.circular(12),
      ),
      child:
          (figure == null
              ? null
              : _MermaidSvgLineBox(
                  fontSize: fontSize,
                  lineHeight: lineHeight,
                  child: figure,
                )) ??
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Text(
                  source,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 13,
                    height: 1.6,
                    letterSpacing: 0,
                    color: colors['text.secondary'],
                  ),
                ),
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    error,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.65,
                      color: colors['status.danger'],
                      letterSpacing: 0,
                    ),
                  ),
                ),
            ],
          ),
    );
  }
}

/// The browser's inline SVG keeps its own pixel-sized labels as surrounding
/// Markdown text scales. Match that line box without WidgetSpan applying a
/// second transform and extra leading above the figure.
class _MermaidSvgLineBox extends StatelessWidget {
  const _MermaidSvgLineBox({
    required this.child,
    required this.fontSize,
    required this.lineHeight,
  });
  final Widget child;
  final double fontSize, lineHeight;
  @override
  Widget build(BuildContext context) {
    RenderL10n.watch(context);
    final scaler = MediaQuery.textScalerOf(context);
    final text = TextPainter(
      text: TextSpan(
        text: ' ',
        style: TextStyle(
          fontFamily: DefaultTextStyle.of(context).style.fontFamily,
          fontSize: fontSize,
          letterSpacing: 0,
        ),
      ),
      textScaler: scaler,
      textDirection: Directionality.of(context),
    )..layout();
    final extra =
        (scaler.scale(fontSize) * lineHeight - text.preferredLineHeight).clamp(
          0.0,
          double.infinity,
        );
    text.dispose();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        MediaQuery.withNoTextScaling(child: child),
        SizedBox(height: extra),
      ],
    );
  }
}
