import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/native_markdown.dart';

import '../tool/parity/capture_html_interactions_test.dart' as harness;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final cases = harness.interactionRows(harness.interactionFixture['cases']);
  for (final item in cases) {
    for (final width
        in (harness.interactionFixture['widths'] as List).cast<num>()) {
      for (final brightness in Brightness.values) {
        testWidgets(
          'native HTML interaction parity ${item['id']} $width ${brightness.name}',
          (tester) async {
            final semantics = tester.ensureSemantics();
            try {
              await harness.runNativeInteractionScenario(
                tester,
                item: item,
                width: width.toInt(),
                brightness: brightness,
                onPhase: (session, phase) async {
                  final expected = harness.interactionWebPhase(
                    width.toInt(),
                    brightness,
                    item['id'] as String,
                    phase,
                  );
                  _compareControls(
                    tester,
                    session,
                    item['id'] as String,
                    harness.interactionRows(expected['controls']),
                    width: width.toInt(),
                    brightness: brightness,
                    phase: phase,
                  );
                  _compareDetails(
                    tester,
                    harness.interactionRows(expected['details']),
                    width: width.toInt(),
                    brightness: brightness,
                    phase: phase,
                  );
                  expect(
                    tester.takeException(),
                    isNull,
                    reason:
                        '${item['id']} $width ${brightness.name} after $phase',
                  );
                },
              );
            } finally {
              // Dispose semantics while the test binding is still in scope.
              await tester.pumpWidget(const SizedBox.shrink());
              semantics.dispose();
              tester.view.reset();
            }
          },
        );
      }
    }
  }
}

void _compareControls(
  WidgetTester tester,
  harness.NativeInteractionSession session,
  String caseId,
  List<Map<String, dynamic>> expected, {
  required int width,
  required Brightness brightness,
  required String phase,
}) {
  final reason = '$caseId $width ${brightness.name} after $phase';
  if (caseId == 'gfm-task-checkboxes') {
    final tasks = tester
        .widgetList<NativeTaskCheckbox>(find.byType(NativeTaskCheckbox))
        .toList();
    expect(tasks, hasLength(expected.length), reason: reason);
    for (var index = 0; index < expected.length; index++) {
      final reference = harness.interactionObject(expected[index]['state']);
      expect(
        tasks[index].checked,
        reference['checked'],
        reason: '$reason GFM checkbox $index checked',
      );
    }
    return;
  }

  final actual = session.controls();
  expect(actual, hasLength(expected.length), reason: '$reason control count');
  for (final reference in expected) {
    final id = reference['id'] as String?;
    expect(id, isNotNull, reason: '$reason raw HTML control has no id');
    final control = session.controlsForId(id!).single;
    final expectedState = harness.interactionObject(reference['state']);
    final checked = expectedState['checked'] as bool;
    final disabled = expectedState['disabled'] as bool;
    final controlReason = '$reason #$id';

    expect(control.checked, checked, reason: '$controlReason checked state');
    expect(
      control.widget.control.disabled,
      disabled,
      reason: '$controlReason disabled state',
    );
    expect(
      control.element.attributes.containsKey('disabled'),
      disabled,
      reason: '$controlReason sanitized disabled attribute',
    );

    final semantics = tester
        .getSemantics(
          find.byKey(
            ValueKey('native-html-control-${control.widget.control.key}'),
          ),
        )
        .getSemanticsData();
    expect(
      semantics.flagsCollection.isChecked,
      checked ? ui.CheckedState.isTrue : ui.CheckedState.isFalse,
      reason: '$controlReason semantics checked state',
    );
    expect(
      semantics.flagsCollection.isEnabled,
      disabled ? ui.Tristate.isFalse : ui.Tristate.isTrue,
      reason: '$controlReason semantics enabled state',
    );

    expect(
      semantics.hint,
      reference['accessibleDescription'],
      reason: '$controlReason accessible description',
    );

    final accessibleName = reference['accessibleName'] as String?;
    if (accessibleName != null) {
      expect(
        control.widget.control.label,
        accessibleName,
        reason: '$controlReason accessible name',
      );
      expect(
        semantics.label,
        accessibleName,
        reason: '$controlReason semantics label',
      );
    }
  }
}

void _compareDetails(
  WidgetTester tester,
  List<Map<String, dynamic>> expected, {
  required int width,
  required Brightness brightness,
  required String phase,
}) {
  for (final detail in expected) {
    final id = detail['id'] as String?;
    final label =
        harness.interactionObject(detail['summary'])['text'] as String;
    final summary = harness.interactionRichText(label, skipOffstage: false);
    final rendered = _paintedOutsideOffstage(summary);
    final reason =
        'details ${id ?? label} $width ${brightness.name} after $phase';

    expect(summary, findsOneWidget, reason: '$reason summary exists');
    expect(
      rendered,
      harness.interactionObject(detail['summary'])['rendered'],
      reason: '$reason summary rendered state',
    );

    if (rendered) {
      final semantics = tester.getSemantics(summary).getSemanticsData();
      final isOpen = detail['open'] as bool;
      expect(
        semantics.flagsCollection.isExpanded,
        isOpen ? ui.Tristate.isTrue : ui.Tristate.isFalse,
        reason: '$reason expanded semantics',
      );
      expect(
        semantics.hasAction(SemanticsAction.tap),
        isTrue,
        reason: '$reason summary activation semantics',
      );
    }

    for (final child in harness.interactionRows(detail['content'])) {
      if (child['tag'] != 'p') continue;
      final text = child['text'] as String;
      final body = harness.interactionRichText(text, skipOffstage: false);
      expect(body, findsOneWidget, reason: '$reason body text exists: $text');
      expect(
        _paintedOutsideOffstage(body),
        child['rendered'],
        reason: '$reason body rendered: $text',
      );
    }
  }
}

bool _paintedOutsideOffstage(Finder finder) {
  if (finder.evaluate().isEmpty) return false;
  var offstage = false;
  finder.evaluate().first.visitAncestorElements((ancestor) {
    final widget = ancestor.widget;
    if (widget is Offstage && widget.offstage) {
      offstage = true;
      return false;
    }
    return true;
  });
  return !offstage;
}
