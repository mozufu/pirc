import '../l10n/app_i18n.dart';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'common.dart';
import 'gateway.dart';
import 'web_controls.dart';
import 'environment_switch_card.dart';

/// Exact request snapshot, not a reconstruction from current configuration.
class ContextPane extends StatefulWidget {
  const ContextPane({
    super.key,
    required this.controller,
    required this.onFile,
  });
  final LiveController controller;
  final ValueChanged<String> onFile;
  @override
  State<ContextPane> createState() => _ContextPaneState();
}

class _ContextPaneState extends State<ContextPane> {
  Json? value;
  bool active = true, loading = false;
  String? session, origin, client, runner, error;
  String copied = '';
  int request = 0;
  Timer? refresh;
  StreamSubscription<Json>? events;
  final expanded = <String>{};
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(observe);
    events = widget.controller.gateway.events.listen((e) {
      if (active &&
          e['sessionId'] == session &&
          e['type'] == 'panelChange' &&
          (e['data'] as List? ?? []).contains('context')) {
        schedule();
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = TickerMode.valuesOf(context).enabled;
    final shown = next && !active;
    active = next;
    if (!active) {
      request++;
      loading = false;
      refresh?.cancel();
    }
    observe(force: shown);
  }

  void schedule() {
    refresh?.cancel();
    refresh = Timer(const Duration(milliseconds: 150), load);
  }

  void observe({bool force = false}) {
    final c = widget.controller;
    final nextRunner =
        '${c.state['runnerStatus']}:${obj(c.state['run'])['status']}';
    final changed =
        session != c.sessionId || origin != c.origin || client != c.clientId;
    if (changed) {
      ++request;
      session = c.sessionId;
      origin = c.origin;
      client = c.clientId;
      setState(() {
        value = null;
        error = null;
      });
      copied = '';
      expanded.clear();
      refresh?.cancel();
    }
    if (active &&
        session != null &&
        (changed || runner != nextRunner || force)) {
      unawaited(load());
    }
    runner = nextRunner;
  }

  Future<void> load() async {
    final id = session;
    if (!active || id == null) return;
    final read = ++request;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final next = await widget.controller.gateway.request(
        '${sessionPath(id)}/panel/context',
      );
      if (!mounted || read != request || !active) return;
      setState(() => value = next);
    } catch (e) {
      if (mounted && read == request && active) {
        setState(
          () => error = e is PlatformException && e.message != null
              ? e.message
              : LiveController.describe(e),
        );
      }
    } finally {
      if (mounted && read == request && active) setState(() => loading = false);
    }
  }

  @override
  void dispose() {
    request++;
    refresh?.cancel();
    unawaited(events?.cancel());
    widget.controller.removeListener(observe);
    super.dispose();
  }

  String tokens(dynamic n) => ((n as num?) ?? 0)
      .round()
      .toString()
      .replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+(?!\d))'), (m) => '${m[1]},');
  String timestamp(dynamic n) {
    if (n is! num) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(n.toInt());
    final hour = d.hour % 12 == 0 ? 12 : d.hour % 12;
    return '${d.month}/${d.day}/${d.year}, $hour:${d.minute.toString().padLeft(2, '0')}:${d.second.toString().padLeft(2, '0')} ${d.hour < 12 ? 'AM' : 'PM'}';
  }

  Widget paragraph(String text, {bool meta = false, bool alert = false}) =>
      _ContextBlock(
        before: _contextEm(context, meta ? 12 : 16),
        after: _contextEm(context, meta ? 12 : 16),
        child: SelectableText(
          text,
          style: webText(
            context,
            size: meta ? 12 : 16,
            color: alert
                ? 'status.danger'
                : meta
                ? 'text.secondary'
                : 'text.primary',
          ).copyWith(height: kTextHeightNone),
        ),
      );
  Widget statusParagraph(String text) {
    final block = paragraph(text) as _ContextBlock;
    return _ContextBlock(
      before: block.before,
      after: block.after,
      child: Semantics(liveRegion: true, child: block.child),
    );
  }

  Widget pre(String text) => _ContextBlock(
    before: _contextEm(context, 12),
    after: _contextEm(context, 12),
    empty: text.isEmpty,
    child: SelectableText(
      text,
      style: TextStyle(
        fontFamily: 'monospace',
        fontSize: 12,
        height: 1.5,
        color: palette(context)['text.primary'],
      ),
    ),
  );
  Widget details(
    String key,
    String title,
    dynamic count,
    List<Widget> children, {
    bool frozen = false,
  }) => Container(
    padding: const EdgeInsets.symmetric(vertical: 8),
    decoration: BoxDecoration(
      border: Border(bottom: BorderSide(color: palette(context)['web.line'])),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => setState(
            () => expanded.contains(key)
                ? expanded.remove(key)
                : expanded.add(key),
          ),
          child: Semantics(
            button: true,
            expanded: expanded.contains(key),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 4, right: 4),
                  child: CustomPaint(
                    size: const Size(10, 10),
                    painter: _Disclosure(
                      expanded.contains(key),
                      palette(context)['text.primary'],
                    ),
                  ),
                ),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(text: title),
                        TextSpan(
                          text: tr(" ~{0} tokens", [tokens(count)]),
                          style: webText(
                            context,
                            size: 12,
                            color: 'text.secondary',
                          ).copyWith(height: kTextHeightNone),
                        ),
                        if (frozen)
                          WidgetSpan(
                            alignment: PlaceholderAlignment.middle,
                            child: Container(
                              margin: const EdgeInsets.only(left: 6),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 5,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color: palette(context)['web.line'],
                                ),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                tr("Frozen"),
                                style: webText(
                                  context,
                                  size: 10,
                                ).copyWith(height: kTextHeightNone),
                              ),
                            ),
                          ),
                      ],
                    ),
                    style: webText(
                      context,
                      size: 16,
                    ).copyWith(height: kTextHeightNone),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (expanded.contains(key))
          LayoutBuilder(
            builder: (context, bounds) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: _contextFlow(children, bounds.maxWidth),
            ),
          ),
      ],
    ),
  );
  @override
  Widget build(BuildContext context) {
    AppI18n.watch(context);
    final snapshot = obj(value?['snapshot']),
        usage = obj(snapshot['usage']),
        model = obj(snapshot['model']);
    final sections = rows(snapshot['sections']),
        tools = rows(snapshot['tools']);
    final scale = (usage['scale'] as num?) ?? 1;
    final segments = <String, double>{
      for (final e in obj(usage['buckets']).entries)
        e.key: ((e.value as num?) ?? 0) * scale.toDouble(),
      'free': ((usage['remaining'] as num?) ?? 0).toDouble(),
    };
    final total = segments.values.fold(0.0, (a, b) => a + b);
    final colors = {
      'system': const Color(0xff6f8de0),
      'tools': const Color(0xffa37bcd),
      'messages': const Color(0xff49a18d),
      'memory': const Color(0xffcf9c50),
      'free': palette(context)['web.line'],
    };
    return _ContextList(
      children: [
        _ContextActions(
          tr("Context"),
          18.72,
          1,
          WebButton(
            tr("Refresh"),
            height: 36,
            fontSize: 14,
            onPressed: loading ? null : load,
          ),
        ),
        if (error != null)
          _ContextBlock(
            before: _contextEm(context, 16),
            after: _contextEm(context, 16),
            child: Semantics(
              liveRegion: true,
              child: (paragraph(error!, alert: true) as _ContextBlock).child,
            ),
          ),
        if (loading && snapshot.isEmpty)
          statusParagraph(tr("Loading context…")),
        if (snapshot.isNotEmpty) ...[
          if (value?['agentRunning'] != true || value?['source'] == 'snapshot')
            _ContextBlock(
              before: _contextEm(context, 16),
              after: _contextEm(context, 16),
              child: Semantics(
                liveRegion: true,
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: palette(context)['web.bg-hover'],
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    tr(
                      "Saved snapshot{0}. This is the last request, not current configuration.",
                      [
                        value?['agentRunning'] != true
                            ? ' — agent stopped'
                            : '',
                      ],
                    ),
                    style: webText(
                      context,
                      size: 16,
                    ).copyWith(height: kTextHeightNone),
                  ),
                ),
              ),
            ),
          paragraph(
            '${model['provider']} / ${model['id']}\n${timestamp(snapshot['takenAt'])}',
            meta: true,
          ),
          Semantics(
            label: tr("Context usage: {0}", [
              segments.entries
                  .map((e) => '${e.key} ${tokens(e.value)}')
                  .join(', '),
            ]),
            image: true,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: SizedBox(
                height: 14,
                child: LayoutBuilder(
                  builder: (context, b) => Row(
                    children: [
                      for (final e in segments.entries)
                        Tooltip(
                          message: '${e.key}: ${tokens(e.value)}',
                          child: Container(
                            width: total == 0
                                ? 0
                                : b.maxWidth * e.value / total,
                            color: colors[e.key],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          _ContextBlock(
            before: _contextEm(context, 12),
            after: _contextEm(context, 12),
            child: Wrap(
              spacing: 12,
              runSpacing: 6,
              children: [
                for (final e in segments.entries)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(width: 8, height: 8, color: colors[e.key]),
                      const SizedBox(width: 4),
                      Text(
                        '${e.key}: ${tokens(e.value)}',
                        style: webText(
                          context,
                          size: 12,
                        ).copyWith(height: kTextHeightNone),
                      ),
                    ],
                  ),
              ],
            ),
          ),
          paragraph(
            tr(
              "Estimated input: {0} · Reported input: {1}\nContext window: {2}",
              [
                tokens(usage['estimatedInput']),
                usage['reportedInput'] == null
                    ? 'not available'
                    : tokens(usage['reportedInput']),
                model['contextWindow'] == null || model['contextWindow'] == 0
                    ? 'unknown'
                    : tokens(model['contextWindow']),
              ],
            ),
            meta: true,
          ),
          paragraph(
            tr(
              "Bucket sizes are estimates{0}. Memory is observations/reflections within messages, not an extra copy. System memory stays in system.",
              [
                usage['reportedInput'] == null
                    ? ''
                    : ' scaled to reported input (including cache)',
              ],
            ),
            meta: true,
          ),
          _ContextActions(
            tr("System sections"),
            16,
            1.33,
            WebButton(
              tr("Copy all"),
              height: 36,
              fontSize: 14,
              onPressed: () async {
                final revision = request;
                try {
                  await Clipboard.setData(
                    ClipboardData(
                      text: sections
                          .map((s) => '${s['text'] ?? ''}')
                          .where((s) => s.isNotEmpty)
                          .join('\n\n'),
                    ),
                  );
                  if (mounted && revision == request) {
                    setState(() => copied = tr("Copied system prompt."));
                  }
                } catch (_) {
                  if (mounted && revision == request) {
                    setState(
                      () => copied = tr(
                        "Unable to copy. Select the expanded section text instead.",
                      ),
                    );
                  }
                }
              },
            ),
          ),
          _ContextBlock(
            before: _contextEm(context, 16),
            after: _contextEm(context, 16),
            empty: copied.isEmpty,
            child: Semantics(
              liveRegion: true,
              child: copied.isEmpty
                  ? const SizedBox.shrink()
                  : (paragraph(copied) as _ContextBlock).child,
            ),
          ),
          for (final (i, section) in sections.indexed)
            details(
              '$i:${section['id']}',
              '${section['title']}',
              section['estimatedTokens'],
              [
                if (section['filePath'] != null)
                  _ContextBlock(
                    before: _contextEm(context, 12),
                    after: _contextEm(context, 12),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        onPressed: () =>
                            widget.onFile('${section['filePath']}'),
                        style: TextButton.styleFrom(
                          padding: EdgeInsets.zero,
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: Text(
                          '${section['source']}',
                          style: webText(
                            context,
                            size: 12,
                            color: 'accent.default',
                          ).copyWith(height: kTextHeightNone),
                        ),
                      ),
                    ),
                  )
                else
                  paragraph('${section['source']}', meta: true),
                pre('${section['text'] ?? ''}'),
              ],
              frozen: section['frozen'] == true,
            ),
          _ContextBlock(
            before: _contextEm(context, 16, 1.33),
            after: _contextEm(context, 16, 1.33),
            child: Text(
              'Tools (${tools.length})',
              style: webText(
                context,
                size: 16,
                weight: FontWeight.w700,
              ).copyWith(height: kTextHeightNone),
            ),
          ),
          for (final tool in tools)
            details(
              'tool:${tool['name']}',
              '${tool['name']}',
              tool['estimatedTokens'],
              [
                pre('${tool['description']}'),
                pre(
                  const JsonEncoder.withIndent(
                    '  ',
                  ).convert(tool['parameters']),
                ),
              ],
            ),
        ],
        // Throwaway placement of the switching interface (T4), after the
        // pinned context content.
        EnvironmentSwitchCard(controller: widget.controller),
      ],
    );
  }
}

class _Disclosure extends CustomPainter {
  _Disclosure(this.open, this.color);
  final bool open;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path();
    if (open) {
      path.moveTo(0, 2);
      path.lineTo(10, 2);
      path.lineTo(5, 9);
    } else {
      path.moveTo(1, 0);
      path.lineTo(9, 5);
      path.lineTo(1, 10);
    }
    canvas.drawPath(path..close(), Paint()..color = color);
  }

  @override
  bool shouldRepaint(_Disclosure old) => old.open != open || old.color != color;
}

// UA block margins use the block's own font size. CSS layout units retain
// fractional margins, while native line boxes come from the active font.
double _contextEm(BuildContext context, double size, [double multiple = 1]) =>
    (MediaQuery.textScalerOf(context).scale(size) * multiple * 64).floor() / 64;

class _ContextBlock extends StatelessWidget {
  const _ContextBlock({
    required this.child,
    this.before = 0,
    this.after = 0,
    this.empty = false,
  });
  final Widget child;
  final double before, after;
  final bool empty;
  @override
  Widget build(BuildContext context) {
    AppI18n.watch(context);
    return Padding(
      padding: EdgeInsets.only(top: before, bottom: after),
      child: child,
    );
  }
}

class _ContextActions extends StatelessWidget {
  const _ContextActions(this.title, this.fontSize, this.marginEm, this.button);
  final String title;
  final double fontSize, marginEm;
  final WebButton button;
  TextStyle heading(BuildContext context) => webText(
    context,
    size: fontSize,
    weight: FontWeight.w700,
  ).copyWith(height: kTextHeightNone);
  double measure(BuildContext context, String text, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textScaler: MediaQuery.textScalerOf(context),
      textDirection: Directionality.of(context),
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }

  double width(BuildContext context, double available) {
    final minimum = title
        .split(RegExp(r'\s+'))
        .map((word) => measure(context, word, heading(context)))
        .fold(0.0, (a, b) => a > b ? a : b);
    final buttonWidth =
        measure(
          context,
          button.label,
          webText(
            context,
            size: button.fontSize,
            weight: FontWeight.w500,
          ).copyWith(height: kTextHeightNone),
        ) +
        button.horizontalPadding * 2;
    final required = minimum + 8 + buttonWidth;
    return available > required ? available : required;
  }

  @override
  Widget build(BuildContext context) {
    AppI18n.watch(context);
    return Row(
      children: [
        Expanded(
          child: Padding(
            padding: EdgeInsets.symmetric(
              vertical: _contextEm(context, fontSize, marginEm),
            ),
            child: Text(title, style: heading(context)),
          ),
        ),
        const SizedBox(width: 8),
        button,
      ],
    );
  }
}

List<Widget> _contextFlow(
  List<Widget> children,
  double width, [
  BuildContext? context,
]) {
  final result = <Widget>[];
  var pending = 0.0;
  for (final widget in children) {
    final block = widget is _ContextBlock
        ? widget
        : _ContextBlock(child: widget);
    final gap = pending > block.before ? pending : block.before;
    if (block.empty) {
      pending = gap > block.after ? gap : block.after;
      result.add(block.child);
      continue;
    }
    if (gap > 0) result.add(SizedBox(height: gap));
    final childWidth = block.child is _ContextActions && context != null
        ? (block.child as _ContextActions).width(context, width)
        : width;
    result.add(
      Align(
        alignment: Alignment.topLeft,
        child: SizedBox(width: childWidth, child: block.child),
      ),
    );
    pending = block.after;
  }
  if (pending > 0) result.add(SizedBox(height: pending));
  return result;
}

class _ContextList extends StatelessWidget {
  const _ContextList({required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) {
    AppI18n.watch(context);
    return LayoutBuilder(
      builder: (context, bounds) {
        final width = (bounds.maxWidth - 24).clamp(0.0, double.infinity);
        final extent = children
            .whereType<_ContextActions>()
            .map((action) => action.width(context, width))
            .fold(width, (a, b) => a > b ? a : b);
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: extent + 24,
            height: bounds.maxHeight,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
              children: _contextFlow(children, width, context),
            ),
          ),
        );
      },
    );
  }
}
