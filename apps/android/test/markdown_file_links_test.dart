import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:pirc_render/src/markdown_file_links.dart';
import 'package:pirc_render/src/markdown_syntax.dart';
import 'package:pirc_render/src/file_links.dart';
import 'package:pirc_mobile/live/common.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'live_test.dart' show theme, FakeGateway;

final linkFixture = obj(
  jsonDecode(
    File('../../fixtures/mobile-parity/markdown-links.json').readAsStringSync(),
  ),
);
List<md.Element> links(List<md.Node> nodes) => [
  for (final node in nodes)
    if (node is md.Element) ...[
      if (node.tag == 'a') node,
      ...links(node.children ?? []),
    ],
];
bool hasCode(md.Node node) =>
    node is md.Element &&
    (node.tag == 'code' || (node.children ?? []).any(hasCode));
void main() {
  final expected = rows(
    jsonDecode(
      File(
        '../../fixtures/mobile-parity/markdown-links-expected.json',
      ).readAsStringSync(),
    ),
  );
  for (final c in rows(linkFixture['cases'])) {
    test('pinned web file links: ${c['id']}', () {
      final tree = md.Document(
        extensionSet: md.ExtensionSet.gitHubFlavored,
        encodeHtml: false,
        blockSyntaxes: const [NativeMathBlockSyntax(), NativeFenceSyntax()],
        inlineSyntaxes: [NativeMathInlineSyntax(), ...nativeFileLinkSyntaxes()],
      ).parseLines((c['source'] as String).split('\n'));
      final actual = links(tree).map((link) {
        final target = parseFileTarget(
          link.attributes['href'],
          base: c['base'],
        );
        return {
          'text': link.textContent,
          'href': link.attributes['href'],
          'code': hasCode(link),
          'target': target == null
              ? null
              : {
                  'path': target.path,
                  if (target.line != null) 'line': target.line,
                  if (target.endLine != null) 'endLine': target.endLine,
                },
        };
      }).toList();
      expect(actual, expected.singleWhere((e) => e['id'] == c['id'])['links']);
    });
  }
  testWidgets('native code and table file links open the relative file target', (
    t,
  ) async {
    final g = FakeGateway();
    String? target;
    await t.pumpWidget(
      MaterialApp(
        theme: theme.build(Brightness.light),
        home: Scaffold(
          body: RichTextBody(
            '`src/main.dart:12-20`\n\n| File |\n|---|\n| src/table.dart:4 |\n\n[`src/external.dart`](https://example.com)',
            gateway: g,
            linkBase: 'docs',
            onFile: (v) => target = v,
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.text('src/main.dart:12-20'));
    expect(target, 'docs/src/main.dart#L12-L20');
    await t.tap(find.text('src/table.dart:4'));
    expect(target, 'docs/src/table.dart#L4');
    await t.tap(find.text('src/external.dart'));
    await t.pump();
    expect(g.calls.last.$1, 'external');
    expect(g.calls.last.$2, {'url': 'https://example.com'});
    await t.pumpWidget(const SizedBox());
    await g.stream.close();
  });
  for (final width in [390.0, 768.0]) {
    testWidgets('long native code link wraps at 2x text on $width', (t) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = Size(width, 1200);
      addTearDown(t.view.reset);
      final path =
          'src/${List.filled(8, 'long_directory').join('/')}/file.dart:2';
      final g = FakeGateway();
      String? target;
      await t.pumpWidget(
        MaterialApp(
          theme: theme.build(Brightness.light),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              child: RichTextBody(
                '`$path`',
                gateway: g,
                onFile: (v) => target = v,
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(t.getSize(find.text(path)).width, lessThanOrEqualTo(width));
      expect(t.takeException(), isNull);
      await t.tap(find.text(path));
      expect(target, '${path.substring(0, path.length - 2)}#L2');
      await t.pumpWidget(const SizedBox());
      await g.stream.close();
    });
  }
}
