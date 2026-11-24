import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart' show MatrixUtils, RenderParagraph;
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_mobile/live/files_state.dart';
import 'package:pirc_mobile/live/files_pane.dart';
import 'package:pirc_render/src/file_links.dart';
import 'live_test.dart' show FakeGateway, theme;
import '../tool/parity/capture_fonts.dart' show loadParityFonts;

Json content(String path, String text, {bool binary = false}) => {
  'path': path,
  'content': text,
  'binary': binary,
  'size': text.length,
  'modifiedAt': 1790960400000,
  'truncated': false,
};
Future<void> flush() => Future<void>.delayed(Duration.zero);
Widget shell(Widget child, {double scale = 1}) => MaterialApp(
  theme: theme.build(Brightness.light),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: Scaffold(body: child),
);
void main() {
  test('path and line ranges follow pinned web cases', () {
    final fixture = jsonDecode(
      File('../../fixtures/mobile-parity/files.json').readAsStringSync(),
    );
    for (final item in fixture['links']) {
      final parsed = parseFileTarget(item['href'], base: item['base'] ?? '');
      expect(
        parsed == null
            ? null
            : {
                'path': parsed.path,
                if (parsed.line != null) 'line': parsed.line,
                if (parsed.endLine != null) 'endLine': parsed.endLine,
              },
        item['expected'],
        reason: '${item['href']}',
      );
      if (parsed != null) {
        final roundtrip = parseFileTarget(parsed.href);
        expect(roundtrip?.path, parsed.path);
        expect(roundtrip?.line, parsed.line);
        expect(roundtrip?.endLine, parsed.endLine);
      }
    }
  });
  test(
    'read generations, exact paths, clamp focus, failed open and scope changes',
    () async {
      final g = FakeGateway(),
          c = LiveController(g)
            ..sessionId = 'one'
            ..origin = 'a';
      final slow = Completer<Json>(), obsolete = Completer<Json>();
      g.handler = (_, args) async {
        final uri = Uri.parse(args['path']), path = uri.queryParameters['path'];
        if (uri.path.endsWith('/files')) return {'path': path, 'entries': []};
        if (path == 'slow.txt') return slow.future;
        if (path == 'obsolete.txt') return obsolete.future;
        if (path == 'missing.txt') {
          throw PlatformException(code: 'HTTP_404', message: 'No such file');
        }
        return content('src/main.ts', 'first\nsecond\nthird\n');
      };
      final state = FilesState(c);
      await flush();
      final old = state.open(const FileTarget('slow.txt'));
      await state.open(
        const FileTarget('/workspace/src/main.ts', line: 2, endLine: 999),
      );
      expect(state.file!['path'], 'src/main.ts');
      expect(state.line, 2);
      expect(state.endLine, 3);
      expect(state.rendered, false);
      await flush();
      expect(state.dir, 'src');
      slow.complete(content('slow.txt', 'old'));
      await old;
      expect(state.file!['path'], 'src/main.ts');
      await state.open(const FileTarget('missing.txt'));
      expect(state.file, isNull);
      expect(state.error, 'missing.txt: No such file');
      final late = state.open(const FileTarget('obsolete.txt'));
      c.origin = 'new-account';
      c.sessionId = 'one';
      c.changed();
      obsolete.complete(content('obsolete.txt', 'private old file'));
      await late;
      await flush();
      expect(state.file, isNull);
      expect(state.dir, '');
      state.dispose();
      c.dispose();
      await g.stream.close();
    },
  );
  test(
    'hidden run completion defers refresh; reopen restores source and range',
    () async {
      final g = FakeGateway(), c = LiveController(g)..sessionId = 'one';
      g.handler = (_, args) async => '${args['path']}'.contains('/content')
          ? content('guide.md', '# Guide\nnext\n')
          : {'path': '', 'entries': []};
      final state = FilesState(c);
      await flush();
      await state.open(const FileTarget('guide.md', line: 2));
      final before = g.calls.length;
      state.setActive(false);
      c.state = {
        'run': {'status': 'running'},
      };
      c.changed();
      c.state = {
        'run': {'status': 'idle'},
      };
      c.changed();
      await flush();
      expect(g.calls.length, before);
      expect(state.stale, true);
      state.setActive(true);
      await flush();
      expect(g.calls.length, before + 2);
      expect(state.line, 2);
      expect(state.rendered, false);
      state.dispose();
      final reopened = FilesState(c);
      await flush();
      expect(reopened.file!['path'], 'guide.md');
      expect(reopened.line, 2);
      expect(reopened.rendered, false);
      reopened.dispose();
      c.dispose();
      await g.stream.close();
    },
  );
  testWidgets(
    'directory types, Markdown source toggle, relative links and back',
    (t) async {
      final g = FakeGateway(), c = LiveController(g)..sessionId = 's';
      g.handler = (_, args) async {
        final uri = Uri.parse(args['path']), path = uri.queryParameters['path'];
        if (uri.path.endsWith('/files')) {
          return {
            'path': path,
            'entries': [
              {'name': 'guide.md', 'kind': 'file', 'size': 30},
              {'name': 'socket', 'kind': 'other'},
            ],
            'truncated': true,
          };
        }
        return path == 'docs/guide.md'
            ? content(path!, '[source](../src/main.ts#L2-L3)')
            : content(path!, 'one\ntwo\nthree');
      };
      await t.pumpWidget(
        shell(FilesPane(controller: c, initialPath: 'docs/guide.md')),
      );
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('Show source'));
      await t.pumpAndSettle();
      expect(find.byType(NativeFileSource), findsOneWidget);
      await t.tap(find.byTooltip('Show rendered'));
      await t.pumpAndSettle();
      await t.tap(find.text('source'));
      await t.pumpAndSettle();
      expect(
        g.calls.any(
          (call) =>
              call.$2['path'] ==
              '/api/sessions/s/files/content?path=src%2Fmain.ts',
        ),
        true,
      );
      expect(find.text('src/main.ts:2-3'), findsOneWidget);
      await t.tap(find.byTooltip('Back to folder'));
      await t.pumpAndSettle();
      expect(find.text('Showing the first 2,000 entries.'), findsOneWidget);
      expect(
        t
            .widget<TextButton>(find.widgetWithText(TextButton, 'socket'))
            .onPressed,
        isNull,
      );
      expect(find.text('..'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
      c.dispose();
      await g.stream.close();
    },
  );
  testWidgets(
    'binary/oversized-image and long source stay visible at 2x text',
    (t) async {
      addTearDown(t.view.reset);
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(390, 844);
      final g = FakeGateway(), c = LiveController(g)..sessionId = 's';
      g.handler = (_, args) async => '${args['path']}'.contains('/content')
          ? {...content('image.png', '', binary: true), 'imageTooLarge': true}
          : {'entries': []};
      await t.pumpWidget(
        shell(FilesPane(controller: c, initialPath: 'image.png'), scale: 2),
      );
      await t.pumpAndSettle();
      expect(find.text('Image too large to preview.'), findsOneWidget);
      expect(t.takeException(), isNull);
      await t.pumpWidget(
        shell(
          NativeFileSource(
            file: content(
              'long.ts',
              List.generate(
                100,
                (i) => 'const value$i = "${'wide' * 50}";',
              ).join('\n'),
            ),
            line: 90,
            endLine: 95,
          ),
          scale: 2,
        ),
      );
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      final scrolls = t.widgetList<SingleChildScrollView>(
        find.byType(SingleChildScrollView),
      );
      expect(scrolls.first.controller!.offset, greaterThan(0));
      await t.pumpWidget(const SizedBox());
      c.dispose();
      await g.stream.close();
    },
  );
  testWidgets('SVG is a native vector preview with natural dimensions', (
    t,
  ) async {
    Size? natural;
    await t.pumpWidget(
      shell(
        NativeFileImage(
          image: {
            'mimeType': 'image/svg+xml',
            'dataBase64': base64Encode(
              utf8.encode(
                '<svg xmlns="http://www.w3.org/2000/svg" width="180" height="90"><rect width="180" height="90" fill="#4176e6"/></svg>',
              ),
            ),
          },
          alt: 'test.svg',
          onSize: (value) => natural = value,
        ),
      ),
    );
    await t.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 150));
    });
    await t.pumpAndSettle();
    expect(natural, const Size(180, 90));
    expect(find.byType(SvgPicture), findsOneWidget);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets('wide intrinsic file rows keep the size suffix visible at 2x', (
    t,
  ) async {
    await t.runAsync(loadParityFonts);
    addTearDown(t.view.reset);
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(861, 844);
    final g = FakeGateway(), c = LiveController(g)..sessionId = 's';
    g.handler = (_, args) async => '${args['path']}'.contains('/files?')
        ? {
            'path': '',
            'entries': [
              {'name': 'README.md', 'kind': 'file', 'size': 256},
              {'name': 'architecture.svg', 'kind': 'file', 'size': 277},
            ],
          }
        : content('README.md', '');
    await t.pumpWidget(
      shell(
        Theme(
          data: theme
              .build(Brightness.light)
              .copyWith(
                textTheme: theme
                    .build(Brightness.light)
                    .textTheme
                    .apply(fontFamily: 'Arial'),
              ),
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: 280, child: FilesPane(controller: c)),
          ),
        ),
        scale: 2,
      ),
    );
    await t.pumpAndSettle();

    final sizeText = find.text('256 B');
    expect(sizeText, findsOneWidget);
    final paragraph = t.renderObject<RenderParagraph>(sizeText);
    final suffix = paragraph.getBoxesForSelection(
      const TextSelection(baseOffset: 4, extentOffset: 5),
    );
    expect(suffix, hasLength(1));
    final suffixRect = MatrixUtils.transformRect(
      paragraph.getTransformTo(null),
      suffix.single.toRect(),
    );
    expect(suffixRect.width, greaterThan(0));
    expect(suffixRect.right, lessThanOrEqualTo(280));
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
    c.dispose();
    await g.stream.close();
  });
}
