import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/mermaid/pie.dart';

void main() {
  test('preserves inline comment markers and removes full-line comments', () {
    final diagram = parseNativeMermaidPie('''
pie
accDescr {
  First line %% remains text
  %% this is also description text

    Second line
}
"Slice": 1
''');

    expect(diagram.description, 'First line %% remains text\nSecond line');
    expect(diagram.sections, {'Slice': 1.0});
  });

  test('matches pinned Mermaid rendered CRLF description', () {
    final diagram = parseNativeMermaidPie(
      'pie\r\naccDescr {\r\nFirst\r\n  Second\r\n}\r\n"Slice": 1',
    );

    expect(diagram.description, 'First\nSecond');
    expect(diagram.sections, {'Slice': 1.0});
  });

  test('accepts an empty or inline multiline block before slices', () {
    final empty = parseNativeMermaidPie('pie\naccDescr {\n}\n"Empty": 0');
    expect(empty.description, isEmpty);
    expect(empty.sections, {'Empty': 0.0});

    final inline = parseNativeMermaidPie(
      'pie\naccDescr { One line }\n"Slice": 2',
    );
    expect(inline.description, 'One line');
    expect(inline.sections, {'Slice': 2.0});
  });

  test(
    'rejects an unclosed multiline description instead of parsing past it',
    () {
      expect(
        () => parseNativeMermaidPie('pie\naccDescr {\nNot closed\n"Slice": 1'),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('Unclosed native pie accDescr block'),
          ),
        ),
      );
    },
  );
}
