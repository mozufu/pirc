import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:pirc_render/src/html_file.dart';

NativeHtmlFile _file(String name, List<int> bytes) =>
    NativeHtmlFile(name: name, mimeType: 'text/plain', bytes: bytes);

NativeHtmlFileInputDescriptor _control(
  NativeHtmlFileInputState state,
  String source,
) => state.resolveControl(
  html.parseFragment(state.annotateHtml(source)).querySelector('input')!,
)!;

void main() {
  test(
    'same script identity adopts selected files, widget resources, and picker result',
    () async {
      const source =
          '<input type="file" multiple data-pirc-script-id="upload" '
          'data-pirc-file-reset-version="0">';
      final pending = Completer<List<NativeHtmlFile>?>();
      var calls = 0;
      final previous = NativeHtmlFileInputState.fromHtml(
        source,
        picker: (_) async {
          calls++;
          if (calls == 1) {
            return [
              _file('first.txt', [1]),
            ];
          }
          return pending.future;
        },
      );
      var previousDisposed = false;
      addTearDown(() {
        if (!previousDisposed) previous.dispose();
      });
      final previousControl = _control(previous, source);
      await previous.pick(previousControl.key);
      expect(previous.filesFor(previousControl.key).single.name, 'first.txt');

      final pickerResult = previous.pick(previousControl.key);
      expect(previous.isPicking(previousControl.key), isTrue);
      final oldFocus = previous.focusNodeFor(previousControl.key);
      final oldWidgetKey = previous.widgetKeyFor(previousControl.key);

      final next = NativeHtmlFileInputState.fromHtml(
        source,
        picker: (_) async => null,
      );
      addTearDown(next.dispose);
      final nextControl = _control(next, source);
      final events = <String>[];
      next.onUserEvent = (key, type) =>
          events.add('$type:${next.filesFor(key).length}');

      next.adoptInteractionState(previous);
      expect(next.filesFor(nextControl.key).single.name, 'first.txt');
      expect(next.isPicking(nextControl.key), isTrue);
      expect(next.focusNodeFor(nextControl.key), same(oldFocus));
      expect(next.widgetKeyFor(nextControl.key), same(oldWidgetKey));

      previous.dispose();
      previousDisposed = true;
      pending.complete([
        _file('second.txt', [2]),
      ]);
      await pickerResult;

      expect(next.filesFor(nextControl.key).single.name, 'second.txt');
      expect(events, ['input:1', 'change:1']);
    },
  );

  test(
    'script reset version clears files and invalidates a pending picker',
    () async {
      const beforeReset =
          '<input type="file" multiple data-pirc-script-id="upload" '
          'data-pirc-file-reset-version="0">';
      const afterReset =
          '<input type="file" multiple data-pirc-script-id="upload" '
          'data-pirc-file-reset-version="1">';
      final pending = Completer<List<NativeHtmlFile>?>();
      var calls = 0;
      final previous = NativeHtmlFileInputState.fromHtml(
        beforeReset,
        picker: (_) async {
          calls++;
          if (calls == 1) {
            return [
              _file('selected.txt', [1]),
            ];
          }
          return pending.future;
        },
      );
      var previousDisposed = false;
      addTearDown(() {
        if (!previousDisposed) previous.dispose();
      });
      final previousControl = _control(previous, beforeReset);
      await previous.pick(previousControl.key);
      final pickerResult = previous.pick(previousControl.key);
      expect(previous.isPicking(previousControl.key), isTrue);

      final next = NativeHtmlFileInputState.fromHtml(
        afterReset,
        picker: (_) async => null,
      );
      addTearDown(next.dispose);
      final nextControl = _control(next, afterReset);
      final events = <String>[];
      next.onUserEvent = (key, type) => events.add(type);
      next.adoptInteractionState(previous);

      expect(next.filesFor(nextControl.key), isEmpty);
      expect(next.isPicking(nextControl.key), isFalse);
      previous.dispose();
      previousDisposed = true;
      pending.complete([
        _file('late.txt', [9]),
      ]);
      await pickerResult;

      expect(next.filesFor(nextControl.key), isEmpty);
      expect(events, isEmpty);
    },
  );

  test(
    'only successful changed selections and picker clears emit input/change',
    () async {
      const source =
          '<input type="file" multiple data-pirc-script-id="upload">';
      final results = <List<NativeHtmlFile>?>[
        null,
        [
          _file('one.txt', [1]),
        ],
        [],
        [
          _file('one.txt', [1]),
        ],
      ];
      final state = NativeHtmlFileInputState.fromHtml(
        source,
        picker: (_) async => results.removeAt(0),
      );
      addTearDown(state.dispose);
      final control = _control(state, source);
      final events = <String>[];
      state.onUserEvent = (key, type) =>
          events.add('$type:${state.filesFor(key).length}');

      await state.pick(control.key); // Cancel.
      expect(events, isEmpty);
      await state.pick(control.key); // Select.
      expect(events, ['input:1', 'change:1']);
      await state.pick(control.key); // Clear in the picker.
      expect(events, ['input:1', 'change:1', 'input:0', 'change:0']);
      await state.pick(control.key); // Select again.
      expect(events, [
        'input:1',
        'change:1',
        'input:0',
        'change:0',
        'input:1',
        'change:1',
      ]);

      final input = html
          .parseFragment(state.annotateHtml(source))
          .querySelector('input')!;
      state.resetElements([input]);
      expect(state.filesFor(control.key), isEmpty);
      expect(events, hasLength(6));
    },
  );
}
