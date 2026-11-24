import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pirc_mobile/theme.dart';
import 'package:pirc_render/src/native_markdown.dart';
import 'package:pirc_render/src/mermaid/requirement_rendering.dart';

// Sources come from the pinned Mermaid parser/Chrome oracle fixture.
const cases = <Map<String, String>>[
  {
    'id': "basic-requirement-element-satisfies",
    'source': r'''requirementDiagram
requirement SignIn {
id: REQ1
text: The service shall authenticate each user.
risk: high
verifyMethod: test
}
element Gateway {
type: service
docRef: API1
}
Gateway - satisfies -> SignIn''',
  },
  {
    'id': "all-requirement-types-risks-verification-methods",
    'source': r'''requirementDiagram
requirement General {
id: R1
text: General constraint.
risk: low
verifyMethod: analysis
}
functionalRequirement Functional {
id: R2
text: Functional behavior.
risk: medium
verifyMethod: demonstration
}
interfaceRequirement Interface {
id: R3
text: Interface contract.
risk: high
verifyMethod: inspection
}
performanceRequirement Performance {
id: R4
text: Latency bound.
risk: low
verifyMethod: test
}
physicalRequirement Physical {
id: R5
text: Physical dimensions.
risk: medium
verifyMethod: analysis
}
designConstraint Design {
id: R6
text: Design constraint.
risk: high
verifyMethod: test
}''',
  },
  {
    'id': "all-relations-forward-reverse",
    'source': r'''requirementDiagram
requirement R1 {
id: R1
text: Top level.
}
requirement R2 {
id: R2
text: Derived level.
}
requirement R3 {
id: R3
text: Trace target.
}
element E1 {
type: service
docRef: E1REF
}
element E2 {
type: client
docRef: E2REF
}
R1 - contains -> R2
R2 <- copies - R1
R2 - derives -> E1
E1 <- satisfies - R1
R1 - verifies -> E2
E2 <- refines - R2
E2 - traces -> R3''',
  },
  {
    'id': "direction-lr-disconnected-nodes",
    'source': r'''requirementDiagram
direction LR
requirement Left {
id: LEFT
text: Connected source.
}
element Processor {
type: service
docRef: PROC1
}
requirement Right {
id: RIGHT
text: Connected target.
}
requirement Isolated {
id: SOLO
text: This node has no relationships.
}
Processor - satisfies -> Left''',
  },
  {
    'id': "long-quoted-html-entities-accessibility",
    'source': r'''requirementDiagram
accTitle: Extended authentication requirements
accDescr {
A multiline accessibility description for the long requirement diagram.
It preserves an &amp; entity and literal <b>HTML</b> input.
}
functionalRequirement LongLabel {
id: REQLONG
text: "The service shall preserve a deliberately long quoted statement with an &amp; entity, literal <b>HTML</b>, and &quot;quoted words&quot; for inspection across multiple rendered lines."
risk: medium
verifyMethod: inspection
}
element LongService {
type: "A deliberately long service type label"
docRef: DOCLONG
}
LongService - satisfies -> LongLabel''',
  },
  {
    'id': "classes-styles-duplicates-default-class",
    'source': r'''requirementDiagram
classDef default fill:#fff1cc,stroke:#92400e,color:#1f2937
requirement PlainDefault {
id: DEFAULT
text: Default class probe.
}
requirement R {
id: FIRST
id: SECOND
text: First field value.
text: Second field value.
risk: low
risk: high
}
requirement R {
id: REPLACEMENT
text: Duplicate name value.
}
element E {
type: first
type: second
docRef: FIRSTREF
docRef: SECONDREF
}
element E {
type: duplicate
}
requirement Urgent:::hot {
id: URGENT
text: Urgent requirement.
}
element Worker:::cool {
type: processor
docRef: WORKERREF
}
class R,E hot
style R fill:#dbeafe,stroke:#1d4ed8,color:#123456
classDef hot fill:#fee2e2,stroke:#b91c1c,color:#7f1d1d
classDef cool fill:#dcfce7,stroke:#15803d,color:#14532d
R - satisfies -> E''',
  },
];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Android renders all requirement fixture content in both themes',
    (t) async {
      final theme = await PircTheme.load();
      for (final brightness in Brightness.values) {
        for (final input in cases) {
          const boundary = ValueKey('requirement-android');
          await t.pumpWidget(
            MaterialApp(
              theme: theme.build(brightness),
              home: Scaffold(
                body: SingleChildScrollView(
                  child: RepaintBoundary(
                    key: boundary,
                    child: NativeMarkdown(
                      source: '~~~mermaid\n${input['source']}\n~~~',
                    ),
                  ),
                ),
              ),
            ),
          );
          await t.pumpAndSettle();
          expect(find.byType(NativeMermaidRequirement), findsOneWidget);
          expect(find.textContaining('Mermaid:'), findsNothing);
          final canvas = find.byWidgetPredicate(
            (w) => w is CustomPaint && w.painter is NativeRequirementPainter,
          );
          expect(canvas, findsOneWidget);
          final painter =
              t.widget<CustomPaint>(canvas).painter!
                  as NativeRequirementPainter;
          for (final node in painter.layout.nodes) {
            expect(node.fields, isNotEmpty);
            expect(node.bounds.width, greaterThan(0));
            expect(node.bounds.height, greaterThan(0));
          }
          final colors = await t.runAsync(() async {
            final image = await t
                .renderObject<RenderRepaintBoundary>(find.byKey(boundary))
                .toImage(pixelRatio: 1);
            try {
              final bytes = (await image.toByteData(
                format: ui.ImageByteFormat.rawRgba,
              ))!.buffer.asUint8List();
              final unique = <int>{};
              for (var i = 0; i + 3 < bytes.length; i += 16) {
                if (bytes[i + 3] != 0) {
                  unique.add(
                    (bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2],
                  );
                }
              }
              return unique.length;
            } finally {
              image.dispose();
            }
          });
          expect(
            colors,
            greaterThan(2),
            reason: '${brightness.name}/${input['id']} painted pixels',
          );
          expect(t.takeException(), isNull);
          await t.pumpWidget(const SizedBox());
        }
      }
    },
  );
}
