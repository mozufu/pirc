import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/mermaid/timeline_model.dart';
import 'package:pirc_render/src/mermaid/timeline_parser.dart';

void main() {
  group('parseNativeMermaidTimeline', () {
    test('parses case-insensitive headers and LR/TD direction tokens', () {
      final defaultDirection = parseNativeMermaidTimeline(
        '%% leading comment\nTiMeLiNe\nA',
      );
      final leftToRight = parseNativeMermaidTimeline('TIMELINE LR\nA');
      final topDown = parseNativeMermaidTimeline('timeline td\nA');

      expect(defaultDirection.direction, 'LR');
      expect(defaultDirection.tasks.single.period, 'A');
      expect(leftToRight.direction, 'LR');
      expect(topDown.direction, 'TD');
    });

    test(
      'retains sections in order, including duplicates and empty sections',
      () {
        final diagram = parseNativeMermaidTimeline(
          'timeline\n'
          'section Empty\n'
          'section Used\n'
          'first period\n'
          'section Used\n'
          'second period',
        );

        expect(diagram.sections.map((section) => section.name), [
          'Empty',
          'Used',
          'Used',
        ]);
        expect(diagram.sections.map((section) => section.index), [0, 1, 2]);
        expect(diagram.sections.first.sourceLine, 2);
        expect(diagram.tasks.map((task) => task.id), [0, 1]);
        expect(diagram.tasks.map((task) => task.sectionName), ['Used', 'Used']);
        expect(diagram.tasks.map((task) => task.period), [
          'first period',
          'second period',
        ]);
      },
    );

    test(
      'preserves raw period whitespace and attaches colon events in order',
      () {
        final diagram = parseNativeMermaidTimeline(
          'timeline\n'
          'section S\n'
          '2001 : first: second\n'
          ': third\n'
          '2002\\: escaped\n'
          '2003 :\n'
          '  continued\n'
          'HTML <b>bold</b><br>label',
        );
        final first = diagram.tasks.first;
        final second = diagram.tasks[1];

        expect(first.id, 0);
        expect(first.period, '2001 ');
        expect(first.task, '2001 ');
        expect(first.section, 'S');
        expect(first.type, 'S');
        expect(first.score, 0);
        expect(first.events.map((event) => event.text), [
          'first',
          'second',
          'third',
        ]);
        expect(first.events.map((event) => event.sourceLine), [3, 3, 4]);
        expect(first.sourceLine, 3);
        // The source lexer does not treat backslash as a colon escape: the
        // period token ends at `:` and the following `: ` is an event token.
        expect(second.id, 1);
        expect(second.period, r'2002\');
        expect(second.events.single.text, 'escaped');
        final continuation = diagram.tasks[2];
        expect(continuation.period, '2003 ');
        expect(continuation.events.single.text, '  continued');
        expect(continuation.events.single.sourceLine, 6);
        expect(diagram.tasks[3].period, 'HTML <b>bold</b><br>label');
      },
    );

    test('reads title and single-line accessibility metadata', () {
      final diagram = parseNativeMermaidTimeline(
        'timeline\n'
        'title Release history\n'
        'accTitle: Releases\n'
        'accDescr: Milestones in order\n'
        '2025',
      );

      expect(diagram.title, 'Release history');
      expect(diagram.accessibleTitle, 'Releases');
      expect(diagram.accessibleDescription, 'Milestones in order');
      expect(diagram.tasks.single.period, '2025');
    });

    test(
      'reads multiline accessibility description and removes line indent',
      () {
        final diagram = parseNativeMermaidTimeline(
          'timeline\n'
          'accDescr {\n'
          'Long line one\n'
          '  Long line two\n'
          '}\n'
          'period',
        );

        expect(diagram.accessibleDescription, 'Long line one\nLong line two');
        expect(diagram.tasks.single.period, 'period');
      },
    );

    test(
      'skips source comments while preserving hash-delimited task prefix',
      () {
        final diagram = parseNativeMermaidTimeline(
          '%% leading comment\n'
          'timeline\n'
          '# full-line comment\n'
          '% percent comment\n'
          'A # trailing comment\n'
          'B',
        );

        expect(diagram.tasks.map((task) => task.period), ['A ', 'B']);
        expect(diagram.tasks.map((task) => task.sourceLine), [5, 6]);
      },
    );

    test('rejects unsupported config, malformed tokens, and orphan events', () {
      expect(
        () => parseNativeMermaidTimeline(
          '%%{init: {"timeline":{"vertical":true}}}%%\ntimeline\nA',
        ),
        throwsFormatException,
      );
      expect(
        () => parseNativeMermaidTimeline(
          '---\ntitle: unsupported\n---\ntimeline',
        ),
        throwsFormatException,
      );
      expect(
        () => parseNativeMermaidTimeline('timeline\n: no previous period'),
        throwsFormatException,
      );
      expect(
        () => parseNativeMermaidTimeline('timeline\nsection A:B'),
        throwsFormatException,
      );
      expect(
        () => parseNativeMermaidTimeline('timeline\naccDescr {\nnot closed'),
        throwsFormatException,
      );
    });

    test('invalid token preserves the source Jison error headline', () {
      expect(
        () => parseNativeMermaidTimeline(
          'timeline\nsection Broken\n2024\n:: malformed event',
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message.split('\n').first,
            'Web error headline',
            'Parse error on line 4:',
          ),
        ),
      );
    });

    test('enforces the processed Mermaid source size limit', () {
      final atLimit = List.filled(49991, 'x').join();
      final overLimit = List.filled(49992, 'x').join();
      expect(
        parseNativeMermaidTimeline('timeline\n$atLimit').tasks.single.period,
        atLimit,
      );
      expect(
        () => parseNativeMermaidTimeline('timeline\n$overLimit'),
        throwsFormatException,
      );
      expect(
        parseNativeMermaidTimeline(
          '%%${List.filled(50001, 'x').join()}\ntimeline',
        ),
        isA<NativeMermaidTimelineDiagram>(),
      );
    });
  });
}
