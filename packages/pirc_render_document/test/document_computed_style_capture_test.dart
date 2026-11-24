import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render_document/src/document_computed_styles.dart';
import 'package:pirc_render/src/document_layout.dart';
import 'package:pirc_render/src/html_document_box.dart';
import 'package:pirc_render/src/html_document_flex.dart';

NativeDocumentComputedStyleSpec _spec({
  Map<String, String> values = const {
    'display': 'block',
    'position': 'static',
    'box-sizing': 'content-box',
  },
  Map<String, String> lengths = const {},
  bool isReplaced = false,
}) => NativeDocumentComputedStyleSpec(
  values: values,
  lengths: lengths,
  fontSize: 16,
  rootFontSize: 16,
  isReplaced: isReplaced,
);

void main() {
  testWidgets('computed dimensions use native fractional box edges', (
    tester,
  ) async {
    final controller = NativeDocumentLayoutController();
    addTearDown(controller.dispose);
    final owner = Object();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: NativeDocumentLayoutRoot(
            controller: controller,
            revision: 1,
            knownIds: const {'box'},
            computedStyles: {
              'box': _spec(
                lengths: {
                  'width': '999px',
                  'height': '999px',
                  'margin-left': '10%',
                  'padding-top': '5%',
                },
              ),
            },
            child: NativeDocumentContainingBlock(
              width: 200,
              height: 100,
              child: NativeDocumentLayoutElement(
                controller: controller,
                revision: 1,
                id: 'box',
                boxSurface: (box) =>
                    nativeDocumentBoxSurface(box, owner: owner),
                child: NativeDocumentBox(
                  geometryOwner: owner,
                  width: const NativeFlexLength.pixels(100),
                  height: const NativeFlexLength.pixels(40),
                  lengthsAreContentBox: true,
                  horizontalEdges: 5.5,
                  verticalEdges: 7.25,
                  child: const SizedBox(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final packet = controller.capture(
      revision: 1,
      generation: 1,
      viewport: const Size(400, 300),
    )!;
    final box = (packet['boxes'] as List).single as Map;
    expect(box['width'], 105.5);
    expect(box['height'], 47.25);
    final styles = box['computedStyle'] as Map;
    expect(styles['width'], '100px');
    expect(styles['height'], '40px');
    expect(styles['margin-left'], '20px');
    expect(styles['padding-top'], '10px');
  });

  testWidgets('inline replaced sizes use the measured box and parent basis', (
    tester,
  ) async {
    final controller = NativeDocumentLayoutController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      Align(
        alignment: Alignment.topLeft,
        child: NativeDocumentLayoutRoot(
          controller: controller,
          revision: 1,
          knownIds: const {'image', 'missing'},
          computedStyles: {
            'image': _spec(
              isReplaced: true,
              values: {
                'display': 'inline',
                'box-sizing': 'content-box',
                for (final side in ['top', 'right', 'bottom', 'left'])
                  'border-$side-width': '0px',
              },
              lengths: {
                'width': '999px',
                'height': '999px',
                for (final side in ['top', 'right', 'bottom', 'left'])
                  'padding-$side': '5%',
                'margin-left': '10%',
              },
            ),
            'missing': _spec(
              isReplaced: true,
              values: {'display': 'inline'},
              lengths: {'width': '900px', 'height': '999px'},
            ),
          },
          child: NativeDocumentContainingBlock(
            width: 200,
            height: 100,
            child: Align(
              alignment: Alignment.topLeft,
              child: NativeDocumentLayoutElement(
                controller: controller,
                revision: 1,
                id: 'image',
                child: const SizedBox(width: 100, height: 50),
              ),
            ),
          ),
        ),
      ),
    );
    final packet = controller.capture(
      revision: 1,
      generation: 1,
      viewport: const Size(400, 300),
    )!;
    final boxes = {
      for (final raw in packet['boxes'] as List) (raw as Map)['id']: raw,
    };
    final styles = boxes['image']!['computedStyle'] as Map;
    expect(styles['width'], '80px');
    expect(styles['height'], '30px');
    expect(styles['padding-top'], '10px');
    expect(styles['margin-left'], '20px');
    expect(boxes['missing']!['kind'], 'unsupported');
    expect(boxes['missing']!['computedStyle'], isNot(contains('width')));
    expect(boxes['missing']!['computedStyle'], isNot(contains('height')));
  });

  testWidgets(
    'hidden and unmeasured nodes retain computable styles without fake dimensions',
    (tester) async {
      final controller = NativeDocumentLayoutController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        NativeDocumentLayoutRoot(
          controller: controller,
          revision: 1,
          knownIds: const {'hidden', 'unmeasured', 'blocked'},
          noBoxIds: const {'hidden', 'blocked'},
          computedStyles: {
            'blocked': NativeDocumentComputedStyleSpec(
              values: {'color': 'red'},
              lengths: {},
              fontSize: 16,
              rootFontSize: 16,
              available: false,
            ),
            'hidden': _spec(
              values: {'display': 'none', 'color': 'rgb(1, 2, 3)'},
              lengths: {'width': '50%', 'height': '20px'},
            ),
            'unmeasured': _spec(
              values: {'display': 'block', 'position': 'relative'},
              lengths: {
                'width': '900px',
                'height': '999px',
                'top': '10%',
                'bottom': 'auto',
                'left': '10%',
                'right': 'auto',
              },
            ),
          },
          child: const SizedBox(),
        ),
      );
      final packet = controller.capture(
        revision: 1,
        generation: 1,
        viewport: const Size(400, 300),
      )!;
      final boxes = {
        for (final raw in packet['boxes'] as List) (raw as Map)['id']: raw,
      };
      expect(boxes['blocked']!['kind'], 'none');
      expect(boxes['blocked'], isNot(contains('computedStyle')));
      expect(boxes['hidden']!['kind'], 'none');
      expect(boxes['hidden']!['computedStyle'], containsPair('width', '50%'));
      expect(boxes['hidden']!['computedStyle'], containsPair('height', '20px'));
      expect(boxes['unmeasured']!['kind'], 'unsupported');
      expect(boxes['unmeasured']!['computedStyle'], isNot(contains('width')));
      expect(boxes['unmeasured']!['computedStyle'], isNot(contains('height')));
      expect(boxes['unmeasured']!['computedStyle'], isNot(contains('top')));
      expect(boxes['unmeasured']!['computedStyle'], isNot(contains('left')));
    },
  );

  testWidgets(
    'style budget does not discard geometry or exceed script limits',
    (tester) async {
      final controller = NativeDocumentLayoutController();
      addTearDown(controller.dispose);
      final ids = {for (var index = 0; index < 200; index++) 'node-$index'};
      final values = {
        for (var index = 0; index < 3; index++)
          '--key-$index': List.filled(4096, '界').join(),
      };
      await tester.pumpWidget(
        NativeDocumentLayoutRoot(
          controller: controller,
          revision: 1,
          knownIds: ids,
          noBoxIds: ids,
          computedStyles: {for (final id in ids) id: _spec(values: values)},
          child: const SizedBox(),
        ),
      );
      final packet = controller.capture(
        revision: 1,
        generation: 1,
        viewport: const Size(400, 300),
      )!;
      final boxes = (packet['boxes'] as List).cast<Map>();
      expect(boxes, hasLength(200));
      expect(
        boxes.where((box) => box.containsKey('computedStyle')),
        isNotEmpty,
      );
      expect(boxes.every((box) => box['kind'] == 'none'), true);
      expect(
        boxes.where((box) => box.containsKey('computedStyle')).length,
        lessThan(200),
      );
      var aggregate = 0;
      for (final box in boxes) {
        final styles = box['computedStyle'] as Map?;
        if (styles == null) continue;
        final size = styles.entries.fold<int>(
          0,
          (sum, entry) =>
              sum +
              (entry.key as String).length +
              (entry.value as String).length,
        );
        expect(size, lessThanOrEqualTo(16 * 1024));
        aggregate += size;
      }
      expect(aggregate, lessThanOrEqualTo(2 * 1024 * 1024));
      expect(utf8.encode(jsonEncode(packet)).length, lessThan(4 * 1024 * 1024));
    },
  );

  testWidgets(
    'oversized declarations fail explicitly without truncating custom properties',
    (tester) async {
      final controller = NativeDocumentLayoutController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        NativeDocumentLayoutRoot(
          controller: controller,
          revision: 1,
          knownIds: const {'large', 'too-many'},
          noBoxIds: const {'large', 'too-many'},
          computedStyles: {
            'large': _spec(values: {'--large': List.filled(4097, 'x').join()}),
            'too-many': _spec(
              values: {for (var i = 0; i < 257; i++) '--value-$i': 'x'},
            ),
          },
          child: const SizedBox(),
        ),
      );
      final packet = controller.capture(
        revision: 1,
        generation: 1,
        viewport: const Size(400, 300),
      )!;
      for (final box in packet['boxes'] as List) {
        expect(box['kind'], 'none');
        expect(box, isNot(contains('computedStyle')));
      }
    },
  );

  testWidgets(
    'same-revision style changes require and capture a fresh layout',
    (tester) async {
      final controller = NativeDocumentLayoutController();
      addTearDown(controller.dispose);
      Widget document(String color) => NativeDocumentLayoutRoot(
        controller: controller,
        revision: 1,
        knownIds: const {'hidden'},
        noBoxIds: const {'hidden'},
        computedStyles: {
          'hidden': _spec(values: {'color': color}),
        },
        child: const SizedBox(),
      );
      await tester.pumpWidget(document('red'));
      expect(
        ((controller.capture(
                      revision: 1,
                      generation: 1,
                      viewport: Size.zero,
                    )!['boxes']
                    as List)
                .single
            as Map)['computedStyle'],
        containsPair('color', 'red'),
      );
      await tester.pumpWidget(document('blue'));
      expect(
        ((controller.capture(
                      revision: 1,
                      generation: 2,
                      viewport: Size.zero,
                    )!['boxes']
                    as List)
                .single
            as Map)['computedStyle'],
        containsPair('color', 'blue'),
      );
      expect(
        controller.capture(revision: 2, generation: 3, viewport: Size.zero),
        isNull,
      );
    },
  );
}
