import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:pirc_render/src/html_select.dart';

class _SelectBinding {
  const _SelectBinding(this.state, this.control, this.id);

  final NativeHtmlSelectState state;
  final NativeHtmlSelectDescriptor control;
  final String id;
}

List<_SelectBinding> _bindings(String source) {
  final state = NativeHtmlSelectState.fromHtml(source);
  final fragment = html.parseFragment(state.annotateHtml(source));
  return fragment
      .querySelectorAll('select')
      .map(
        (element) =>
            _SelectBinding(state, state.resolveControl(element)!, element.id),
      )
      .toList(growable: false);
}

_SelectBinding _binding(String source, String id) =>
    _bindings(source).firstWhere((binding) => binding.id == id);

Widget _focusPage(Iterable<_SelectBinding> bindings) => MaterialApp(
  home: Scaffold(
    body: Column(
      children: [
        for (final binding in bindings)
          Focus(
            focusNode: binding.state.focusNodeFor(binding.control.key),
            child: const SizedBox(width: 100, height: 24),
          ),
      ],
    ),
  ),
);

void main() {
  testWidgets('focus lifecycle and click order use script IDs', (tester) async {
    const source = '''
      <select id="first" data-pirc-script-id="select-one"><option>A</option></select>
      <select id="second" data-pirc-script-id="select-two"><option>B</option></select>
    ''';
    final bindings = _bindings(source);
    final first = bindings[0];
    final second = bindings[1];
    final events = <String>[];
    final details = <Map<String, dynamic>>[];
    void capture(String key, String type, Map<String, dynamic> data) {
      events.add('$key:$type');
      details.add({'key': key, 'type': type, ...data});
    }

    first.state.onDetailedUserEvent = capture;
    second.state.onDetailedUserEvent = capture;

    await tester.pumpWidget(_focusPage([first, second]));
    first.state.focusNodeFor(first.control.key).requestFocus();
    first.state.recordUserClick(first.control.key);
    await tester.pump();
    expect(events, [
      '${first.control.key}:focus',
      '${first.control.key}:focusin',
      '${first.control.key}:click',
    ]);
    expect(details[0]['relatedTarget'], isNull);
    expect(details[2]['type'], 'click');

    first.state.setPopupOpen(first.control.key, true);
    first.state.focusNodeFor(first.control.key).unfocus();
    await tester.pump();
    expect(events, [
      '${first.control.key}:focus',
      '${first.control.key}:focusin',
      '${first.control.key}:click',
    ]);
    first.state.focusNodeFor(first.control.key).requestFocus();
    await tester.pump();
    first.state.setPopupOpen(first.control.key, false);
    await tester.pump();
    expect(events, [
      '${first.control.key}:focus',
      '${first.control.key}:focusin',
      '${first.control.key}:click',
    ]);

    second.state.focusNodeFor(second.control.key).requestFocus();
    await tester.pump();
    expect(events.sublist(3), [
      '${first.control.key}:blur',
      '${first.control.key}:focusout',
      '${second.control.key}:focus',
      '${second.control.key}:focusin',
    ]);
    expect(details[3]['relatedTarget'], 'select-two');
    expect(details[5]['relatedTarget'], 'select-one');

    second.state.focusNodeFor(second.control.key).unfocus();
    await tester.pump();
    expect(events.sublist(7), [
      '${second.control.key}:blur',
      '${second.control.key}:focusout',
    ]);
    expect(details[7]['relatedTarget'], isNull);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    first.state.dispose();
  });

  test('multiple selection gestures emit one input/change pair', () {
    const source = '''
      <select id="choices" multiple data-pirc-script-id="choices">
        <option>A</option><option>B</option><option>C</option>
      </select>
    ''';
    final binding = _binding(source, 'choices');
    final legacy = <String>[];
    final detailed = <String>[];
    binding.state.onUserEvent = (_, type) => legacy.add(type);
    binding.state.onDetailedUserEvent = (_, type, data) {
      detailed.add('$type:${data.keys.toList()}');
    };

    expect(binding.state.selectIndices(binding.control.key, [0, 1]), isTrue);
    expect(binding.state.selectedIndices(binding.control.key), [0, 1]);
    expect(legacy, ['input', 'change']);
    expect(detailed, ['input:[]', 'change:[]']);

    expect(binding.state.selectIndices(binding.control.key, [1, 2]), isTrue);
    expect(binding.state.selectedIndices(binding.control.key), [1, 2]);
    expect(legacy, ['input', 'change', 'input', 'change']);
    expect(detailed, ['input:[]', 'change:[]', 'input:[]', 'change:[]']);
    expect(binding.state.selectIndices(binding.control.key, [1, 2]), isFalse);
    expect(legacy, ['input', 'change', 'input', 'change']);

    binding.state.dispose();
  });

  testWidgets(
    'adoption preserves focus identity without repeating focus events',
    (tester) async {
      const beforeSource = '''
      <select id="choice" data-pirc-script-id="stable"><option>A</option>
        <option>B</option></select>
    ''';
      const afterSource = '''
      <select id="choice" data-pirc-script-id="stable"><option>A</option>
        <option selected>B</option></select>
    ''';
      final before = _binding(beforeSource, 'choice');
      final after = _binding(afterSource, 'choice');
      final events = <String>[];
      before.state.onDetailedUserEvent = (_, type, _) => events.add(type);
      after.state.onDetailedUserEvent = (_, type, _) => events.add(type);

      await tester.pumpWidget(_focusPage([before]));
      final originalFocus = before.state.focusNodeFor(before.control.key);
      final originalWidgetKey = before.state.widgetKeyFor(before.control.key);
      originalFocus.requestFocus();
      await tester.pump();
      expect(events, ['focus', 'focusin']);
      before.state.setPopupOpen(before.control.key, true);
      originalFocus.unfocus();
      await tester.pump();
      expect(events, ['focus', 'focusin']);

      after.state.adoptInteractionState(before.state);
      before.state.dispose();
      expect(
        identical(after.state.focusNodeFor(after.control.key), originalFocus),
        isTrue,
      );
      expect(
        identical(
          after.state.widgetKeyFor(after.control.key),
          originalWidgetKey,
        ),
        isTrue,
      );
      expect(after.state.selectedIndices(after.control.key), [1]);
      await tester.pumpWidget(_focusPage([after]));
      await tester.pump();
      after.state.focusNodeFor(after.control.key).requestFocus();
      await tester.pump();
      after.state.setPopupOpen(after.control.key, false);
      await tester.pump();
      expect(events, ['focus', 'focusin']);

      after.state.focusNodeFor(after.control.key).unfocus();
      await tester.pump();
      expect(events, ['focus', 'focusin', 'blur', 'focusout']);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox());
      after.state.dispose();
    },
  );

  test(
    'history, reset, adoption, and pending click disposal stay silent',
    () async {
      const source = '''
      <select id="choices" multiple data-pirc-script-id="stable">
        <option selected>A</option><option>B</option><option>C</option>
      </select>
    ''';
      final before = _binding(source, 'choices');
      final events = <String>[];
      before.state.onUserEvent = (_, type) => events.add('legacy:$type');
      before.state.onDetailedUserEvent = (_, type, _) =>
          events.add('detail:$type');

      expect(before.state.selectIndices(before.control.key, [1, 2]), isTrue);
      expect(events, [
        'legacy:input',
        'detail:input',
        'legacy:change',
        'detail:change',
      ]);
      before.state.restoreHistorySelectedness(before.control.key, const {
        0: true,
        1: false,
        2: false,
      });
      expect(before.state.selectedIndices(before.control.key), [0]);
      before.state.resetDefaults([before.control.key]);
      expect(before.state.selectedIndices(before.control.key), [0]);
      expect(events, [
        'legacy:input',
        'detail:input',
        'legacy:change',
        'detail:change',
      ]);

      final after = _binding(source, 'choices');
      after.state.onDetailedUserEvent = (_, type, _) =>
          events.add('detail:$type');
      after.state.adoptInteractionState(before.state);
      before.state.dispose();
      expect(after.state.selectedIndices(after.control.key), [0]);
      expect(events, [
        'legacy:input',
        'detail:input',
        'legacy:change',
        'detail:change',
      ]);

      after.state.recordUserClick(after.control.key);
      after.state.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(events, [
        'legacy:input',
        'detail:input',
        'legacy:change',
        'detail:change',
      ]);
    },
  );
}
