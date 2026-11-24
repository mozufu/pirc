// Measure and compare full selected text for the committed Chromium corpus.
// Partial forward/reverse pointer ranges are covered in markdown_selection_test.
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/native_markdown.dart';
import '../../test/live_test.dart' show theme;

void main() {
  testWidgets('measure native clipboard semantics against pinned web corpus', (
    t,
  ) async {
    final fixture =
        jsonDecode(
              File(
                '../../fixtures/mobile-parity/markdown-selection.json',
              ).readAsStringSync(),
            )
            as Map;
    final expected =
        jsonDecode(
              File(
                '../../fixtures/mobile-parity/markdown-selection-expected.json',
              ).readAsStringSync(),
            )
            as List;
    final output = <Map<String, dynamic>>[];
    for (final c in fixture['cases'] as List) {
      String? selected;
      await t.pumpWidget(
        MaterialApp(
          theme: theme.build(Brightness.light),
          home: Scaffold(
            body: SelectionArea(
              key: ValueKey(c['id']),
              onSelectionChanged: (content) => selected = content?.plainText,
              child: NativeMarkdown(source: c['source'] as String),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      t
          .state<SelectableRegionState>(find.byType(SelectableRegion))
          .selectAll(SelectionChangedCause.keyboard);
      await t.pumpAndSettle();
      expect(
        selected,
        expected.firstWhere((e) => e['id'] == c['id'])['text'],
        reason: c['id'] as String,
      );
      expect(t.takeException(), isNull);
      output.add({'id': c['id'], 'text': selected});
    }
    final dir = Directory('build/parity')..createSync(recursive: true);
    File('${dir.path}/markdown-selection-native-text.json').writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(output)}\n',
    );
  });
}
