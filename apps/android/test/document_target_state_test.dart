import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'live_test.dart' show theme;
import 'support/document_target_state_case.dart';

void main() {
  final fixture =
      jsonDecode(
            File(
              '../../packages/pirc_render/test/fixtures/parity/document-target-state-chromium153.json',
            ).readAsStringSync(),
          )
          as Map;
  for (final row in (fixture['cases'] as List).where(
    (r) => r['scripted'] == false,
  )) {
    testWidgets(
      'target state ${row['viewport']} dpr${row['dpr']} ${row['theme']}',
      (tester) async {
        expect(
          await checkDocumentTargetState(
            tester,
            row as Map,
            theme.build(
              row['theme'] == 'dark' ? Brightness.dark : Brightness.light,
            ),
          ),
          10,
        );
      },
    );
  }
}
