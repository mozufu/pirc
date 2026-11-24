import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:pirc_render/src/html_file.dart';

void main() {
  group('NativeHtmlFileInputState', () {
    test(
      'parses accept, multiple, required, disabled fieldsets and labels',
      () {
        const source = '''
<fieldset disabled>
  <legend><label>First <input id="allowed" type="file" name="upload" multiple accept=".TXT, image/*" required></label></legend>
  <input id="blocked" type="file" name="blocked">
</fieldset>
<label for="allowed">Explicit label</label>
''';
        final state = NativeHtmlFileInputState.fromHtml(
          source,
          picker: (_) async => null,
        );
        addTearDown(state.dispose);
        final root = html.parseFragment(state.annotateHtml(source));
        final allowed = root.querySelector('#allowed')!;
        final blocked = root.querySelector('#blocked')!;
        final firstLabel = root.querySelector('legend label')!;
        final explicitLabel = root.querySelector('label[for=allowed]')!;

        final first = state.resolveControl(allowed)!;
        final second = state.resolveControl(blocked)!;
        expect(first.name, 'upload');
        expect(first.accept, ['.txt', 'image/*']);
        expect(first.multiple, isTrue);
        expect(first.required, isTrue);
        expect(first.disabled, isFalse);
        expect(first.visible, isTrue);
        expect(first.label, 'First Explicit label');
        expect(second.disabled, isTrue);
        expect(state.willValidate(second.key), isFalse);
        expect(state.isRequiredSatisfied(second.key), isTrue);
        expect(state.valueMissing(second.key), isFalse);
        expect(state.resolveLabel(firstLabel)?.key, first.key);
        expect(state.resolveLabel(explicitLabel)?.key, first.key);
        expect(state.isRequiredSatisfied(first.key), isFalse);
      },
    );

    test('CSS-hidden required controls validate; disabled ones are barred', () {
      const source = '''
<input id="hidden" type="file" required style="display:none">
<fieldset disabled><input id="barred" type="file" required></fieldset>
''';
      final state = NativeHtmlFileInputState.fromHtml(
        source,
        picker: (_) async => null,
      );
      addTearDown(state.dispose);
      final root = html.parseFragment(state.annotateHtml(source));
      final hidden = state.resolveControl(root.querySelector('#hidden')!)!;
      final barred = state.resolveControl(root.querySelector('#barred')!)!;

      expect(hidden.visible, isFalse);
      expect(state.willValidate(hidden.key), isTrue);
      expect(state.valueMissing(hidden.key), isTrue);
      expect(state.willValidate(barred.key), isFalse);
      expect(state.valueMissing(barred.key), isTrue);
    });

    test(
      'picked files keep bytes and names, cancel preserves, reset clears',
      () async {
        const source =
            '<form><label for="file">Attachment</label><input id="file" type="file" name="upload" multiple accept=".txt, image/*" required></form>';
        final requests = <NativeHtmlFilePickerRequest>[];
        var call = 0;
        final state = NativeHtmlFileInputState.fromHtml(
          source,
          picker: (request) async {
            requests.add(request);
            call++;
            if (call == 1) {
              return [
                NativeHtmlFile(
                  name: r'C:\fakepath\notes one.txt',
                  mimeType: 'text/plain',
                  bytes: [0x61, 0x00, 0xff],
                ),
                NativeHtmlFile(
                  name: 'two.pdf',
                  mimeType: 'application/pdf',
                  bytes: [0x62],
                ),
              ];
            }
            return null;
          },
        );
        addTearDown(state.dispose);
        final root = html.parseFragment(state.annotateHtml(source));
        final input = root.querySelector('input')!;
        final descriptor = state.resolveControl(input)!;

        await state.pick(descriptor.key);
        expect(requests.single.accept, ['.txt', 'image/*']);
        expect(requests.single.multiple, isTrue);
        expect(state.filesFor(descriptor.key).map((file) => file.name), [
          'notes one.txt',
          'two.pdf',
        ]);
        expect(state.filesFor(descriptor.key).first.bytes, [0x61, 0x00, 0xff]);
        final mutableCopy = state.filesFor(descriptor.key).first.bytes;
        mutableCopy[0] = 0x7a;
        expect(state.filesFor(descriptor.key).first.bytes, [0x61, 0x00, 0xff]);
        expect(state.isRequiredSatisfied(descriptor.key), isTrue);

        await state.pick(descriptor.key);
        expect(state.filesFor(descriptor.key).map((file) => file.name), [
          'notes one.txt',
          'two.pdf',
        ]);
        expect(state.isRequiredSatisfied(descriptor.key), isTrue);

        state.resetElements([input]);
        expect(state.filesFor(descriptor.key), isEmpty);
        expect(state.isRequiredSatisfied(descriptor.key), isFalse);
      },
    );

    test(
      'single input keeps only first host result and accept is only a hint',
      () async {
        const source = '<input type="file" accept=".txt" required>';
        NativeHtmlFilePickerRequest? request;
        final state = NativeHtmlFileInputState.fromHtml(
          source,
          picker: (value) async {
            request = value;
            return [
              NativeHtmlFile(
                name: 'image.png',
                mimeType: 'image/png',
                bytes: [1],
              ),
              NativeHtmlFile(
                name: 'extra.txt',
                mimeType: 'text/plain',
                bytes: [2],
              ),
            ];
          },
        );
        addTearDown(state.dispose);
        final input = html
            .parseFragment(state.annotateHtml(source))
            .querySelector('input')!;
        final descriptor = state.resolveControl(input)!;

        await state.pick(descriptor.key);
        expect(request!.multiple, isFalse);
        expect(request!.accept, ['.txt']);
        expect(state.filesFor(descriptor.key).map((file) => file.name), [
          'image.png',
        ]);
      },
    );

    test('reset invalidates a pending picker result', () async {
      const source = '<form><input type="file" name="f" multiple></form>';
      final pending = Completer<List<NativeHtmlFile>?>();
      final state = NativeHtmlFileInputState.fromHtml(
        source,
        picker: (_) => pending.future,
      );
      addTearDown(state.dispose);
      final input = html
          .parseFragment(state.annotateHtml(source))
          .querySelector('input')!;
      final key = state.resolveControl(input)!.key;

      final selection = state.pick(key);
      expect(state.isPicking(key), isTrue);
      state.resetElements([input]);
      expect(state.isPicking(key), isFalse);
      pending.complete([
        NativeHtmlFile(name: 'late.txt', mimeType: 'text/plain', bytes: [7]),
      ]);
      await selection;
      expect(state.filesFor(key), isEmpty);
    });
  });

  testWidgets(
    'file input button opens picker and displays only safe filename',
    (tester) async {
      const source = '<input id="file" type="file" name="f">';
      final state = NativeHtmlFileInputState.fromHtml(
        source,
        picker: (_) async => [
          NativeHtmlFile(
            name: r'C:\fakepath\report.txt',
            mimeType: 'text/plain',
            bytes: [0x41],
          ),
        ],
      );
      addTearDown(state.dispose);
      final input = html
          .parseFragment(state.annotateHtml(source))
          .querySelector('input')!;
      final control = state.resolveControl(input)!;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NativeHtmlFileInputWidget(
              state: state,
              control: control,
              textStyle: const TextStyle(fontSize: 14, color: Colors.black),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(ValueKey('native-html-file-input-${control.key}')),
      );
      await tester.pumpAndSettle();

      expect(find.text('report.txt'), findsOneWidget);
      expect(find.textContaining('fakepath'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('multiple selections display a localized count, not paths', (
    tester,
  ) async {
    const source = '<input id="file" type="file" multiple>';
    final state = NativeHtmlFileInputState.fromHtml(
      source,
      picker: (_) async => [
        NativeHtmlFile(
          name: 'one résumé-台北.txt',
          mimeType: 'text/plain',
          bytes: [1],
        ),
        NativeHtmlFile(
          name: 'two + space.bin',
          mimeType: 'application/octet-stream',
          bytes: [2],
        ),
      ],
    );
    addTearDown(state.dispose);
    final input = html
        .parseFragment(state.annotateHtml(source))
        .querySelector('input')!;
    final control = state.resolveControl(input)!;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NativeHtmlFileInputWidget(
            state: state,
            control: control,
            textStyle: const TextStyle(fontSize: 14),
            strings: NativeHtmlFileInputStrings.forLocale(
              const Locale('zh', 'TW'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(
      find.byKey(ValueKey('native-html-file-input-${control.key}')),
    );
    await tester.pumpAndSettle();

    expect(find.text('選擇檔案'), findsOneWidget);
    expect(find.text('2 個檔案'), findsOneWidget);
    expect(find.text('one résumé-台北.txt'), findsNothing);
    expect(find.text('two + space.bin'), findsNothing);
  });

  testWidgets('disabled file input and disabled fieldset never open picker', (
    tester,
  ) async {
    const source =
        '<fieldset disabled><legend>Caption</legend><input id="blocked" type="file"></fieldset><input id="disabled" type="file" disabled>';
    var calls = 0;
    final state = NativeHtmlFileInputState.fromHtml(
      source,
      picker: (_) async {
        calls++;
        return const [];
      },
    );
    addTearDown(state.dispose);
    final root = html.parseFragment(state.annotateHtml(source));
    final blocked = state.resolveControl(root.querySelector('#blocked')!)!;
    final disabled = state.resolveControl(root.querySelector('#disabled')!)!;
    expect(blocked.disabled, isTrue);
    expect(disabled.disabled, isTrue);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              NativeHtmlFileInputWidget(
                state: state,
                control: blocked,
                textStyle: const TextStyle(fontSize: 14),
              ),
              NativeHtmlFileInputWidget(
                state: state,
                control: disabled,
                textStyle: const TextStyle(fontSize: 14),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(ValueKey('native-html-file-input-${blocked.key}')),
    );
    await tester.tap(
      find.byKey(ValueKey('native-html-file-input-${disabled.key}')),
    );
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(tester.takeException(), isNull);
  });
}
