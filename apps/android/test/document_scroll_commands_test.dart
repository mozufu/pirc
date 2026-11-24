import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show OverflowBoxFit;
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/document_element_scroll.dart';
import 'package:pirc_render/src/document_scroll_commands.dart';
import 'package:pirc_render/src/document_scroll_anchor.dart';
import 'live_test.dart' show theme;

final fixture =
    jsonDecode(
          File(
            'tool/parity/fixtures/document-scroll-commands-chromium153.json',
          ).readAsStringSync(),
        )
        as Map;
Widget scene(
  NativeDocumentScrollController root,
  NativeDocumentElementScrollController element,
) => SingleChildScrollView(
  controller: root,
  child: SizedBox(
    height: 2200,
    child: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: 180,
        height: 100,
        child: NativeDocumentElementScroll(
          controller: element,
          id: 'port',
          revision: 1,
          overflowX: NativeDocumentOverflow.auto,
          overflowY: NativeDocumentOverflow.auto,
          child: const OverflowBox(
            fit: OverflowBoxFit.deferToChild,
            alignment: Alignment.topLeft,
            minWidth: 600,
            maxWidth: 600,
            child: SizedBox(width: 600, height: 800),
          ),
        ),
      ),
    ),
  ),
);
void execute(
  String target,
  Map command,
  NativeDocumentScrollController root,
  NativeDocumentElementScrollController element,
) {
  if (target == 'root') {
    applyNativeDocumentScrollAxis(
      root,
      (command['y'] as num?)?.toDouble(),
      relative: command['kind'] == 'by',
      behavior: command['behavior'] as String,
    );
  } else {
    element.applyActions([
      {
        'id': 'port',
        'op': command['kind'] == 'by' ? 'scrollBy' : 'scrollTo',
        'left': command['x'],
        'top': command['y'],
        'behavior': command['behavior'],
      },
    ]);
  }
}

void check(
  Map expected,
  NativeDocumentScrollController root,
  NativeDocumentElementScrollController element,
) {
  expect(
    root.offset,
    closeTo((expected['root']['top'] as num).toDouble(), .01),
  );
  final metrics = element.metricsFor('port')!;
  expect(
    metrics['top'],
    closeTo((expected['element']['top'] as num).toDouble(), .01),
  );
  expect(
    metrics['left'],
    closeTo((expected['element']['left'] as num).toDouble(), .01),
  );
}

void main() {
  for (final row in fixture['cases'] as List) {
    testWidgets(
      'native command ${row['target']} ${row['mode']} ${row['viewport']['width']} dpr${row['dpr']} ${row['theme']}',
      (tester) async {
        final dpr = (row['dpr'] as num).toDouble();
        tester.view.devicePixelRatio = dpr;
        tester.view.physicalSize =
            Size(
              (row['viewport']['width'] as num).toDouble(),
              (row['viewport']['height'] as num).toDouble(),
            ) *
            dpr;
        addTearDown(tester.view.reset);
        final root = NativeDocumentScrollController(),
            element = NativeDocumentElementScrollController();
        try {
          await tester.pumpWidget(
            MaterialApp(
              theme: theme.build(
                row['theme'] == 'dark' ? Brightness.dark : Brightness.light,
              ),
              home: scene(root, element),
            ),
          );
          for (final command in row['commands'] as List) {
            execute(row['target'] as String, command as Map, root, element);
          }
          // These are actual native positions immediately after command execution,
          // distinct from the still-deferred JS snapshot getters.
          check(row['result']['immediate'] as Map, root, element);
          expect(element.pendingScrollEvents.length, lessThanOrEqualTo(1));
          await tester.pumpAndSettle();
          check(row['result']['settled'] as Map, root, element);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox());
          root.dispose();
          element.dispose();
        }
      },
    );
  }
  for (final target in ['root', 'element']) {
    for (final otherAxis in [false, true]) {
      testWidgets(
        'an active $target animation stops on ${otherAxis ? 'another axis' : 'the same current position'}',
        (tester) async {
          final root = NativeDocumentScrollController(),
              element = NativeDocumentElementScrollController();
          try {
            await tester.pumpWidget(MaterialApp(home: scene(root, element)));
            execute(
              target,
              {'kind': 'to', 'x': null, 'y': 180, 'behavior': 'smooth'},
              root,
              element,
            );
            await tester.pump(const Duration(milliseconds: 16));
            await tester.pump(const Duration(milliseconds: 60));
            final top = target == 'root'
                ? root.offset
                : element.metricsFor('port')!['top']!;
            expect(top, greaterThan(0));
            expect(top, lessThan(180));
            execute(
              target,
              {
                'kind': 'to',
                'x': otherAxis ? 0 : null,
                'y': otherAxis ? null : top,
                'behavior': 'instant',
              },
              root,
              element,
            );
            await tester.pumpAndSettle();
            final after = target == 'root'
                ? root.offset
                : element.metricsFor('port')!['top']!;
            expect(after, top);
            expect(tester.takeException(), isNull);
          } finally {
            await tester.pumpWidget(const SizedBox());
            root.dispose();
            element.dispose();
          }
        },
      );
    }
  }
}
