import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:markdown/markdown.dart' as md;
import 'package:pirc_render/src/markdown_syntax.dart';

void main() {
  final fixture = jsonDecode(
    File(
      '../../fixtures/mobile-parity/markdown-list-heading.json',
    ).readAsStringSync(),
  );
  for (final row in fixture['cases']) {
    test('list block structure matches pinned Marked: ${row['id']}', () {
      final nodes = md.Document(
        extensionSet: md.ExtensionSet.gitHubFlavored,
        blockSyntaxes: const [NativeHeadingSyntax()],
      ).parseLines((row['source'] as String).split('\n'));
      final expected = html.parseFragment(row['html']);
      final actual = html.parseFragment(md.renderToHtml(nodes));
      List<List<String>> structure(dynamic document) => [
        for (final item in document.querySelectorAll('li'))
          [for (final child in item.children) child.localName as String],
      ];
      expect(structure(actual), structure(expected));
      expect(
        actual.text?.replaceAll(RegExp(r'\s+'), ' ').trim(),
        expected.text?.replaceAll(RegExp(r'\s+'), ' ').trim(),
      );
      expect(
        actual.querySelector('ol')?.attributes['start'],
        expected.querySelector('ol')?.attributes['start'],
      );
    });
  }
}
