import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/document_fragment_scroll_case.dart';
import 'live_test.dart' show theme;

void main() {
  final fixture =
      jsonDecode(
            File(
              '../../packages/pirc_render/test/fixtures/parity/document-fragment-scroll-chromium153.json',
            ).readAsStringSync(),
          )
          as Map;
  for (final row in (fixture['cases'] as List).where(
    (r) => r['scripted'] == false,
  )) {
    if ([
      'default',
      'padding-margin',
      'zero-range',
      'root-padding',
      'css-smooth',
    ].contains(row['mode'])) {
      testWidgets(
        'initial native fragment geometry ${row['mode']} ${row['viewport']} dpr${row['dpr']} ${row['theme']}',
        (tester) async {
          await checkFragmentScrollCase(
            tester,
            row as Map,
            theme.build(
              row['theme'] == 'dark' ? Brightness.dark : Brightness.light,
            ),
            initial: true,
          );
        },
      );
    }
    testWidgets(
      'native fragment geometry ${row['mode']} ${row['viewport']} dpr${row['dpr']} ${row['theme']}',
      (tester) async {
        await checkFragmentScrollCase(
          tester,
          row as Map,
          theme.build(
            row['theme'] == 'dark' ? Brightness.dark : Brightness.light,
          ),
        );
      },
    );
  }
}
