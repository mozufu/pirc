import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/document_transform.dart';

void main() {
  test(
    '2D function order and default CSS border-box origin remain distinct',
    () {
      final first = NativeDocumentTransformSpec.parse(
        'translate(10px, 20px) scale(2)',
      )!.resolve(const Size(80, 40));
      final second = NativeDocumentTransformSpec.parse(
        'scale(2) translate(10px, 20px)',
      )!.resolve(const Size(80, 40));
      expect(
        MatrixUtils.transformPoint(first, Offset.zero),
        const Offset(-30, 0),
      );
      expect(
        MatrixUtils.transformPoint(second, Offset.zero),
        const Offset(-20, 20),
      );
    },
  );
  test('unsupported/nonfinite transform syntax stays explicit', () {
    for (final value in [
      'none',
      'scale(NaN)',
      'scale(Infinity)',
      'matrix(1,2,3)',
      'translateZ(1px)',
      'perspective(10px)',
      'scale(1 2)',
      'translate(calc(1px + 2px))',
    ]) {
      expect(NativeDocumentTransformSpec.parse(value), isNull, reason: value);
    }
    expect(
      NativeDocumentTransformSpec.parse('scale(2)', origin: '0 0 10px'),
      isNull,
    );
  });
  testWidgets(
    'origin uses the owned border box and transformed content receives taps without changing flow size',
    (tester) async {
      const box = ValueKey('border'), flow = ValueKey('flow');
      var taps = 0;
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              key: flow,
              width: 200,
              height: 100,
              child: NativeDocumentTransform(
                spec: NativeDocumentTransformSpec.parse('scale(2)')!,
                viewport: const Size(800, 600),
                fontSize: 16,
                boxGeometry: (_) => (
                  surface: key.currentContext!.findRenderObject() as RenderBox,
                  size: const Size(80, 40),
                ),
                child: Align(
                  alignment: Alignment.topLeft,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 10, top: 20),
                    child: SizedBox(
                      key: key,
                      width: 80,
                      height: 40,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => taps++,
                        child: const ColoredBox(key: box, color: Colors.blue),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byKey(flow)), const Size(200, 100));
      expect(
        tester.getRect(find.byKey(box)),
        const Rect.fromLTWH(-30, 0, 160, 80),
      );
      await tester.tapAt(const Offset(120, 40));
      expect(taps, 1);
      expect(tester.takeException(), isNull);
    },
  );
}
