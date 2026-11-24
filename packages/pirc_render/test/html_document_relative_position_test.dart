import 'package:flutter/widgets.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/document_relative_position.dart';
import 'package:pirc_render/src/html_document_box.dart';
import 'package:pirc_render/src/html_document_flex.dart';

NativeDocumentRelativePositionSpec _parse(
  Map<String, String> styles, {
  TextDirection direction = TextDirection.ltr,
}) => NativeDocumentRelativePositionSpec.parse(styles, direction: direction)!;

Widget _host(Widget child, {double width = 200, double? height = 100}) =>
    Directionality(
      textDirection: TextDirection.ltr,
      child: SizedBox.expand(
        child: Align(
          alignment: Alignment.topLeft,
          child: NativeDocumentContainingBlock(
            width: width,
            height: height,
            child: child,
          ),
        ),
      ),
    );

Rect _semanticsScreenRect(SemanticsNode node) {
  var rect = node.rect;
  SemanticsNode? current = node;
  while (current != null) {
    final transform = current.transform;
    if (transform != null) rect = MatrixUtils.transformRect(transform, rect);
    current = current.parent;
  }
  return rect;
}

void main() {
  group('NativeDocumentRelativePositionSpec', () {
    test('parses signed physical px and percentages', () {
      final spec = _parse({
        'position': 'relative',
        'top': '-7.5px',
        'left': '+10px',
        'right': '2%',
        'bottom': '1px',
      });

      expect(
        spec.resolve(
          containingWidth: 200,
          containingHeight: 80,
          direction: TextDirection.ltr,
        ),
        const Offset(10, -7.5),
      );
      expect(
        spec.resolve(
          containingWidth: 200,
          containingHeight: 80,
          direction: TextDirection.rtl,
        ),
        const Offset(-4, -7.5),
      );
    });

    test('expands inset shorthand before applying physical longhands', () {
      final spec = _parse({
        'position': 'relative',
        'inset': '1px 2px 3px 4px',
        'left': '-6px',
        'top': 'auto',
      });

      expect(spec.resolve(direction: TextDirection.ltr), const Offset(-6, -3));
      expect(spec.resolve(direction: TextDirection.rtl), const Offset(-2, -3));
    });

    test('unresolved vertical percentages behave as auto', () {
      final spec = _parse({
        'position': 'relative',
        'top': '50%',
        'bottom': '8px',
        'left': '10%',
      });

      expect(spec.resolve(containingWidth: 200), const Offset(20, -8));
      expect(spec.resolve(containingHeight: 40), const Offset(0, 20));
    });

    test(
      'common font/viewport insets require finite canonical pixel lengths',
      () {
        for (final unit in ['em', 'rem', 'vw', 'vh']) {
          final css = {'position': 'relative', 'top': '2$unit'};
          expect(NativeDocumentRelativePositionSpec.parse(css), isNull);
          final spec = NativeDocumentRelativePositionSpec.parse(
            css,
            computedLengths: {'top': '24px'},
          );
          expect(spec!.resolve(), const Offset(0, 24));
          for (final invalid in ['auto', '24%', 'Infinitypx', 'NaNpx']) {
            expect(
              NativeDocumentRelativePositionSpec.parse(
                css,
                computedLengths: {'top': invalid},
              ),
              isNull,
            );
          }
        }
      },
    );

    test(
      'mixed relative shorthand keeps winning physical sides and zero units',
      () {
        final spec = NativeDocumentRelativePositionSpec.parse(
          {
            'position': 'relative',
            'inset': '1em 2rem 3vh 4vw',
            'top': 'auto',
            'left': '25%',
          },
          computedLengths: {
            'top': 'auto',
            'right': '48px',
            'bottom': '30px',
            'left': '25%',
          },
        );
        expect(spec!.resolve(containingWidth: 200), const Offset(50, -30));
        final zero = NativeDocumentRelativePositionSpec.parse(
          {'position': 'relative', 'top': '0em'},
          computedLengths: {'top': 'auto'},
        );
        expect(zero!.isNoOp, isTrue);
      },
    );

    test('retains harmless zero units, including logical zero insets', () {
      final spec = _parse({
        'position': 'relative',
        'inset': '0rem 0vw 0% 0.0em',
        'inset-inline-start': '0%',
      });

      expect(spec.isNoOp, isTrue);
      expect(spec.resolve(), Offset.zero);
    });

    for (final styles in [
      <String, String>{'position': 'static', 'top': '10px'},
      <String, String>{'position': 'absolute', 'top': '10px'},
      <String, String>{'position': 'fixed', 'left': '10px'},
      <String, String>{'position': 'sticky', 'bottom': '10px'},
      <String, String>{'position': 'relative', 'top': '1em'},
      <String, String>{'position': 'relative', 'left': '1vh'},
      <String, String>{'position': 'relative', 'inset-inline-start': '1px'},
      <String, String>{'position': 'relative', 'top': 'calc(2px + 1px)'},
      <String, String>{'position': 'relative', 'inset': '1px 2px 3px 4px 5px'},
    ]) {
      test('rejects unsupported declaration map: $styles', () {
        expect(NativeDocumentRelativePositionSpec.parse(styles), isNull);
      });
    }
  });

  testWidgets('relative percentages move paint but preserve flow size', (
    tester,
  ) async {
    const targetKey = ValueKey('relative-position-target');
    const siblingKey = ValueKey('relative-position-sibling');
    final spec = _parse({'position': 'relative', 'left': '10%', 'top': '25%'});

    await tester.pumpWidget(
      _host(
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            NativeDocumentRelativePosition(
              spec: spec,
              direction: TextDirection.ltr,
              child: const SizedBox(key: targetKey, width: 20, height: 10),
            ),
            const SizedBox(key: siblingKey, width: 20, height: 10),
          ],
        ),
      ),
    );

    expect(tester.getTopLeft(find.byKey(targetKey)), const Offset(20, 25));
    expect(tester.getTopLeft(find.byKey(siblingKey)), const Offset(0, 10));
    expect(
      tester.getSize(find.byType(NativeDocumentRelativePosition)),
      const Size(20, 10),
    );
    final relative = tester.renderObject<RenderBox>(
      find.byType(NativeDocumentRelativePosition),
    );
    expect(relative.paintBounds, const Rect.fromLTWH(0, 0, 40, 35));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'percentage inset uses the parent width across tight child and resize updates',
    (tester) async {
      const targetKey = ValueKey('relative-position-tight-child');

      Widget tree({required double width, required String left}) {
        return _host(
          NativeDocumentRelativePosition(
            spec: _parse({'position': 'relative', 'left': left}),
            direction: TextDirection.ltr,
            child: const SizedBox(key: targetKey, width: 30, height: 10),
          ),
          width: width,
        );
      }

      await tester.pumpWidget(tree(width: 400, left: '10%'));
      expect(tester.getTopLeft(find.byKey(targetKey)).dx, 40);

      // Updating the inset keeps the 30px child tight while resolving the
      // percentage against its 400px containing block.
      await tester.pumpWidget(tree(width: 400, left: '20%'));
      expect(tester.getTopLeft(find.byKey(targetKey)).dx, 80);

      // A subsequent containing-block resize must refresh the used value.
      await tester.pumpWidget(tree(width: 600, left: '20%'));
      expect(tester.getTopLeft(find.byKey(targetKey)).dx, 120);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('percentage top uses only a definite containing-block height', (
    tester,
  ) async {
    const targetKey = ValueKey('relative-position-auto-height');
    final spec = _parse({
      'position': 'relative',
      'top': '50%',
      'bottom': '8px',
    });

    await tester.pumpWidget(
      _host(
        NativeDocumentBox(
          width: const NativeFlexLength.pixels(200),
          child: NativeDocumentRelativePosition(
            spec: spec,
            direction: TextDirection.ltr,
            child: const SizedBox(key: targetKey, width: 20, height: 10),
          ),
        ),
      ),
    );

    expect(tester.getTopLeft(find.byKey(targetKey)).dy, -8);
    expect(tester.takeException(), isNull);
  });

  testWidgets('relative hit testing follows the translated child', (
    tester,
  ) async {
    var taps = 0;
    final spec = _parse({
      'position': 'relative',
      'left': '10px',
      'top': '10px',
    });

    await tester.pumpWidget(
      _host(
        Stack(
          alignment: Alignment.topLeft,
          children: [
            const SizedBox(width: 50, height: 30),
            NativeDocumentRelativePosition(
              spec: spec,
              direction: TextDirection.ltr,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => taps++,
                child: const SizedBox(width: 20, height: 10),
              ),
            ),
          ],
        ),
        width: 50,
        height: 30,
      ),
    );

    await tester.tapAt(const Offset(25, 15));
    expect(taps, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('relative offset and semantics use the same paint transform', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const semanticKey = ValueKey('relative-position-semantics');
    final semantics = tester.ensureSemantics();
    try {
      final spec = _parse({
        'position': 'relative',
        'left': '12px',
        'top': '7px',
      });

      await tester.pumpWidget(
        _host(
          Stack(
            alignment: Alignment.topLeft,
            children: [
              const SizedBox(width: 60, height: 40),
              NativeDocumentRelativePosition(
                spec: spec,
                direction: TextDirection.ltr,
                child: Semantics(
                  key: semanticKey,
                  container: true,
                  label: 'relative target',
                  child: const SizedBox(width: 20, height: 10),
                ),
              ),
            ],
          ),
          width: 60,
          height: 40,
        ),
      );

      final semanticsNode = tester.getSemantics(find.byKey(semanticKey));
      expect(
        _semanticsScreenRect(semanticsNode),
        const Rect.fromLTWH(12, 7, 20, 10),
      );
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('relative wrapper preserves intrinsic size and flow baseline', (
    tester,
  ) async {
    const flowTextKey = ValueKey('relative-position-flow-text');
    const relativeTextKey = ValueKey('relative-position-baseline-text');
    final spec = _parse({'position': 'relative', 'top': '3px', 'left': '5px'});
    await tester.pumpWidget(
      _host(
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            const Text('baseline', key: flowTextKey),
            NativeDocumentRelativePosition(
              spec: spec,
              direction: TextDirection.ltr,
              child: const Text('baseline', key: relativeTextKey),
            ),
          ],
        ),
      ),
    );

    final relative = tester.renderObject<RenderBox>(
      find.byType(NativeDocumentRelativePosition),
    );
    final paragraph = tester.renderObject<RenderBox>(
      find.byKey(relativeTextKey),
    );
    expect(
      relative.getMinIntrinsicWidth(100),
      paragraph.getMinIntrinsicWidth(100),
    );
    expect(
      relative.getMaxIntrinsicHeight(100),
      paragraph.getMaxIntrinsicHeight(100),
    );
    expect(
      tester.getTopLeft(find.byKey(relativeTextKey)).dy,
      tester.getTopLeft(find.byKey(flowTextKey)).dy + 3,
    );
  });
}
