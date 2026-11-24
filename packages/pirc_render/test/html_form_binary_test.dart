import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/html_file.dart';
import 'package:pirc_render/src/html_form_binary.dart';

void main() {
  group('nativeHtmlFormDataUrlEncode', () {
    test('serializes empty and selected files in successful-control order', () {
      final file = NativeHtmlFile(
        name: 'one résumé-台北.txt',
        mimeType: 'text/plain',
        bytes: [76, 105, 110, 101, 32, 49, 10],
      );
      final empty = [
        const NativeHtmlFormDataEntry.file('upload'),
        const NativeHtmlFormDataEntry.text('q', 'A + B & C ~ ! 台北'),
        const NativeHtmlFormDataEntry.text('notes', 'line one\nline two'),
      ];
      final selected = [
        NativeHtmlFormDataEntry.file('upload', file: file),
        NativeHtmlFormDataEntry.file(
          'upload',
          file: NativeHtmlFile(
            name: 'two + space.bin',
            mimeType: 'application/octet-stream',
            bytes: [0, 65, 255],
          ),
        ),
        const NativeHtmlFormDataEntry.text('q', 'A + B & C ~ ! 台北'),
        const NativeHtmlFormDataEntry.text('notes', 'line one\nline two'),
      ];

      expect(
        nativeHtmlFormDataUrlEncode(empty),
        'upload=&q=A+%2B+B+%26+C+%7E+%21+%E5%8F%B0%E5%8C%97&notes=line+one%0D%0Aline+two',
      );
      expect(
        nativeHtmlFormDataUrlEncode(selected),
        'upload=one+r%C3%A9sum%C3%A9-%E5%8F%B0%E5%8C%97.txt&upload=two+%2B+space.bin&q=A+%2B+B+%26+C+%7E+%21+%E5%8F%B0%E5%8C%97&notes=line+one%0D%0Aline+two',
      );
    });

    test('urlencoded POST returns immutable UTF-8 body bytes', () {
      final body = nativeHtmlFormDataEncode([
        NativeHtmlFormDataEntry.file(
          'upload',
          file: NativeHtmlFile(
            name: 'one résumé-台北.txt',
            mimeType: 'text/plain',
            bytes: [1],
          ),
        ),
        const NativeHtmlFormDataEntry.text('notes', 'one\ntwo'),
      ], enctype: 'application/x-www-form-urlencoded');

      expect(body.contentType, 'application/x-www-form-urlencoded');
      expect(
        utf8.decode(body.bytes),
        'upload=one+r%C3%A9sum%C3%A9-%E5%8F%B0%E5%8C%97.txt&notes=one%0D%0Atwo',
      );
      expect(body.byteLength, body.bytes.length);
      final mutated = body.bytes;
      mutated[0] = 0;
      expect(body.bytes.first, 'u'.codeUnitAt(0));
    });

    test('text/plain uses CRLF records and keeps filenames and raw text', () {
      final body = nativeHtmlFormDataEncode([
        const NativeHtmlFormDataEntry.file('upload'),
        const NativeHtmlFormDataEntry.file('upload', file: null),
        const NativeHtmlFormDataEntry.text('q', 'A + B & C ~ ! 台北'),
        const NativeHtmlFormDataEntry.text('notes', 'line one\nline two'),
      ], enctype: 'text/plain');

      expect(body.contentType, 'text/plain');
      expect(
        utf8.decode(body.bytes),
        'upload=\r\n'
        'upload=\r\n'
        'q=A + B & C ~ ! 台北\r\n'
        'notes=line one\r\nline two\r\n',
      );
    });

    test('text/plain emits one CRLF line for each selected filename', () {
      final body = nativeHtmlFormDataEncode([
        NativeHtmlFormDataEntry.file(
          'upload',
          file: NativeHtmlFile(
            name: 'one résumé-台北.txt',
            mimeType: 'text/plain',
            bytes: [1],
          ),
        ),
        NativeHtmlFormDataEntry.file(
          'upload',
          file: NativeHtmlFile(
            name: 'two + space.bin',
            mimeType: 'application/octet-stream',
            bytes: [2],
          ),
        ),
        const NativeHtmlFormDataEntry.text('notes', 'line one\nline two'),
      ], enctype: 'text/plain');

      expect(
        utf8.decode(body.bytes),
        'upload=one résumé-台北.txt\r\n'
        'upload=two + space.bin\r\n'
        'notes=line one\r\nline two\r\n',
      );
    });
  });

  group('multipart/form-data', () {
    test('keeps file payloads binary and emits browser-compatible framing', () {
      const boundary = '----WebKitFormBoundary0123456789abcdef';
      final body = nativeHtmlFormDataEncode(
        [
          const NativeHtmlFormDataEntry.file('upload'),
          NativeHtmlFormDataEntry.file(
            'upload',
            file: NativeHtmlFile(
              name: 'two + space.bin',
              mimeType: 'application/octet-stream',
              bytes: [0x00, 0x41, 0xff, 0x0d, 0x0a, 0x42, 0x80],
            ),
          ),
          const NativeHtmlFormDataEntry.text('notes', 'line one\nline two'),
        ],
        enctype: 'multipart/form-data',
        boundary: boundary,
      );

      expect(body.contentType, 'multipart/form-data; boundary=$boundary');
      expect(body.boundary, boundary);
      final expected = BytesBuilder()
        ..add(ascii.encode('--$boundary\r\n'))
        ..add(
          ascii.encode(
            'Content-Disposition: form-data; name="upload"; filename=""\r\n',
          ),
        )
        ..add(
          ascii.encode('Content-Type: application/octet-stream\r\n\r\n\r\n'),
        )
        ..add(ascii.encode('--$boundary\r\n'))
        ..add(
          ascii.encode(
            'Content-Disposition: form-data; name="upload"; filename="two + space.bin"\r\n',
          ),
        )
        ..add(ascii.encode('Content-Type: application/octet-stream\r\n\r\n'))
        ..add([0x00, 0x41, 0xff, 0x0d, 0x0a, 0x42, 0x80])
        ..add(ascii.encode('\r\n--$boundary\r\n'))
        ..add(
          ascii.encode('Content-Disposition: form-data; name="notes"\r\n\r\n'),
        )
        ..add(utf8.encode('line one\r\nline two\r\n'))
        ..add(ascii.encode('--$boundary--\r\n'));
      expect(body.bytes, expected.takeBytes());
    });

    test('matches the captured two-file order and binary payload bytes', () {
      const boundary = '----WebKitFormBoundary0123456789abcdef';
      final body = nativeHtmlFormDataEncode(
        [
          NativeHtmlFormDataEntry.file(
            'upload',
            file: NativeHtmlFile(
              name: 'one résumé-台北.txt',
              mimeType: 'text/plain',
              bytes: [
                76,
                105,
                110,
                101,
                32,
                49,
                10,
                84,
                97,
                105,
                112,
                101,
                105,
                32,
                240,
                159,
                140,
                128,
              ],
            ),
          ),
          NativeHtmlFormDataEntry.file(
            'upload',
            file: NativeHtmlFile(
              name: 'two + space.bin',
              mimeType: 'application/octet-stream',
              bytes: [0, 65, 255, 13, 10, 66, 128],
            ),
          ),
          const NativeHtmlFormDataEntry.text('q', 'A + B & C ~ ! 台北'),
          const NativeHtmlFormDataEntry.text('notes', 'line one\nline two'),
        ],
        enctype: 'multipart/form-data',
        boundary: boundary,
      );

      final expected = BytesBuilder()
        ..add(ascii.encode('--$boundary\r\n'))
        ..add(
          utf8.encode(
            'Content-Disposition: form-data; name="upload"; filename="one résumé-台北.txt"\r\n',
          ),
        )
        ..add(ascii.encode('Content-Type: text/plain\r\n\r\n'))
        ..add([
          76,
          105,
          110,
          101,
          32,
          49,
          10,
          84,
          97,
          105,
          112,
          101,
          105,
          32,
          240,
          159,
          140,
          128,
        ])
        ..add(ascii.encode('\r\n--$boundary\r\n'))
        ..add(
          ascii.encode(
            'Content-Disposition: form-data; name="upload"; filename="two + space.bin"\r\n',
          ),
        )
        ..add(ascii.encode('Content-Type: application/octet-stream\r\n\r\n'))
        ..add([0, 65, 255, 13, 10, 66, 128])
        ..add(ascii.encode('\r\n--$boundary\r\n'))
        ..add(ascii.encode('Content-Disposition: form-data; name="q"\r\n\r\n'))
        ..add(utf8.encode('A + B & C ~ ! 台北\r\n'))
        ..add(ascii.encode('--$boundary\r\n'))
        ..add(
          ascii.encode('Content-Disposition: form-data; name="notes"\r\n\r\n'),
        )
        ..add(utf8.encode('line one\r\nline two\r\n'))
        ..add(ascii.encode('--$boundary--\r\n'));
      expect(body.bytes, expected.takeBytes());
    });

    test('writes UTF-8 filename bytes and escapes header injection', () {
      const boundary = '----WebKitFormBoundary0123456789abcdef';
      final body = nativeHtmlFormDataEncode(
        [
          NativeHtmlFormDataEntry.file(
            'upload"\r\nX: bad',
            file: NativeHtmlFile(
              name: 'one résumé-台北.txt',
              mimeType: 'text/plain',
              bytes: [0x4c, 0xff],
            ),
          ),
        ],
        enctype: 'multipart/form-data',
        boundary: boundary,
      );

      final bytes = body.bytes;
      final header = utf8.decode(
        bytes.takeWhile((byte) => byte != 0x4c).toList(),
      );
      expect(header, contains('name="upload%22%0D%0AX: bad"'));
      expect(header, contains('filename="one résumé-台北.txt"'));
      expect(header, contains('Content-Type: text/plain\r\n\r\n'));
      expect(bytes, contains(0xff));
    });

    test('generates a boundary and rejects invalid caller boundaries', () {
      final generated = nativeHtmlFormDataEncode(const [
        NativeHtmlFormDataEntry.text('x', 'y'),
      ], enctype: 'multipart/form-data');
      expect(generated.boundary, startsWith('----WebKitFormBoundary'));
      expect(generated.contentType, contains(generated.boundary!));

      expect(
        () => nativeHtmlFormDataEncode(
          const [NativeHtmlFormDataEntry.text('x', 'y')],
          enctype: 'multipart/form-data',
          boundary: 'bad boundary',
        ),
        throwsArgumentError,
      );
    });
  });

  test('unsupported encodings are explicit', () {
    expect(
      () => nativeHtmlFormDataEncode(const [
        NativeHtmlFormDataEntry.text('x', 'y'),
      ], enctype: 'application/json'),
      throwsUnsupportedError,
    );
  });
}
