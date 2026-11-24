import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_mobile/live/artifacts.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'live_test.dart' show FakeGateway, theme;

Json message(
  int v,
  String content, {
  String type = 'markdown',
  String status = 'complete',
}) => {
  'id': 'm$v',
  'role': 'assistant',
  'content':
      '說明\n\n```pirc-artifact\n${jsonEncode({'id': 'report', 'version': v, 'title': '報告', 'type': type, 'status': status, 'content': content})}\n```',
};
void main() {
  test(
    'invalid blocks preserve fallback, user messages never become artifacts',
    () {
      final malformed = {
        'role': 'assistant',
        'content': '```pirc-artifact\n{broken}\n```',
      };
      expect(messageArtifacts(malformed), isEmpty);
      expect(artifactProse(malformed), malformed['content']);
      expect(messageArtifacts({...message(1, 'x'), 'role': 'user'}), isEmpty);
      expect(artifactProse(message(1, 'x')), '說明');
    },
  );
  test(
    'completed revision is immutable; later versions survive across messages',
    () {
      final versions = artifactVersions([
        message(1, 'original'),
        message(1, 'overwrite'),
        message(2, 'new'),
      ], 'report');
      expect(versions.map((a) => a.content), ['original', 'new']);
    },
  );
  testWidgets(
    'new artifact version never replaces selection or scroll until explicit switch',
    (t) async {
      final g = FakeGateway();
      final c = LiveController(g)..sessionId = 's';
      final m = message(1, List.filled(60, '內容\n\n').join());
      c.state = {
        'messages': [m],
      };
      await t.pumpWidget(
        MaterialApp(
          theme: theme.build(Brightness.light),
          home: Scaffold(
            body: ArtifactPane(
              controller: c,
              initial: messageArtifacts(m).single,
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      final view = find.byKey(const Key('artifact-content'));
      await t.drag(view, const Offset(0, -250));
      await t.pumpAndSettle();
      final offset = t.widget<ListView>(view).controller!.offset;
      c.state = {
        'messages': [m, message(2, '新版')],
      };
      c.changed();
      await t.pumpAndSettle();
      expect(find.text('報告 · v1'), findsOneWidget);
      expect(t.widget<ListView>(view).controller!.offset, offset);
      await t.tap(find.text('已有 v2 · 切換新版'));
      await t.pumpAndSettle();
      expect(find.text('報告 · v2'), findsOneWidget);
      expect(t.widget<ListView>(view).controller!.offset, 0);
      expect(g.calls.where((x) => x.$1 == 'command'), isEmpty);
      await t.pumpWidget(const SizedBox());
      c.dispose();
      await g.stream.close();
    },
  );
  for (final type in ['markdown', 'code', 'table', 'image', 'html']) {
    testWidgets('$type renderer falls back without executing content', (
      t,
    ) async {
      final g = FakeGateway();
      final c = LiveController(g)..sessionId = 's';
      final a = Artifact({
        'id': 'a',
        'version': 1,
        'title': '成果',
        'type': type,
        'content': '<script>hello</script>',
        'columns': ['A', 'B'],
        'rows': [
          [1],
        ],
        'summary': '摘要',
      }, 'm');
      await t.pumpWidget(
        MaterialApp(
          theme: theme.build(Brightness.dark),
          home: Scaffold(
            body: ArtifactPane(controller: c, initial: a),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(g.calls, isEmpty);
      await t.pumpWidget(const SizedBox());
      c.dispose();
      await g.stream.close();
    });
  }
}
