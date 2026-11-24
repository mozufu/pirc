// UI integrity of the native renderer, measured on real layout and paint.
//
// Each case renders hostile markup (fixed/absolute positioning, negative
// offsets, transforms, huge sizes, transparent overlays, Mermaid style
// directives) inside a chat-like column that also holds app UI: an earlier card
// and a later approval card in the same scroll view, and a composer outside it.
// A case fails when the content paints over anything outside its own box (the
// app's colors are sampled from a rendered image) or when any render object of
// the message is on the hit path of a tap outside the box. A positive control
// proves the probe notices a real escape.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_mobile/live/common.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_render/src/html_document_content.dart';
import 'dart:convert';
import 'package:pirc_mobile/live/gateway.dart';

import 'live_test.dart' show theme;

/// A chat-like column: an untrusted message, then app UI that content must not
/// be able to cover or intercept (an approval card in the same scroll view,
/// and a composer outside it).
class _Harness {
  _Harness(this.html, {this.leak = false});
  final String html;

  /// Positive control: lets the message paint and hit-test outside its box so
  /// the probe has to notice.
  final bool leak;
  final captureKey = GlobalKey();
  final messageKey = GlobalKey();
  final approveKey = const ValueKey('approve');
  final earlierKey = const ValueKey('earlier');
  final earlierCardKey = const ValueKey('earlier-card');
  final approveCardKey = const ValueKey('approve-card');
  var earlier = 0;
  final sendKey = const ValueKey('send');
  final composerKey = const ValueKey('composer');
  var approved = 0, sent = 0;

  Widget build(NativeDocumentWindows windows, Gateway gateway) => MaterialApp(
    theme: theme.build(Brightness.light),
    home: NativeDocumentScope(
      windows: windows,
      documentUrl: 'https://gateway.example/?session=s',
      sourceIdentity: windows.accountIdentity,
      child: Scaffold(
        backgroundColor: Colors.white,
        body: RepaintBoundary(
          key: captureKey,
          child: ColoredBox(
            color: Colors.white,
            child: Column(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    child: Column(
                      children: [
                        // An earlier item in the same scroll view (a card that
                        // paints before the message does).
                        Container(
                          key: earlierCardKey,
                          color: const Color(0xff00aa00),
                          padding: const EdgeInsets.all(12),
                          child: ElevatedButton(
                            key: earlierKey,
                            onPressed: () => earlier++,
                            child: const Text('Earlier'),
                          ),
                        ),
                        const SizedBox(height: 24),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: KeyedSubtree(
                            key: messageKey,
                            child: leak
                                ? Column(
                                    children: [
                                      RichTextBody(html, gateway: gateway),
                                      Transform.translate(
                                        offset: const Offset(-20, -230),
                                        child: GestureDetector(
                                          behavior: HitTestBehavior.opaque,
                                          onTap: () {},
                                          child: const SizedBox(
                                            width: 450,
                                            height: 300,
                                            child: ColoredBox(
                                              color: Colors.red,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  )
                                : RichTextBody(html, gateway: gateway),
                          ),
                        ),
                        const SizedBox(height: 40),
                        Container(
                          key: approveCardKey,
                          color: const Color(0xff00aa00),
                          padding: const EdgeInsets.all(12),
                          child: ElevatedButton(
                            key: approveKey,
                            onPressed: () => approved++,
                            child: const Text('Approve'),
                          ),
                        ),
                        const SizedBox(height: 40),
                      ],
                    ),
                  ),
                ),
                Container(
                  color: const Color(0xff0000aa),
                  padding: const EdgeInsets.all(8),
                  child: Row(
                    children: [
                      Expanded(child: TextField(key: composerKey)),
                      ElevatedButton(
                        key: sendKey,
                        onPressed: () => sent++,
                        child: const Text('Send'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  Rect messageRect(WidgetTester t) => t.getRect(find.byKey(messageKey));
}

Future<ui.Image> _capture(WidgetTester t, _Harness h) async {
  late ui.Image image;
  await t.runAsync(() async {
    final boundary =
        h.captureKey.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
    image = await boundary.toImage();
  });
  return image;
}

Future<ByteData> _pixels(WidgetTester t, ui.Image image) async {
  late ByteData data;
  await t.runAsync(() async {
    data = (await image.toByteData())!;
  });
  return data;
}

int _pixel(ByteData data, ui.Image image, Offset p) {
  final x = p.dx.round().clamp(0, image.width - 1);
  final y = p.dy.round().clamp(0, image.height - 1);
  final o = (y * image.width + x) * 4;
  return (data.getUint8(o) << 16) |
      (data.getUint8(o + 1) << 8) |
      data.getUint8(o + 2);
}

/// What untrusted markup did to the surrounding app.
class _Verdict {
  _Verdict(this.paintedOver, this.approveIntercepted, this.sendIntercepted);
  final List<String> paintedOver;
  final bool approveIntercepted, sendIntercepted;
  bool get escaped =>
      paintedOver.isNotEmpty || approveIntercepted || sendIntercepted;
  @override
  String toString() =>
      'paintedOver=$paintedOver approveIntercepted=$approveIntercepted sendIntercepted=$sendIntercepted';
}

Future<_Verdict> _probe(
  WidgetTester t,
  String html, {
  bool leak = false,
  String label = 'probe',
}) async {
  final probe = _Harness(html, leak: leak);
  final gateway = Gateway();
  final windows = NativeDocumentWindows(
    gateway,
    appDocumentUrl: () => 'https://gateway.example/?session=s',
  );
  addTearDown(windows.dispose);
  t.view.physicalSize = const Size(390 * 3, 844 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);

  await t.pumpWidget(probe.build(windows, gateway));
  await t.pumpAndSettle();
  final image = await _capture(t, probe);
  final data = await _pixels(t, image);
  final dump = const String.fromEnvironment('UI_DUMP');
  if (dump.isNotEmpty) {
    await t.runAsync(() async {
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      File(
        '$dump/${label.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_')}.png',
      ).writeAsBytesSync(png!.buffer.asUint8List());
    });
  }
  final box = probe.messageRect(t);
  final viewport = Offset.zero & const Size(390, 844);
  final message = find.byKey(probe.messageKey).evaluate().single.renderObject!;

  // Everything outside the message box must still show what the app drew
  // there. Colors are the app's own: white page, green approval card, blue
  // composer bar.
  const white = 0xffffff, green = 0x00aa00, blue = 0x0000aa;
  final card = t.getRect(find.byKey(probe.approveCardKey));
  final earlierCard = t.getRect(find.byKey(probe.earlierCardKey));
  final checks = <String, (Offset, int)>{
    'earlier card': (earlierCard.topLeft + const Offset(3, 3), green),
    'earlier card (far corner)': (
      earlierCard.bottomRight - const Offset(3, 3),
      green,
    ),
    'left gutter': (Offset(4, box.center.dy.clamp(140, 700).toDouble()), white),
    'right gutter': (
      Offset(386, box.center.dy.clamp(140, 700).toDouble()),
      white,
    ),
    'composer bar': (
      t.getTopLeft(find.byKey(probe.composerKey)) + const Offset(-4, 4),
      blue,
    ),
    if (viewport.contains(card.topLeft + const Offset(3, 3)))
      'approval card': (card.topLeft + const Offset(3, 3), green),
    if (viewport.contains(card.bottomRight - const Offset(3, 3)))
      'approval card (far corner)': (
        card.bottomRight - const Offset(3, 3),
        green,
      ),
    if (box.bottom + 8 < card.top - 4 &&
        viewport.contains(Offset(8, box.bottom + 8)))
      'gap below message': (Offset(8, box.bottom + 8), white),
  };
  final painted = <String>[];
  for (final entry in checks.entries) {
    if (_pixel(data, image, entry.value.$1) != entry.value.$2) {
      painted.add(entry.key);
    }
  }

  // A tap on app UI must reach app UI: the target must be on the hit path and
  // nothing from the message may be on it at a point outside the message box.
  bool intercepted(Offset at, Finder target) {
    if (!viewport.contains(at) || box.contains(at)) return false;
    final result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(result, at, t.view.viewId);
    final render = target.evaluate().single.renderObject!;
    final path = result.path.map((e) => e.target).whereType<RenderObject>();
    return !path.any((o) => _isInside(o, render)) ||
        path.any((o) => _isInside(o, message));
  }

  final earlierFinder = find.byKey(probe.earlierKey);
  final earlierHit = intercepted(t.getCenter(earlierFinder), earlierFinder);
  final approveFinder = find.byKey(probe.approveKey);
  final sendFinder = find.byKey(probe.sendKey);
  final approveHit = intercepted(t.getCenter(approveFinder), approveFinder);
  final sendHit = intercepted(t.getCenter(sendFinder), sendFinder);
  return _Verdict(painted, approveHit || earlierHit, sendHit);
}

bool _isInside(RenderObject node, RenderObject ancestor) {
  RenderObject? n = node;
  while (n != null) {
    if (identical(n, ancestor)) return true;
    n = n.parent;
  }
  return false;
}

String _chain(int n) =>
    'flowchart LR\n${[for (var i = 0; i < n; i++) '  N$i[Node $i with a rather long label] --> N${i + 1}'].join('\n')}\n';

final _mermaidCases = <String, String>{
  'U4 themeCSS in init':
      "```mermaid\n%%{init: {'themeCSS': 'body{background:#f00} .node rect{fill:#f00} } @import url(https://evil.example/x.css); :root{--x:1} svg{position:fixed;inset:0}', 'theme':'base', 'themeVariables': {'primaryColor':'#f00'}}}%%\nflowchart TD\n  A[Start] --> B[End]\n```",
  'U4 classDef and style values':
      '```mermaid\nflowchart TD\n  A[Start] --> B[End]\n  classDef big fill:#f00,stroke:#f00,stroke-width:50px,color:#fff\n  class A big\n  style B fill:#f00,stroke-width:50px\n```',
  'U4 classDef and style with hostile values':
      '```mermaid\nflowchart TD\n  A[Start] --> B[End]\n  classDef big fill:#f00,stroke-width:5000px,font-size:5000px,width:99999px,height:99999px,position:fixed,inset:0,transform:scale(500)\n  class A big\n  style B fill:#f00,stroke-width:5000px,opacity:0,background:url(https://evil.example/x.png)\n```',
  'U5 very wide and tall diagram': '```mermaid\n${_chain(120)}```',
  'U5 huge label':
      '```mermaid\nflowchart TD\n  A["${'W' * 6000}"] --> B["${'tall\n' * 400}"]\n```',
  'U5 sequence with many participants':
      '```mermaid\nsequenceDiagram\n${[for (var i = 0; i < 60; i++) '  participant P$i'].join('\n')}\n  P0->>P59: hello\n```',
  'U5 gantt over a century':
      '```mermaid\ngantt\n  dateFormat YYYY-MM-DD\n  section S\n  Long :a, 1900-01-01, 36500d\n  Tiny :b, 2000-01-01, 1d\n```',
  'U5 xychart huge range':
      '```mermaid\nxychart-beta\n  x-axis [a, b]\n  y-axis "v" 0 --> 1000000000000\n  bar [1, 999999999999]\n```',
};

final _cases = <String, String>{
  'U2 negative left margin':
      '<div style="margin-left:-1000px;width:3000px;height:30px;background:#f00"></div>',
  'U2 nowrap long text':
      '<p style="white-space:nowrap;background:#f00;color:#f00">${'W' * 4000}</p>',
  'U2 wide table':
      '<table style="width:99999px;background:#f00"><tr><td>a</td><td>b</td></tr></table>',
  'U2 sticky':
      '<div style="position:sticky;top:-9999px;background:#f00;height:40px">s</div>',
  'U2 float over neighbours':
      '<div style="float:left;margin-top:-500px;margin-left:-500px;width:2000px;height:2000px;background:#f00"></div>',
  'U3 inline-block overlay with negative margins':
      '<span style="display:inline-block;margin:-2000px;width:5000px;height:5000px;opacity:0">x</span>',
  'U1 fixed inset:0':
      '<p>msg</p><div style="position:fixed;inset:0;background:#f00;z-index:9999"></div>',
  'U1 fixed 100vw/100vh':
      '<p>msg</p><div style="position:fixed;top:0;left:0;width:100vw;height:100vh;background:#f00"></div>',
  'U1 fixed with text':
      '<div style="position:fixed;inset:0;background:#f00;color:#fff;z-index:2147483647">Session expired. Re-enter your token</div>',
  'U2 absolute negative offsets':
      '<div style="position:relative"><div style="position:absolute;top:-2000px;left:-2000px;width:5000px;height:5000px;background:#f00"></div></div>',
  'U2 absolute below':
      '<div style="position:relative;height:10px"><div style="position:absolute;top:0;left:0;width:100%;height:3000px;background:#f00"></div></div>',
  'U2 negative margin':
      '<div style="margin-top:-3000px;margin-bottom:-3000px;height:6000px;background:#f00"></div>',
  'U2 transform scale':
      '<div style="width:10px;height:10px;background:#f00;transform:scale(500);transform-origin:0 0"></div>',
  'U2 transform translate':
      '<div style="width:300px;height:100px;background:#f00;transform:translate(0,2000px)"></div>',
  'U2 huge size':
      '<div style="width:99999px;height:99999px;background:#f00"></div>',
  'U2 relative offset':
      '<div style="position:relative;top:3000px;left:0;width:100%;height:200px;background:#f00"></div>',
  'U3 transparent absolute overlay':
      '<div style="position:relative"><div style="position:absolute;top:0;left:0;width:100%;height:5000px;opacity:0"><a href="https://evil.example/x" style="display:block;width:100%;height:5000px">x</a></div></div>',
  'U3 transparent fixed overlay link':
      '<a href="https://evil.example/x" style="position:fixed;inset:0;display:block;opacity:0">overlay</a>',
  'U3 transparent fixed overlay button':
      '<button style="position:fixed;inset:0;opacity:0">overlay</button>',
};

/// A fetched document hosted between app chrome: a top bar and a bottom bar
/// that stand for the window controls the document must not cover.
class _DocumentHarness {
  _DocumentHarness(this.html);
  final String html;
  final captureKey = GlobalKey();
  final viewKey = GlobalKey();
  final topKey = const ValueKey('top-button');
  final bottomKey = const ValueKey('bottom-button');

  Widget build(NativeDocumentWindows windows, Gateway gateway) {
    final bytes = Uint8List.fromList(utf8.encode(html));
    final document = NativeFetchedDocument(
      id: 1,
      url: 'https://elsewhere.example/doc.html',
      status: 200,
      bytes: bytes,
      mimeType: 'text/html',
      content: NativeHtmlDocumentContent.fromBytes(
        bytes,
        mimeType: 'text/html',
        charset: 'utf-8',
      ),
      headers: const {},
    );
    return MaterialApp(
      theme: theme.build(Brightness.light),
      home: NativeDocumentScope(
        windows: windows,
        documentUrl: document.url,
        sourceIdentity: windows.accountIdentity,
        child: Scaffold(
          body: RepaintBoundary(
            key: captureKey,
            child: ColoredBox(
              color: Colors.white,
              child: Column(
                children: [
                  Container(
                    color: const Color(0xff00aa00),
                    padding: const EdgeInsets.all(8),
                    child: Row(
                      children: [
                        ElevatedButton(
                          key: topKey,
                          onPressed: () {},
                          child: const Text('Back'),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: KeyedSubtree(
                      key: viewKey,
                      child: NativeFetchedDocumentView(
                        document: document,
                        gateway: gateway,
                        onLink: (_) {},
                        onSubmit: (_) {},
                      ),
                    ),
                  ),
                  Container(
                    color: const Color(0xff0000aa),
                    padding: const EdgeInsets.all(8),
                    child: Row(
                      children: [
                        ElevatedButton(
                          key: bottomKey,
                          onPressed: () {},
                          child: const Text('Close'),
                        ),
                      ],
                    ),
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

Future<_Verdict> _probeDocument(
  WidgetTester t,
  String html, {
  String label = 'doc',
}) async {
  final probe = _DocumentHarness(html);
  final gateway = Gateway();
  final windows = NativeDocumentWindows(
    gateway,
    appDocumentUrl: () => 'https://gateway.example/?session=s',
  );
  addTearDown(windows.dispose);
  t.view.physicalSize = const Size(390 * 3, 844 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(probe.build(windows, gateway));
  await t.pumpAndSettle();
  late ui.Image image;
  late ByteData data;
  await t.runAsync(() async {
    final boundary =
        probe.captureKey.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
    image = await boundary.toImage();
    data = (await image.toByteData())!;
  });
  final dump = const String.fromEnvironment('UI_DUMP');
  if (dump.isNotEmpty) {
    await t.runAsync(() async {
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      File(
        '$dump/doc_${label.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_')}.png',
      ).writeAsBytesSync(png!.buffer.asUint8List());
    });
  }
  final top = t.getRect(find.byKey(probe.topKey));
  final bottom = t.getRect(find.byKey(probe.bottomKey));
  final view = t.getRect(find.byKey(probe.viewKey));
  const green = 0x00aa00, blue = 0x0000aa;
  final painted = <String>[
    if (_pixel(data, image, Offset(2, top.top - 6)) != green) 'top bar',
    if (_pixel(data, image, Offset(386, top.top - 6)) != green)
      'top bar (right)',
    if (_pixel(data, image, Offset(2, bottom.bottom + 6)) != blue) 'bottom bar',
    if (_pixel(data, image, Offset(386, bottom.bottom + 6)) != blue)
      'bottom bar (right)',
  ];
  final viewRender = find.byKey(probe.viewKey).evaluate().single.renderObject!;
  bool intercepted(Offset at, Finder target) {
    final result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(result, at, t.view.viewId);
    final render = target.evaluate().single.renderObject!;
    final path = result.path.map((e) => e.target).whereType<RenderObject>();
    return !path.any((o) => _isInside(o, render)) ||
        path.any((o) => _isInside(o, viewRender));
  }

  final topHit = intercepted(top.center, find.byKey(probe.topKey));
  final bottomHit = intercepted(bottom.center, find.byKey(probe.bottomKey));
  expect(view.top, greaterThanOrEqualTo(top.bottom));
  return _Verdict(painted, topHit, bottomHit);
}

const _documentCases = <String, String>{
  'fixed inset:0':
      '<p>doc</p><div style="position:fixed;inset:0;background:#f00;z-index:9999"></div>',
  'fixed 100vw/100vh':
      '<div style="position:fixed;top:0;left:0;width:100vw;height:100vh;background:#f00"></div>',
  'absolute negative offsets':
      '<div style="position:relative"><div style="position:absolute;top:-2000px;left:-2000px;width:5000px;height:5000px;background:#f00"></div></div>',
  'transform translate':
      '<div style="width:300px;height:100px;background:#f00;transform:translate(0,-2000px)"></div>',
  'transform scale':
      '<div style="width:10px;height:10px;background:#f00;transform:scale(500);transform-origin:0 0"></div>',
  'negative margin':
      '<div style="margin-top:-3000px;height:6000px;background:#f00"></div>',
  'transparent fixed overlay':
      '<a href="https://evil.example/x" style="position:fixed;inset:0;display:block;opacity:0">overlay</a>',
  'fixed modal-like':
      '<div style="position:fixed;top:-500px;left:-500px;right:-500px;bottom:-500px;background:rgba(255,0,0,.9)"></div>',
};

void main() {
  testWidgets('control: the probe notices a message that does escape its box', (
    t,
  ) async {
    final verdict = await _probe(t, '<p>msg</p>', leak: true);
    expect(verdict.escaped, isTrue, reason: '$verdict');
    expect(verdict.paintedOver, isNotEmpty);
  });

  for (final entry in _mermaidCases.entries) {
    testWidgets('Mermaid ${entry.key}: stays inside the message box', (
      t,
    ) async {
      final verdict = await _probe(t, entry.value, label: entry.key);
      expect(verdict.escaped, isFalse, reason: '${entry.key}: $verdict');
    });
  }

  for (final entry in _cases.entries) {
    testWidgets('${entry.key}: stays inside the message box', (t) async {
      final verdict = await _probe(t, entry.value, label: entry.key);
      expect(verdict.escaped, isFalse, reason: '${entry.key}: $verdict');
    });
  }

  for (final entry in _documentCases.entries) {
    testWidgets('document view, ${entry.key}: stays inside its window', (
      t,
    ) async {
      final verdict = await _probeDocument(t, entry.value, label: entry.key);
      expect(verdict.escaped, isFalse, reason: '${entry.key}: $verdict');
    });
  }
}
