import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:pirc_render/src/document_layout.dart';
import 'package:pirc_render/src/document_offsets.dart';
import 'package:pirc_render/src/html_document_styles.dart';

Map<String, NativeDocumentOffsetSpec> _specs(String css, {String? removeId}) {
  final document = html.parse(
    '<!doctype html><html id="root"><body id="body">'
    '<div id="parent"><div id="child"></div></div><div id="other"></div>'
    '</body></html>',
  );
  for (final node in document.querySelectorAll('[id]')) {
    if (node.id != removeId) node.attributes['data-pirc-script-id'] = node.id;
  }
  final styles = NativeDocumentStyleEngine(
    stylesheets: [
      NativeDocumentStylesheet(css, baseUrl: 'https://offsets.test/'),
    ],
    viewportWidth: 390,
    viewportHeight: 844,
    dark: false,
  ).apply(document);
  return nativeDocumentOffsetSpecs(
    document: document,
    stylesByElement: styles.stylesByElement,
  );
}

Widget _host(
  NativeDocumentLayoutController controller,
  Widget child, {
  Set<String> ids = const {'parent', 'child'},
}) => Directionality(
  textDirection: TextDirection.ltr,
  child: Align(
    alignment: Alignment.topLeft,
    child: NativeDocumentLayoutRoot(
      controller: controller,
      revision: 1,
      knownIds: ids,
      child: child,
    ),
  ),
);

Map<String, dynamic> _capture(NativeDocumentLayoutController controller) =>
    controller.capture(
      revision: 1,
      generation: 1,
      viewport: const Size(390, 844),
      scrollOffset: const Offset(20, 100),
    )!;
Map<String, dynamic> _box(Map<String, dynamic> packet, String id) =>
    (packet['boxes'] as List).cast<Map<String, dynamic>>().singleWhere(
      (box) => box['id'] == id,
    );

const _parentSpec = NativeDocumentOffsetSpec(
  parentId: 'parent',
  originId: 'parent',
  origin: NativeDocumentOffsetOrigin.paddingEdge,
);

void main() {
  test(
    'root/body and static-body origin are preserved before DOM wrapping',
    () {
      final specs = _specs('');
      expect(specs['root']!.parentId, isNull);
      expect(
        specs['root']!.origin,
        NativeDocumentOffsetOrigin.initialContainingBlock,
      );
      expect(specs['body']!.origin, NativeDocumentOffsetOrigin.zero);
      expect(specs['child']!.parentId, 'body');
      expect(specs['child']!.originId, 'root');
      expect(specs['child']!.origin, NativeDocumentOffsetOrigin.borderBox);
    },
  );
  test('relative body and nearest relative ancestor use their own origins', () {
    final body = _specs('body{position:relative}');
    expect(body['child']!.parentId, 'body');
    expect(body['child']!.originId, 'body');
    expect(body['child']!.origin, NativeDocumentOffsetOrigin.borderBox);
    final parent = _specs(
      'body,#parent{position:relative} #parent{top:0;left:auto}',
    );
    expect(parent['parent']!.parentId, 'body');
    expect(parent['child']!.parentId, 'parent');
    expect(parent['child']!.origin, NativeDocumentOffsetOrigin.paddingEdge);
  });
  for (final insets in [
    'top:1px',
    'right:-7.5px;bottom:12px',
    'left:10%;top:20%',
    'inset:1px 2% auto -4px',
  ]) {
    test(
      'relative native block insets expose measured offset metadata: $insets',
      () {
        final specs = _specs('#parent{position:relative;$insets}');
        expect(specs['parent']!.parentId, 'body');
        expect(specs['child']!.parentId, 'parent');
      },
    );
  }
  test('direct grid inline items expose native relative box metadata', () {
    final specs = _specs(
      'body{display:grid}#parent{display:inline;position:relative;left:10px}',
    );
    expect(specs['parent']!.parentId, 'body');
    expect(specs['child']!.parentId, 'parent');
  });
  test(
    'nonzero relative inline insets do not claim native fragment support',
    () {
      final specs = _specs('#parent{display:inline;position:relative;top:1px}');
      expect(specs.containsKey('parent'), isFalse);
      expect(specs.containsKey('child'), isFalse);
      expect(specs.containsKey('other'), isTrue);
    },
  );
  test(
    'supported CSS paint transforms select their measured containing block',
    () {
      final specs = _specs('#parent{transform:translateX(1px)}');
      expect(specs['parent']!.parentId, 'body');
      expect(specs['child']!.parentId, 'parent');
      expect(specs['child']!.origin, NativeDocumentOffsetOrigin.paddingEdge);
    },
  );
  test(
    'static block markers skip hidden siblings but reject visible inline whitespace',
    () {
      for (final row in [
        ('<span hidden>hidden</span>', true),
        ('<input type="hidden">', true),
        (' \n ', true),
        ('&nbsp;', false),
        ('<span>inline</span>', false),
      ]) {
        final doc = html.parse(
          '<body>${row.$1}<dialog open id="d"></dialog></body>',
        );
        expect(
          nativeDocumentStaticBlockPositionSupported(
            doc.querySelector('dialog')!,
            (_) => {},
          ),
          row.$2,
          reason: row.$1,
        );
      }
    },
  );
  for (final position in ['absolute', 'fixed']) {
    test(
      'block static-position $position exposes native containing block metadata',
      () {
        final specs = _specs('#parent{position:$position}');
        expect(
          specs['parent']!.parentId,
          position == 'fixed' ? isNull : 'body',
        );
        expect(specs['parent']!.requiresPositionedSurface, isTrue);
        expect(specs['child']!.parentId, 'parent');
        expect(specs['child']!.origin, NativeDocumentOffsetOrigin.paddingEdge);
      },
    );
  }
  for (final css in [
    'position:sticky',
    'position:relative;top:1em',
    'position:relative;left:calc(1px + 2%)',
    'position:relative;inset-inline-start:1px',
    'translate:1px',
    'scale:2',
    'rotate:1deg',
    'zoom:2',
    'contain:paint',
    'will-change:transform',
    'perspective:100px',
    'filter:blur(1px)',
    'display:table',
    'display:contents',
    'writing-mode:vertical-rl',
    'float:left',
    'column-count:1',
    'column-count:2',
  ]) {
    test('unsupported ancestor geometry stays explicit: $css', () {
      final specs = _specs('#parent{$css}');
      expect(specs.containsKey('parent'), isFalse);
      expect(specs.containsKey('child'), isFalse);
      expect(specs.containsKey('other'), isTrue);
    });
  }
  test(
    'missing ancestor IDs and changed style do not reuse old parent metadata',
    () {
      expect(
        _specs(
          '#parent{position:relative}',
          removeId: 'parent',
        ).containsKey('child'),
        isFalse,
      );
      expect(_specs('#parent{position:relative}')['child']!.parentId, 'parent');
      expect(_specs('#parent{position:static}')['child']!.parentId, 'body');
    },
  );

  testWidgets(
    'unproved positioned ownership withholds offsets without hiding layout',
    (t) async {
      final controller = NativeDocumentLayoutController();
      for (final origin in [
        NativeDocumentOffsetOrigin.viewport,
        NativeDocumentOffsetOrigin.initialContainingBlock,
      ]) {
        await t.pumpWidget(
          _host(
            controller,
            NativeDocumentLayoutElement(
              controller: controller,
              revision: 1,
              id: 'child',
              offsetSpec: NativeDocumentOffsetSpec(
                parentId: null,
                origin: origin,
                requiresPositionedSurface: true,
              ),
              child: const SizedBox(width: 20, height: 10),
            ),
            ids: const {'child'},
          ),
        );
        final box = _box(_capture(controller), 'child');
        expect(box['kind'], 'box');
        expect(box['width'], 20);
        expect(box, isNot(contains('offset')));
      }
      await t.pumpWidget(
        _host(
          controller,
          NativeDocumentLayoutElement(
            controller: controller,
            revision: 1,
            id: 'parent',
            offsetSpec: const NativeDocumentOffsetSpec(
              parentId: null,
              origin: NativeDocumentOffsetOrigin.viewport,
              requiresPositionedSurface: true,
            ),
            child: NativeDocumentLayoutElement(
              controller: controller,
              revision: 1,
              id: 'child',
              offsetSpec: _parentSpec,
              child: const SizedBox(width: 20, height: 10),
            ),
          ),
        ),
      );
      expect(_box(_capture(controller), 'child'), isNot(contains('offset')));
      await t.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );

  testWidgets('native offsets subtract actual unrounded border insets', (
    t,
  ) async {
    final controller = NativeDocumentLayoutController();
    addTearDown(controller.dispose);
    await t.pumpWidget(
      _host(
        controller,
        Padding(
          padding: const EdgeInsets.only(left: 11, top: 13),
          child: NativeDocumentLayoutElement(
            controller: controller,
            revision: 1,
            id: 'parent',
            child: DecoratedBox(
              decoration: BoxDecoration(border: Border.all(width: 2.5)),
              child: Padding(
                padding: const EdgeInsets.all(7.5),
                child: NativeDocumentLayoutElement(
                  controller: controller,
                  revision: 1,
                  id: 'child',
                  offsetSpec: _parentSpec,
                  child: const SizedBox(width: 20, height: 10),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    final box = _box(_capture(controller), 'child');
    expect(box['x'], 18.5);
    expect(box['y'], 20.5);
    expect(box['offset'], {'top': 5, 'left': 5, 'parentId': 'parent'});
    await t.pumpWidget(const SizedBox.shrink());
  });

  for (final parentState in ['missing', 'duplicate', 'not ancestor']) {
    testWidgets('native offsets omit $parentState parent without hiding box', (
      t,
    ) async {
      final controller = NativeDocumentLayoutController();
      addTearDown(controller.dispose);
      NativeDocumentLayoutElement parent() => NativeDocumentLayoutElement(
        controller: controller,
        revision: 1,
        id: 'parent',
        child: const SizedBox(width: 10, height: 10),
      );
      await t.pumpWidget(
        _host(
          controller,
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (parentState != 'missing') parent(),
              if (parentState == 'duplicate') parent(),
              NativeDocumentLayoutElement(
                controller: controller,
                revision: 1,
                id: 'child',
                offsetSpec: _parentSpec,
                child: const SizedBox(width: 20, height: 10),
              ),
            ],
          ),
        ),
      );
      await t.pumpAndSettle();
      final box = _box(_capture(controller), 'child');
      expect(box['kind'], 'box');
      expect(box.containsKey('offset'), isFalse);
      await t.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('scale transform retains bounding geometry and omits offsets', (
    t,
  ) async {
    final controller = NativeDocumentLayoutController();
    addTearDown(controller.dispose);
    await t.pumpWidget(
      _host(
        controller,
        Transform.scale(
          scale: 2,
          child: NativeDocumentLayoutElement(
            controller: controller,
            revision: 1,
            id: 'child',
            offsetSpec: const NativeDocumentOffsetSpec(
              parentId: null,
              origin: NativeDocumentOffsetOrigin.initialContainingBlock,
            ),
            child: const SizedBox(width: 20, height: 10),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    final box = _box(_capture(controller), 'child');
    expect(box['kind'], 'box');
    expect(box['width'], 40);
    expect(box.containsKey('offset'), isFalse);
    await t.pumpWidget(const SizedBox.shrink());
  });
}
