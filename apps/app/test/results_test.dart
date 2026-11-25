import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_app/src/work/artifacts.dart';
import 'package:pirc_app/src/work/result_reader.dart';
import 'package:pirc_client/pirc_client.dart';

import 'support/harness.dart';
import 'support/session_fixture.dart';

String _block(Map<String, Object?> data) =>
    '```pirc-artifact\n${jsonEncode(data)}\n```';

Map<String, Object?> _assistant(String text, int at) => {
  'role': 'assistant',
  'content': [
    {'type': 'text', 'text': text},
  ],
  'stopReason': 'stop',
  'timestamp': at,
};

Map<String, Object?> _report(
  int version, {
  String status = 'complete',
  String type = 'markdown',
  String? content,
}) => {
  'id': 'report',
  'version': version,
  'title': 'API report',
  'type': type,
  'summary': 'Three specs compared',
  'status': status,
  'content':
      content ?? List.generate(80, (i) => 'v$version line $i').join('\n\n'),
};

Future<FixtureSession> _open(
  WidgetTester tester,
  List<Map<String, Object?>> versions, {
  double width = 1300,
}) async {
  final s = FixtureSession('joined-mid-stream.json');
  final history = s.snapshot['history']! as List;
  for (final (i, version) in versions.indexed) {
    history.add(
      _assistant('Here it is.\n\n${_block(version)}', 2000 + i * 100),
    );
  }
  s.gateway = s.install();
  await pumpApp(
    tester,
    gateway: s.gateway!,
    width: width,
    height: 1200,
    location: '/work?open=s2',
  );
  return s;
}

Future<void> _openCard(WidgetTester tester, {int index = 0}) async {
  final open = find.text('Open');
  await tester.ensureVisible(open.at(index));
  await tester.pumpAndSettle();
  await tester.tap(open.at(index));
  await tester.pumpAndSettle();
}

void main() {
  group('parsing', () {
    Message msg(String content, {bool partial = false}) => Message(
      id: 'm1',
      role: 'assistant',
      content: content,
      createdAt: 1,
      isPartial: partial,
    );

    test('valid blocks become results; malformed ones stay Markdown', () {
      final content =
          'Intro\n\n${_block(_report(1))}\n\n```pirc-artifact\n{bad json\n```';
      final found = messageArtifacts(msg(content));
      expect(found.single.version, 1);
      expect(artifactProse(msg(content)), contains('{bad json'));
      expect(artifactProse(msg(content)), isNot(contains('"report"')));
    });

    test('a partial message is generating; versions keep completed ones', () {
      expect(
        messageArtifacts(msg(_block(_report(1)), partial: true)).single.status,
        'generating',
      );
      final versions = artifactVersions([
        msg(_block(_report(1, content: 'first'))),
        msg(_block(_report(2))).copyWith(id: 'm2'),
        msg(_block(_report(1, content: 'rewrite'))).copyWith(id: 'm3'),
      ], 'report');
      expect([for (final a in versions) a.version], [1, 2]);
      expect(versions.first.content, 'first');
    });

    test('a table shares as tab-separated lines', () {
      final table = messageArtifacts(
        msg(
          _block({
            'id': 't',
            'version': 1,
            'title': 'T',
            'type': 'table',
            'columns': ['a', 'b'],
            'rows': [
              [1, 2],
            ],
          }),
        ),
      ).single;
      expect(table.shareText, 'T\na\tb\n1\t2');
    });
  });

  appTest('a card shows kind, version, title and summary; open reads it', (
    tester,
  ) async {
    await _open(tester, [_report(1)]);
    expect(find.text('markdown · v1'), findsOneWidget);
    expect(find.text('API report'), findsOneWidget);
    expect(find.text('Three specs compared'), findsOneWidget);
    await _openCard(tester);
    expect(find.byType(ResultReader), findsOneWidget);
    expect(find.text('API report · v1'), findsOneWidget);
  });

  for (final (width, beside) in [
    (1300.0, true),
    (1000.0, false),
    (375.0, false),
  ]) {
    appTest('$width wide: the reader ${beside ? 'sits beside' : 'replaces'} '
        'the conversation', (tester) async {
      await _open(tester, [_report(1)], width: width);
      await _openCard(tester);
      final reader = tester.getRect(find.byType(ResultReader));
      if (beside) {
        expect(reader.width, 400);
        expect(find.text('Here it is.', findRichText: true), findsWidgets);
      } else {
        expect(reader.width, greaterThan(width / 2));
      }
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.byType(ResultReader), findsNothing);
    });
  }

  appTest('a newer version shows a note; the reader never switches itself', (
    tester,
  ) async {
    final s = await _open(tester, [_report(1)]);
    await _openCard(tester);
    // v2 arrives while v1 is open.
    (s.snapshot['history']! as List).add(
      _assistant('Updated.\n\n${_block(_report(2))}', 3000),
    );
    s.gateway!.socket('/api/events')!.push({
      'type': 'reset',
      'reason': 'cursor_expired',
      'watermark': {'epoch': 1, 'sequence': 4},
    });
    await tester.pumpAndSettle();
    expect(find.text('API report · v1'), findsOneWidget);
    expect(find.text('Version 2 is ready.'), findsOneWidget);
    await tester.tap(find.text('Switch to v2'));
    await tester.pumpAndSettle();
    expect(find.text('API report · v2'), findsOneWidget);
    expect(find.text('Version 2 is ready.'), findsNothing);
  });

  appTest('each version keeps its own reading position', (tester) async {
    await _open(tester, [_report(1), _report(2)]);
    await _openCard(tester, index: 0);
    // v2 is the latest: it opens first.
    expect(find.text('API report · v2'), findsOneWidget);
    final list = find.byKey(const ValueKey('reader-2'));
    await tester.drag(list, const Offset(0, -600));
    await tester.pumpAndSettle();
    final scrolled = tester.widget<ListView>(list).controller!.offset;
    expect(scrolled, greaterThan(0));
    await tester.tap(find.byTooltip('Versions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('v1').last);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<ListView>(find.byKey(const ValueKey('reader-1')))
          .controller!
          .offset,
      0,
    );
    await tester.tap(find.byTooltip('Versions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('v2').last);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<ListView>(find.byKey(const ValueKey('reader-2')))
          .controller!
          .offset,
      scrolled,
    );
  });

  appTest('a failed version: the last good one stays', (tester) async {
    await _open(tester, [_report(1), _report(2, status: 'failed')]);
    expect(find.text('Failed'), findsOneWidget);
    await _openCard(tester, index: 1);
    expect(find.text('API report · v1'), findsOneWidget);
    expect(
      find.text('Version 2 failed. The last good version is shown.'),
      findsOneWidget,
    );
  });

  appTest('a kind the app does not support shows its summary', (tester) async {
    await _open(tester, [_report(1, type: 'chart')]);
    await _openCard(tester);
    expect(
      find.text('This kind of result is shown as its summary.'),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(ResultReader),
        matching: find.textContaining(
          'Three specs compared',
          findRichText: true,
        ),
      ),
      findsWidgets,
    );
  });

  appTest('a result still generating says so', (tester) async {
    final s = FixtureSession('joined-mid-stream.json');
    s.snapshot['partialMessage'] = {
      'base': {'role': 'assistant', 'content': [], 'timestamp': 9000},
      'content': {
        '0': {'type': 'text', 'text': _block(_report(1))},
      },
    };
    s.gateway = s.install();
    await pumpApp(tester, gateway: s.gateway!, location: '/work?open=s2');
    expect(find.text('Generating…'), findsOneWidget);
    expect(find.text('Read what is ready'), findsOneWidget);
  });
}
