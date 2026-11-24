import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/html_document_grid.dart';

void main() {
  testWidgets('native grid sizes fraction tracks and spans by row height', (
    t,
  ) async {
    await t.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 300,
              child: NativeDocumentGrid(
                fractions: [1, 2],
                spans: [1, 1, 2],
                columnGap: 12,
                rowGap: 9,
                children: [
                  SizedBox(key: ValueKey('a'), height: 20),
                  SizedBox(key: ValueKey('b'), height: 40),
                  SizedBox(key: ValueKey('c'), height: 30),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    final a = t.getRect(find.byKey(const ValueKey('a')));
    final b = t.getRect(find.byKey(const ValueKey('b')));
    final c = t.getRect(find.byKey(const ValueKey('c')));
    expect(a.width, 96);
    expect(b.width, 192);
    expect(b.left - a.left, 108);
    expect(a.height, 40);
    expect(c.width, 300);
    expect(c.top - a.top, 49);
    expect(t.takeException(), isNull);
  });

  testWidgets(
    'native flex row stretches to natural height in a scrolling page',
    (t) async {
      await t.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: SizedBox(
                width: 300,
                child: NativeDocumentFlexRow(
                  gap: 10,
                  children: [
                    SizedBox(key: ValueKey('a'), width: 80, height: 20),
                    SizedBox(key: ValueKey('b'), width: 60, height: 40),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      final a = t.getRect(find.byKey(const ValueKey('a')));
      final b = t.getRect(find.byKey(const ValueKey('b')));
      expect(a.height, 40);
      expect(b.height, 40);
      expect(b.left - a.left, 90);
      expect(t.takeException(), isNull);
    },
  );
}
