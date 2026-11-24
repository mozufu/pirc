import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:pirc_render/src/html_document_styles.dart';

Map<String, String> style(
  String css, {
  bool dark = false,
  bool defaults = true,
  String inline = '',
}) {
  final doc = html.parse(
    '<html><body><dialog open style="$inline"></dialog></body></html>',
  );
  final result = NativeDocumentStyleEngine(
    stylesheets: [
      NativeDocumentStylesheet(css, baseUrl: 'https://dialog.example/'),
    ],
    viewportWidth: 390,
    dark: dark,
    dialogDefaults: defaults,
  ).apply(doc);
  expect(result.diagnostics, isEmpty);
  return result.stylesByElement[doc.querySelector('dialog')] ?? {};
}

void main() {
  test(
    'author-only cascade stays opt-in and author universal rules outrank UA',
    () {
      expect(style('', defaults: false), isEmpty);
      final actual = style(
        '*{position:static;width:200px;padding:0;border:0;background:transparent;color:red}',
      );
      expect(actual['position'], 'static');
      expect(actual['width'], '200px');
      expect(actual['padding-top'], '0');
      expect(actual['border-top-width'], '0');
      expect(actual['border-top-style'], 'none');
      expect(actual['color'], '#f00');
    },
  );
  test('author inline and important declarations keep their original rank', () {
    final actual = style(
      'dialog{width:180px!important;padding:3px!important}',
      inline: 'width:220px;padding:4px;border:2px dashed blue',
    );
    expect(actual['width'], '180px');
    expect(actual['padding-top'], '3px');
    expect(actual['border-top-width'], '2px');
    expect(actual['border-top-style'], 'dashed');
    expect(actual['border-top-color'], '#00f');
  });
  for (final row in [
    ('normal', true, '', '#ffffff', '#000000'),
    ('light-dark', true, 'html{color-scheme:light dark}', '#121212', '#ffffff'),
    ('forced-dark', false, 'body{color-scheme:dark}', '#121212', '#ffffff'),
    (
      'dialog-light',
      true,
      'html{color-scheme:dark}dialog{color-scheme:light}',
      '#ffffff',
      '#000000',
    ),
    (
      'variable-dark',
      false,
      ':root{--scheme:dark}dialog{color-scheme:var(--scheme)}',
      '#121212',
      '#ffffff',
    ),
  ]) {
    test('dialog system colors follow used color scheme ${row.$1}', () {
      final actual = style(row.$3, dark: row.$2);
      expect(actual['background-color'], row.$4);
      expect(actual['color'], row.$5);
      expect(actual['border-top-color'], 'currentColor');
    });
  }
}
