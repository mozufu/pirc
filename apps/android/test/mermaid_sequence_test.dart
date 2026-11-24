import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/mermaid/sequence.dart';
import '../tool/parity/capture_fonts.dart';

void main() {
  group('native Mermaid sequence parser', () {
    test(
      'keeps aliases, implicit participants, notes, arrows, and activations',
      () {
        final diagram = parseNativeMermaidSequence('''
sequenceDiagram
actor U as "User"
participant API as "Public API"
autonumber 3 2
U->>+API: request
API-->>-U: response
autonumber off
API->>API: retry
Note left of U: Caller
Note right of API: Handler
Note over U,API: complete
''');

        expect(diagram.participants.map((participant) => participant.id), [
          'U',
          'API',
        ]);
        expect(diagram.participants.map((participant) => participant.label), [
          'User',
          'Public API',
        ]);
        expect(
          diagram.participants.first.kind,
          NativeSequenceParticipantKind.actor,
        );

        final messages = diagram.events
            .whereType<NativeSequenceMessage>()
            .toList();
        expect(messages.map((message) => message.arrow), [
          NativeSequenceArrow.solid,
          NativeSequenceArrow.dashed,
          NativeSequenceArrow.solid,
        ]);
        expect(messages.map((message) => message.number), [3, 5, null]);
        expect(messages.map((message) => message.activation), [
          NativeSequenceActivationMarker.activateReceiver,
          NativeSequenceActivationMarker.deactivateSender,
          NativeSequenceActivationMarker.none,
        ]);
        final notes = diagram.events.whereType<NativeSequenceNote>().toList();
        expect(notes.map((note) => note.placement), [
          NativeSequenceNotePlacement.left,
          NativeSequenceNotePlacement.right,
          NativeSequenceNotePlacement.over,
        ]);
        expect(diagram.events.whereType<NativeSequenceActivation>(), isEmpty);
      },
    );

    testWidgets(
      'adds participants on first message and keeps nested frame boundaries',
      (tester) async {
        await tester.runAsync(loadParityFonts);
        final diagram = parseNativeMermaidSequence('''
sequenceDiagram
loop health check
  A->>B: ping
  alt ready
    B-->>A: yes
  else waiting
    B--xA: no
  end
end
''');

        expect(diagram.participants.map((participant) => participant.id), [
          'A',
          'B',
        ]);
        expect(
          diagram.events.whereType<NativeSequenceFrameStart>(),
          hasLength(2),
        );
        expect(
          diagram.events.whereType<NativeSequenceFrameDivider>(),
          hasLength(1),
        );
        expect(
          diagram.events.whereType<NativeSequenceFrameEnd>(),
          hasLength(2),
        );
        final layout = layoutNativeMermaidSequence(
          diagram,
          inheritedTextStyle: const TextStyle(fontFamily: 'Arial'),
        );
        expect(layout.frames, hasLength(2));
        expect(layout.frames.every((frame) => frame.height >= 32), isTrue);
      },
    );

    test('distinguishes headless, open, filled, and dashed arrows', () {
      final diagram = parseNativeMermaidSequence('''
sequenceDiagram
A->B: direct line
A-->B: dotted line
A-)B: async open arrow
A--)B: dotted async open arrow
A->>B: filled arrow
A-->>B: dotted filled arrow
''');
      final arrows = diagram.events.whereType<NativeSequenceMessage>().map(
        (message) => message.arrow,
      );
      expect(arrows, [
        NativeSequenceArrow.solidLine,
        NativeSequenceArrow.dashedLine,
        NativeSequenceArrow.solidOpen,
        NativeSequenceArrow.dashedOpen,
        NativeSequenceArrow.solid,
        NativeSequenceArrow.dashed,
      ]);
    });

    test('upgrades implicit participants and accepts numeric/quoted ids', () {
      final diagram = parseNativeMermaidSequence('''
sequenceDiagram
42->>"Public API": request
participant 42 as Caller
actor "Public API" as Service
''');
      expect(diagram.participants.map((participant) => participant.id), [
        '42',
        'Public API',
      ]);
      expect(diagram.participants.map((participant) => participant.label), [
        'Caller',
        'Service',
      ]);
      expect(
        diagram.participants.last.kind,
        NativeSequenceParticipantKind.actor,
      );
    });

    test(
      'quoted note identifiers preserve commas without phantom participants',
      () {
        final diagram = parseNativeMermaidSequence('''
sequenceDiagram
participant "A, B" as Team
Note over "A, B": One participant
''');
        expect(diagram.participants.map((p) => p.id), ['A, B']);
        expect((diagram.events.single as NativeSequenceNote).participants, [
          'A, B',
        ]);
      },
    );

    test('rejects unsupported syntax and unbalanced constructs', () {
      expect(
        () => parseNativeMermaidSequence('flowchart LR\nA-->B'),
        throwsFormatException,
      );
      expect(
        () => parseNativeMermaidSequence(
          'sequenceDiagram\n%%{init: {"theme":"dark"}}%%',
        ),
        throwsFormatException,
      );
      expect(
        () => parseNativeMermaidSequence(
          'sequenceDiagram\nA->>B: hi\ncreate participant C',
        ),
        throwsFormatException,
      );
      expect(
        () => parseNativeMermaidSequence('sequenceDiagram\nend'),
        throwsFormatException,
      );
      expect(
        () => parseNativeMermaidSequence('sequenceDiagram\nloop open'),
        throwsFormatException,
      );
      expect(
        () => parseNativeMermaidSequence(
          'sequenceDiagram\nA->>B: hi\ndeactivate A',
        ),
        throwsFormatException,
      );
    });
  });

  group('native Mermaid sequence layout', () {
    testWidgets('preserves pinned participant geometry and message ordering', (
      tester,
    ) async {
      await tester.runAsync(loadParityFonts);
      final diagram = parseNativeMermaidSequence('''
sequenceDiagram
participant A as Alice
participant B as Bob
A->>B: Hello
B-->>A: Hi
''');
      final layout = layoutNativeMermaidSequence(
        diagram,
        inheritedTextStyle: const TextStyle(fontFamily: 'Arial'),
      );

      // Pinned Mermaid 11.17.2: a 450px viewBox, 150px actor boxes, and
      // 50px participant margin. The browser viewBox starts at x=-50.
      expect(layout.width, 450);
      expect(layout.participantWidths.values, everyElement(150));
      expect(layout.participantCenters['A'], 125);
      expect(layout.participantCenters['B'], 325);
      expect(layout.headerTop, 0);
      // Vertical text metrics are platform dependent; the web reference is
      // footer=185, height=271. Pixel parity remains open in plans/mobile.md.
      expect(layout.footerTop, layout.events.last.lineY! + 20);
      expect(layout.height, layout.footerTop + 86);
      expect(
        layout.events.whereType<NativeSequencePositionedEvent>().length,
        2,
      );
      expect(layout.events.first.lineY, greaterThan(65));
      expect(layout.events.last.lineY, greaterThan(layout.events.first.lineY!));
    });

    testWidgets(
      'positions a right note and self message inside the expanded viewBox',
      (tester) async {
        await tester.runAsync(loadParityFonts);
        final diagram = parseNativeMermaidSequence('''
sequenceDiagram
participant A as Alice
A->>A: Think
Note right of A: Decision made
''');
        final layout = layoutNativeMermaidSequence(
          diagram,
          inheritedTextStyle: const TextStyle(fontFamily: 'Arial'),
        );
        final notePosition = layout.events.singleWhere(
          (event) => event.event is NativeSequenceNote,
        );

        expect(layout.width, 350);
        expect(notePosition.top, 151);
        expect(notePosition.height, 38);
        expect(layout.footerTop, 209);
        expect(layout.height, 295);
        final messagePosition = layout.events.singleWhere(
          (event) => event.event is NativeSequenceMessage,
        );
        expect(messagePosition.lineY, 111);
      },
    );

    testWidgets('paints a responsive Flutter-native diagram', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 390,
              child: const NativeMermaidSequence(
                source: 'sequenceDiagram\nA->>B: Hello',
                dark: false,
              ),
            ),
          ),
        ),
      );

      expect(find.byType(NativeMermaidSequence), findsOneWidget);
      final semantics = tester
          .getSemantics(find.byType(NativeMermaidSequence))
          .getSemanticsData();
      expect(semantics.flagsCollection.isImage, isTrue);
      expect(semantics.label, contains('Participants: A, B'));
      expect(semantics.label, contains('A to B: Hello'));
      final paintFinder = find.descendant(
        of: find.byType(NativeMermaidSequence),
        matching: find.byType(CustomPaint),
      );
      final paint = tester.widget<CustomPaint>(paintFinder);
      expect(paint.painter, isNotNull);
      expect(tester.getSize(paintFinder).width, 390);
      expect(tester.getSize(paintFinder).height, lessThan(250));
    });
  });
}
