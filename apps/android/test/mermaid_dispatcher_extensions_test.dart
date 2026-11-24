import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/native_markdown.dart';
import 'package:pirc_render/src/mermaid/git_graph_rendering.dart';
import 'package:pirc_render/src/mermaid/journey_rendering.dart';
import 'package:pirc_render/src/mermaid/kanban_rendering.dart';
import 'package:pirc_render/src/mermaid/sankey_rendering.dart';
import 'package:pirc_render/src/mermaid/block_rendering.dart';
import 'live_test.dart' show theme;

void main() {
  testWidgets(
    'Markdown dispatch renders five native diagram extensions in phone/tablet themes',
    (t) async {
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      const source =
          '```mermaid\njourney\ntitle Release\nsection Build\nCompile: 5: Developer\nTest: 3: QA\n```\n\n'
          '```mermaid\ngitGraph\ncommit id: "a"\nbranch dev\ncommit id: "b"\ncheckout main\ncommit id: "c"\nmerge dev id: "merged"\n```'
          '\n\n```mermaid\nkanban\n  Backlog\n    card[**Implement** renderer]@{assigned: Lee, ticket: APP-12}\n  Done\n    shipped[Ship]\n```'
          '\n\n```mermaid\nsankey-beta\nA,B,5\nA,C,3\nB,D,4\nC,D,4\n```'
          '\n\n```mermaid\nblock-beta\ncolumns 2\nA["Input"]\nB["Output"]\nA --> B\n```';
      for (final width in [390.0, 768.0]) {
        t.view.physicalSize = Size(width, 1000);
        for (final brightness in Brightness.values) {
          for (final scale in [1.0, 2.0]) {
            await t.pumpWidget(
              MaterialApp(
                theme: theme.build(brightness),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!,
                ),
                home: const Scaffold(
                  body: SingleChildScrollView(
                    padding: EdgeInsets.all(16),
                    child: NativeMarkdown(source: source, lineHeight: 1.65),
                  ),
                ),
              ),
            );
            await t.pumpAndSettle();
            expect(
              t.takeException(),
              isNull,
              reason: '$width/$brightness/$scale',
            );
            expect(find.byType(NativeMermaidJourney), findsOneWidget);
            expect(find.byType(NativeMermaidGitGraph), findsOneWidget);
            expect(find.byType(NativeMermaidKanban), findsOneWidget);
            expect(find.byType(NativeMermaidSankey), findsOneWidget);
            expect(find.byType(NativeMermaidBlockChart), findsOneWidget);
            expect(
              t.getSize(find.byType(NativeMermaidGitGraph)).width,
              lessThanOrEqualTo(width - 32),
            );
            expect(
              t.getSize(find.byType(NativeMermaidJourney)).width,
              lessThanOrEqualTo(width - 32),
            );
          }
        }
      }
    },
  );
  testWidgets(
    'invalid layouts and unsupported labels preserve source without framework errors',
    (t) async {
      for (final source in [
        'sankey-beta\nA,B,1\nB,A,1',
        'sankey\nA,B,0',
        'block-beta\ncolumns 0\nA["Input"]',
        'kanban\n  Backlog\n    card[<span style="color:red">Styled</span>]',
      ]) {
        await t.pumpWidget(
          MaterialApp(
            theme: theme.build(Brightness.light),
            home: Scaffold(
              body: SingleChildScrollView(
                child: NativeMarkdown(
                  source: '```mermaid\n$source\n```',
                  lineHeight: 1.65,
                ),
              ),
            ),
          ),
        );
        await t.pumpAndSettle();
        expect(t.takeException(), isNull, reason: source);
        expect(find.text(source), findsOneWidget);
        expect(find.textContaining('Mermaid:'), findsOneWidget);
        expect(find.byType(NativeMermaidSankey), findsNothing);
        expect(find.byType(NativeMermaidKanban), findsNothing);
        expect(find.byType(NativeMermaidBlockChart), findsNothing);
      }
    },
  );
}
