import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:pirc_render/src/document_computed_styles.dart';
import 'package:pirc_render/src/html_document_styles.dart';

void main() {
  test('marks only canvas boxes with two authored numeric pixel sizes', () {
    final fixed = _specFor(
      '<canvas id="fixed" style="width: 350px; height: 220px"></canvas>',
    );
    expect(fixed['fixed']!.canvasBitmapSizeIndependent, isTrue);
    expect(fixed['fixed']!.canvasEquivalentStyleWrites, isFalse);

    for (final style in [
      'width: auto; height: 220px',
      'width: 350px; height: 50%',
      'width: 22em; height: 220px',
      'width: calc(300px + 50px); height: 220px',
      'width: 350px',
    ]) {
      final spec = _specFor('<canvas id="candidate" style="$style"></canvas>');
      expect(
        spec['candidate']!.canvasBitmapSizeIndependent,
        isFalse,
        reason: style,
      );
    }
  });

  test(
    'keeps zero pixel dimensions eligible and requires the document gate',
    () {
      final zero = _specFor(
        '<canvas id="zero" style="width: 0px; height: 0px"></canvas>',
      );
      expect(zero['zero']!.canvasBitmapSizeIndependent, isTrue);

      final gated = _specFor(
        '<canvas id="gated" style="width: 350px; height: 220px"></canvas>',
        canvasBitmapAttributesIndependent: false,
      );
      expect(gated['gated']!.canvasBitmapSizeIndependent, isFalse);
      expect(gated['gated']!.canvasEquivalentStyleWrites, isFalse);
    },
  );

  test('accepts percent width under an explicit ordinary block width', () {
    final percent = _specFor('''
      <div id="parent" style="width: 350px; height: 240px">
        <canvas id="percent" style="width: 100%; height: 240px"></canvas>
      </div>
    ''');
    expect(percent['percent']!.canvasBitmapSizeIndependent, isTrue);
    expect(percent['percent']!.canvasEquivalentStyleWrites, isTrue);

    final pixels = _specFor('''
      <div id="parent" style="width: 350px; height: 240px">
        <canvas id="pixels" style="width: 350px; height: 240px"></canvas>
      </div>
    ''');
    expect(pixels['pixels']!.canvasBitmapSizeIndependent, isTrue);
    expect(pixels['pixels']!.canvasEquivalentStyleWrites, isTrue);

    final relativeParent = _specFor('''
      <div id="parent" style="position: relative; width: 350px; height: 240px">
        <canvas id="relative" style="width: 0%; height: 0px"></canvas>
      </div>
    ''');
    expect(relativeParent['relative']!.canvasBitmapSizeIndependent, isTrue);
    expect(relativeParent['relative']!.canvasEquivalentStyleWrites, isTrue);
  });

  test('rejects percent width without an explicit pixel-width parent', () {
    for (final parentStyle in ['height: 240px', 'width: 100%; height: 240px']) {
      final specs = _specFor('''
        <div id="parent" style="$parentStyle">
          <canvas id="candidate" style="width: 100%; height: 240px"></canvas>
        </div>
      ''');
      expect(
        specs['candidate']!.canvasBitmapSizeIndependent,
        isFalse,
        reason: parentStyle,
      );
      expect(
        specs['candidate']!.canvasEquivalentStyleWrites,
        isFalse,
        reason: parentStyle,
      );
    }
  });

  test('rejects percent sizing in non-block or intrinsic layout ancestors', () {
    for (final wrapper in [
      '<div style="display: flex; width: 350px; height: 240px">{canvas}</div>',
      '<div style="display: grid; width: 350px; height: 240px">{canvas}</div>',
      '<table style="width: 350px"><tbody><tr><td>{canvas}</td></tr></tbody></table>',
      '<div style="width: 350px"><span>{canvas}</span></div>',
      '<div style="width: 350px"><div style="display: inline-block; width: 350px">{canvas}</div></div>',
      '<div style="width: 350px; float: left; height: 240px">{canvas}</div>',
      '<div style="width: 350px; position: absolute; height: 240px">{canvas}</div>',
      '<div style="width: 350px; position: fixed; height: 240px">{canvas}</div>',
      '<div style="width: min-content"><div style="width: 350px">{canvas}</div></div>',
      '<div style="width: 350px; min-width: min-content">{canvas}</div>',
      '<div style="width: 350px; max-width: max-content">{canvas}</div>',
      '<div style="width: 350px; aspect-ratio: auto">{canvas}</div>',
      '<div style="width: 350px; inline-size: 350px">{canvas}</div>',
      '<div style="position: absolute"><div style="width: 350px">{canvas}</div></div>',
    ]) {
      final specs = _specFor(
        wrapper.replaceAll(
          '{canvas}',
          '<canvas id="candidate" style="width: 100%; height: 240px"></canvas>',
        ),
      );
      expect(
        specs['candidate']!.canvasBitmapSizeIndependent,
        isFalse,
        reason: wrapper,
      );
      expect(
        specs['candidate']!.canvasEquivalentStyleWrites,
        isFalse,
        reason: wrapper,
      );
    }
  });

  test('requires fixed pixel canvas height and supported writing mode', () {
    for (final canvasStyle in [
      'width: 100%; height: auto',
      'width: 100%; height: 50%',
      'width: auto; height: 240px',
    ]) {
      final specs = _specFor('''
        <div style="width: 350px; height: 240px">
          <canvas id="candidate" style="$canvasStyle"></canvas>
        </div>
      ''');
      expect(
        specs['candidate']!.canvasBitmapSizeIndependent,
        isFalse,
        reason: canvasStyle,
      );
      expect(
        specs['candidate']!.canvasEquivalentStyleWrites,
        isFalse,
        reason: canvasStyle,
      );
    }

    final vertical = _specFor('''
      <div style="width: 350px; height: 240px; writing-mode: vertical-rl">
        <canvas id="candidate" style="width: 100%; height: 240px"></canvas>
      </div>
    ''');
    expect(vertical['candidate']!.resizeSupported, isFalse);
    expect(vertical['candidate']!.canvasBitmapSizeIndependent, isFalse);
    expect(vertical['candidate']!.canvasEquivalentStyleWrites, isFalse);
  });

  test('does not mark non-canvas elements independent', () {
    final specs = _specFor(
      '<div id="ordinary" style="width: 350px; height: 220px"></div>',
    );
    expect(specs['ordinary']!.canvasBitmapSizeIndependent, isFalse);
    expect(specs['ordinary']!.canvasEquivalentStyleWrites, isFalse);
  });
  test('special UA and native layout boxes never grant percentage independence', () {
    for (final source in [
      '<fieldset style="width:350px"><canvas id="target" style="width:100%;height:240px"></canvas></fieldset>',
      '<button style="display:block;width:350px"><canvas id="target" style="width:100%;height:240px"></canvas></button>',
      '<dialog open style="width:350px"><canvas id="target" style="width:100%;height:240px"></canvas></dialog>',
      '<div style="width:350px;columns:2"><canvas id="target" style="width:100%;height:240px"></canvas></div>',
    ]) {
      final spec = _specFor(source)['target']!;
      expect(spec.canvasBitmapSizeIndependent, isFalse, reason: source);
      expect(spec.canvasEquivalentStyleWrites, isFalse, reason: source);
    }
  });

  test(
    'simple intrinsic and one-axis canvases expose size calculation candidates',
    () {
      for (final style in [
        '',
        'width:200px',
        'height:100px',
        'width:50%;height:50%',
      ]) {
        final specs = _specFor(
          '<div id="parent" style="width:350px;height:240px">'
          '<canvas id="target" style="$style"></canvas></div>',
        );
        expect(specs['target']!.canvasSizingProjection, isTrue, reason: style);
        expect(specs['parent']!.fixedBlockChildId, isNotNull);
      }
      for (final extra in [
        'padding:1px',
        'margin:auto',
        'max-width:200px',
        'width:auto !important',
      ]) {
        final spec = _specFor(
          '<div style="width:350px;height:240px">'
          '<canvas id="target" style="$extra"></canvas></div>',
        )['target']!;
        expect(spec.canvasSizingProjection, isFalse, reason: extra);
      }
    },
  );

  test(
    'size-changing projection rejects viewport-dependent parent positions and bases',
    () {
      for (final wrapper in [
        '<div style="position:relative;width:350px;height:240px;margin:0 auto">{canvas}</div>',
        '<div style="position:relative;left:50%;width:350px;height:240px">{canvas}</div>',
        '<div style="width:350px;height:240px;padding-left:10%">{canvas}</div>',
        '<div style="direction:rtl;width:350px;height:240px">{canvas}</div>',
        '<div style="width:350px;height:240px;transform:translateX(50%)">{canvas}</div>',
        '<p>Earlier text can wrap when a root scrollbar appears.</p><div style="width:350px;height:240px">{canvas}</div>',
        '<div>Earlier text<div style="width:350px;height:240px">{canvas}</div></div>',
      ]) {
        final specs = _specFor(
          wrapper.replaceFirst('{canvas}', '<canvas id="target"></canvas>'),
        );
        expect(
          specs['target']!.canvasSizingProjection,
          isFalse,
          reason: wrapper,
        );
      }
      final fixed = _specFor(
        '<div style="width:350px;height:240px;margin-left:20px"><canvas id="target"></canvas></div>',
      );
      expect(fixed['target']!.canvasSizingProjection, isTrue);
    },
  );

  test('projects box styles only for measured edgeless fixed canvases', () {
    for (final width in ['350px', '100%']) {
      final spec = _specFor(
        '<div style="width:350px;height:240px">'
        '<canvas id="target" style="width:$width;height:240px"></canvas></div>',
      )['target']!;
      expect(spec.replacedBoxStyleProjection, isTrue);
    }
    for (final extra in [
      'padding:1px',
      'border:1px solid',
      'width:350px !important',
      'display:inline !important',
      'box-sizing:content-box !important',
      'min-width:2px',
    ]) {
      final spec = _specFor(
        '<div style="width:350px;height:240px">'
        '<canvas id="target" style="width:350px;height:240px;$extra"></canvas></div>',
      )['target']!;
      expect(spec.replacedBoxStyleProjection, isFalse, reason: extra);
    }
    for (final overflow in ['auto', 'scroll', 'hidden;overflow-y:visible']) {
      final spec = _specFor(
        '<div style="width:350px;height:240px;overflow:$overflow">'
        '<canvas id="target" style="width:100%;height:240px"></canvas></div>',
      )['target']!;
      expect(spec.replacedBoxStyleProjection, isFalse, reason: overflow);
    }
    final document = html.parse(
      '<style>canvas {display:inline !important}</style>'
      '<div style="width:350px;height:240px"><canvas id="target" style="width:350px;height:240px"></canvas></div>',
    );
    final styles = NativeDocumentStyleEngine(
      stylesheets: [
        NativeDocumentStylesheet(
          document.querySelector('style')!.text,
          baseUrl: 'https://example.test/style.css',
        ),
      ],
      viewportWidth: 390,
      dark: false,
    ).apply(document);
    expect(styles.inlineBoxStyleOverridesIndependent, isFalse);
  });

  test(
    'ordinary fixed blocks retain clientWidth under descendant size changes',
    () {
      for (final style in [
        'width:350px',
        'width:350px;padding:8px;border:3px solid;box-sizing:content-box',
        'width:350px;padding:8px;border:3px solid;box-sizing:border-box;overflow:hidden',
      ]) {
        final spec = _specFor(
          '<div id="parent" style="$style"><div style="width:100px;height:40px"></div></div>',
        )['parent']!;
        expect(
          spec.clientWidthIndependentOfDescendantSizes,
          isTrue,
          reason: style,
        );
      }
    },
  );
  test(
    'clientWidth proof excludes intrinsic, scrollbar and unsupported sizing',
    () {
      for (final style in [
        'width:auto',
        'width:100%',
        'width:350px;min-width:100px',
        'width:350px;max-width:400px',
        'width:350px;padding-left:10%',
        'width:350px;display:inline-block',
        'width:350px;display:flex',
        'width:350px;display:grid',
        'width:350px;position:absolute',
        'width:350px;overflow:auto',
        'width:350px;overflow:scroll',
        'width:350px;overflow-x:hidden;overflow-y:visible',
        'width:350px;columns:2',
        'width:350px;aspect-ratio:1',
      ]) {
        final spec = _specFor(
          '<div id="parent" style="$style"><div></div></div>',
        )['parent']!;
        expect(
          spec.clientWidthIndependentOfDescendantSizes,
          isFalse,
          reason: style,
        );
      }
      for (final wrapper in [
        'display:flex',
        'display:grid',
        'display:inline-block',
        'float:left',
        'position:absolute',
        'width:min-content',
      ]) {
        final spec = _specFor(
          '<div style="$wrapper"><div id="parent" style="width:350px"></div></div>',
        )['parent']!;
        expect(
          spec.clientWidthIndependentOfDescendantSizes,
          isFalse,
          reason: wrapper,
        );
      }
      final dependent = _specFor(
        '<div id="parent" style="width:350px"></div>',
        canvasBitmapAttributesIndependent: false,
      )['parent']!;
      expect(dependent.clientWidthIndependentOfDescendantSizes, isFalse);
    },
  );
}

Map<String, NativeDocumentComputedStyleSpec> _specFor(
  String source, {
  bool? canvasBitmapAttributesIndependent,
}) {
  final document = html.parse(source);
  final testIdsByScriptId = <String, String>{};
  for (final (index, element) in document.querySelectorAll('*').indexed) {
    final scriptId = 'pirc-${index + 1}';
    testIdsByScriptId[scriptId] = element.id.isEmpty ? scriptId : element.id;
    element.attributes['data-pirc-script-id'] = 'pirc-${index + 1}';
  }
  final styles = NativeDocumentStyleEngine(
    stylesheets: const [],
    viewportWidth: 390,
    dark: false,
  ).apply(document);
  final byScriptId = nativeDocumentComputedStyleSpecs(
    document: document,
    stylesByElement: styles.stylesByElement,
    viewportWidth: 390,
    viewportHeight: 844,
    inlineBoxStyleOverridesIndependent:
        styles.inlineBoxStyleOverridesIndependent,
    canvasBitmapAttributesIndependent:
        canvasBitmapAttributesIndependent ??
        styles.canvasBitmapAttributesIndependent,
  );
  return {
    for (final entry in testIdsByScriptId.entries)
      if (byScriptId.containsKey(entry.key))
        entry.value: byScriptId[entry.key]!,
  };
}
