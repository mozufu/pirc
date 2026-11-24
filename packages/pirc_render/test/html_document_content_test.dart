import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/html_document_content.dart';

Uint8List _bytes(List<int> bytes) => Uint8List.fromList(bytes);

List<int> _utf16Bytes(String value, {required bool littleEndian}) {
  final bytes = <int>[];
  for (final unit in value.codeUnits) {
    if (littleEndian) {
      bytes
        ..add(unit & 0xFF)
        ..add(unit >> 8);
    } else {
      bytes
        ..add(unit >> 8)
        ..add(unit & 0xFF);
    }
  }
  return bytes;
}

void main() {
  test('decodes UTF-8 and extracts HTML metadata without executing scripts', () {
    const source =
        '<!doctype html><html><head>'
        '<meta charset="utf-8">'
        '<title>Résumé</title>'
        '<base href="/docs/" target="_blank">'
        '<base href="/ignored/">'
        '<link rel="alternate stylesheet" href="main.css">'
        '<link rel="icon stylesheet" href="print.css">'
        '<style>body { color: red; }</style>'
        '<script type="application/json">{}</script>'
        '</head><body class="reader" data-page="one"><p>café</p></body></html>';
    final content = NativeHtmlDocumentContent.fromBytes(
      _bytes(utf8.encode(source)),
      mimeType: 'text/html',
    );

    expect(content.encoding, 'utf-8');
    expect(content.text, source);
    expect(content.isHtml, isTrue);
    expect(content.title, 'Résumé');
    expect(content.bodyInnerHtml, '<p>café</p>');
    expect(content.bodyAttributes, {'class': 'reader', 'data-page': 'one'});
    expect(content.baseHref, '/docs/');
    expect(content.baseTarget, '_blank');
    expect(content.stylesheetRefs, ['main.css', 'print.css']);
    expect(content.inlineStyles, ['body { color: red; }']);
    expect(content.hasScripts, isTrue);
  });

  test('BOM overrides conflicting header and meta declarations', () {
    const source = '<meta charset="windows-1252"><p>café</p>';
    final content = NativeHtmlDocumentContent.fromBytes(
      _bytes([0xEF, 0xBB, 0xBF, ...utf8.encode(source)]),
      mimeType: 'text/html',
      charset: 'windows-1252',
    );

    expect(content.encoding, 'utf-8');
    expect(content.bodyInnerHtml, '<p>café</p>');
  });

  test(
    'supported header charset overrides meta and Latin1 aliases use Windows-1252',
    () {
      final prefix = utf8.encode('<meta charset="utf-8"><p>');
      final bytes = _bytes([
        ...prefix,
        0x80,
        0x82,
        0x92,
        ...utf8.encode('</p>'),
      ]);
      final content = NativeHtmlDocumentContent.fromBytes(
        bytes,
        mimeType: 'text/html',
        charset: '  LaTiN1  ',
      );

      expect(content.encoding, 'windows-1252');
      expect(content.bodyInnerHtml, '<p>€‚’</p>');
    },
  );

  test(
    'unknown header labels fall through to a meta declaration in first 1024 bytes',
    () {
      final prefix = utf8.encode('<meta charset="ascii"><p>');
      final content = NativeHtmlDocumentContent.fromBytes(
        _bytes([...prefix, 0x80, ...utf8.encode('</p>')]),
        mimeType: 'text/html',
        charset: 'x-not-a-real-encoding',
      );

      expect(content.encoding, 'windows-1252');
      expect(content.bodyInnerHtml, '<p>€</p>');
    },
  );

  test('meta declarations past the first 1024 bytes are not used', () {
    final padding = List<int>.filled(1024, 0x20);
    final lateMeta = utf8.encode('<meta charset="utf-8"><p>');
    final content = NativeHtmlDocumentContent.fromBytes(
      _bytes([...padding, ...lateMeta, 0x80, ...utf8.encode('</p>')]),
      mimeType: 'text/html',
    );

    expect(content.encoding, 'windows-1252');
    expect(content.bodyInnerHtml, contains('<p>€</p>'));
  });

  test(
    'Windows-1252 remaps bytes 128 through 159 and preserves undefined controls',
    () {
      final content = NativeHtmlDocumentContent.fromBytes(
        _bytes([0x80, 0x81, 0x82, 0x91, 0x92, 0x9D, 0x9F]),
        mimeType: 'text/plain',
        charset: 'windows-1252',
      );

      expect(content.text, '€\u0081‚‘’\u009DŸ');
      expect(content.encoding, 'windows-1252');
      expect(content.isHtml, isFalse);
      expect(content.title, isNull);
    },
  );

  test('UTF-16LE and UTF-16BE BOMs select byte order and remove the BOM', () {
    const source = '<p>漢字</p>';
    final le = NativeHtmlDocumentContent.fromBytes(
      _bytes([0xFF, 0xFE, ..._utf16Bytes(source, littleEndian: true)]),
      mimeType: 'text/html',
    );
    final be = NativeHtmlDocumentContent.fromBytes(
      _bytes([0xFE, 0xFF, ..._utf16Bytes(source, littleEndian: false)]),
      mimeType: 'text/html',
    );

    expect(le.encoding, 'utf-16le');
    expect(le.bodyInnerHtml, '<p>漢字</p>');
    expect(be.encoding, 'utf-16be');
    expect(be.bodyInnerHtml, '<p>漢字</p>');
  });

  test(
    'UTF-16 header labels decode no-BOM bodies and replace malformed input',
    () {
      const source = '<p>頁</p>';
      final content = NativeHtmlDocumentContent.fromBytes(
        _bytes(_utf16Bytes(source, littleEndian: true)),
        mimeType: 'text/html',
        charset: 'utf-16le',
      );
      final malformed = NativeHtmlDocumentContent.fromBytes(
        _bytes([0x00, 0xD8]),
        mimeType: 'text/plain',
        charset: 'utf-16le',
      );

      expect(content.encoding, 'utf-16le');
      expect(content.bodyInnerHtml, '<p>頁</p>');
      expect(malformed.text, '�');
    },
  );

  test('malformed UTF-8 replaces invalid bytes', () {
    final content = NativeHtmlDocumentContent.fromBytes(
      _bytes([0xC3, 0x28]),
      mimeType: 'text/plain',
      charset: 'utf-8',
    );

    expect(content.text, '�(');
  });

  test('recognized but unimplemented encodings fail explicitly', () {
    expect(
      () => NativeHtmlDocumentContent.fromBytes(
        _bytes(utf8.encode('<p>text</p>')),
        mimeType: 'text/html',
        charset: 'Shift_JIS',
      ),
      throwsA(isA<UnsupportedError>()),
    );
    expect(
      () => NativeHtmlDocumentContent.fromBytes(
        _bytes(utf8.encode('<meta charset="Shift_JIS">')),
        mimeType: 'text/html',
      ),
      throwsA(isA<UnsupportedError>()),
    );
  });

  test(
    'non-HTML text defaults to UTF-8 and does not scan XML declarations',
    () {
      const source =
          '<?xml version="1.0" encoding="windows-1252"?><root>café</root>';
      final content = NativeHtmlDocumentContent.fromBytes(
        _bytes(utf8.encode(source)),
        mimeType: 'application/xml',
      );

      expect(content.encoding, 'utf-8');
      expect(content.text, source);
      expect(content.isHtml, isFalse);
      expect(content.title, isNull);
      expect(content.bodyInnerHtml, isEmpty);
      expect(content.stylesheetRefs, isEmpty);
      expect(content.hasScripts, isFalse);
    },
  );
}
