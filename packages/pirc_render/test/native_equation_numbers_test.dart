import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/native_equation_numbers.dart';

Widget slot(String id, int count) => NativeEquationNumberSlot(
  key: ValueKey(id),
  count: count,
  builder: (first) => Text('$id:$first'),
);

void main() {
  testWidgets('document numbers follow tree order after keyed reorder/remove', (
    t,
  ) async {
    Future<void> show(List<Widget> children) async {
      await t.pumpWidget(
        MaterialApp(
          home: NativeEquationNumberDocument(child: Column(children: children)),
        ),
      );
      await t.pumpAndSettle();
    }

    await show([slot('a', 2), slot('manual', 0), slot('b', 1)]);
    expect(find.text('a:1'), findsOneWidget);
    expect(find.text('manual:3'), findsOneWidget);
    expect(find.text('b:3'), findsOneWidget);
    await show([slot('b', 1), slot('a', 2)]);
    expect(find.text('b:1'), findsOneWidget);
    expect(find.text('a:2'), findsOneWidget);
    await show([slot('a', 1)]);
    expect(find.text('a:1'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets(
    'nested documents reset and offstage retained slots do not count',
    (t) async {
      final hidden = ValueNotifier(false);
      addTearDown(hidden.dispose);
      final retained = slot('hidden', 3);
      final later = slot('later', 1);
      await t.pumpWidget(
        MaterialApp(
          home: NativeEquationNumberDocument(
            child: Column(
              children: [
                ValueListenableBuilder(
                  valueListenable: hidden,
                  builder: (_, value, _) =>
                      Offstage(offstage: value, child: retained),
                ),
                NativeEquationNumberDocument(child: slot('inner', 4)),
                later,
              ],
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('later:4'), findsOneWidget);
      expect(find.text('inner:1'), findsOneWidget);
      hidden.value = true;
      await t.pumpAndSettle();
      expect(find.text('later:1'), findsOneWidget);
      hidden.value = false;
      await t.pumpAndSettle();
      expect(find.text('later:4'), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );
}
