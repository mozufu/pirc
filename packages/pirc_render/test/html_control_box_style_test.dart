import 'package:csslib/parser.dart' as css_parser;
import 'package:csslib/visitor.dart' as css;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/html_control_box_style.dart';

List<css.Declaration> declarations(String source) {
  final sheet = css_parser.parse('x { $source }');
  final rule = sheet.topLevels.single as css.RuleSet;
  return rule.declarationGroup.declarations
      .whereType<css.Declaration>()
      .toList();
}

NativeHtmlControlBoxStyle style(
  String source, {
  double fontSize = 16,
  bool dark = false,
  bool multiline = false,
  NativeHtmlControlBoxUaPreset? uaPreset,
  bool applyUaDefaults = true,
}) => NativeHtmlControlBoxStyle.fromDeclarations(
  declarations(source),
  fontSize: fontSize,
  dark: dark,
  multiline: multiline,
  uaPreset: uaPreset,
  applyUaDefaults: applyUaDefaults,
);

void main() {
  test('text and textarea presets retain their browser box defaults', () {
    final input = style('');
    expect(input.padding, const EdgeInsets.fromLTRB(2, 1, 2, 1));
    expect(input.border.top.width, 2);
    expect(input.boxSizing, NativeHtmlControlBoxSizing.borderBox);

    final textarea = style('', multiline: true);
    expect(textarea.padding, const EdgeInsets.all(2));
    expect(textarea.border.top.width, 1);

    final select = style('', uaPreset: NativeHtmlControlBoxUaPreset.select);
    expect(select.padding, const EdgeInsets.fromLTRB(2, 0, 2, 0));
    expect(select.border.top.width, 1);
    expect(select.backgroundColor, isNull);
  });

  test('shorthand expansion honors important and source order per side', () {
    final box = style('''
      padding: 2px 3px;
      padding-left: 8px;
      padding-right: 4px !important;
      padding: 1px !important;
      border: 2px solid red !important;
      border: 1px solid blue;
      border-top-width: 3px !important;
    ''');

    expect(box.padding, const EdgeInsets.all(1));
    expect(box.border.top.width, 3);
    expect(box.border.right.width, 2);
    expect(box.border.top.color, const Color(0xffff0000));
    expect(box.border.bottom.color, const Color(0xffff0000));
    expect(
      box.specifiedProperties,
      containsAll([
        'padding',
        'padding-top',
        'padding-right',
        'padding-bottom',
        'padding-left',
        'border',
        'border-top-width',
        'border-right-color',
      ]),
    );
  });

  test(
    'content-box dimensions add resolved padding and border, then clamp',
    () {
      final box = style('''
      box-sizing: content-box;
      width: 100px;
      min-width: 150px;
      max-width: 180px;
      padding: 10px;
      border: 2px solid black;
    ''');
      final layout = box.resolveLayout(
        intrinsicBorderBoxSize: const Size(50, 20),
        constraints: const BoxConstraints(maxWidth: 250, maxHeight: 200),
      );
      expect(layout.size.width, 174);
      expect(layout.padding, const EdgeInsets.all(10));
      expect(layout.border.top.width, 2);
    },
  );

  test('percentages remain lazy until finite parent constraints are known', () {
    final box = style('width: 50%; height: 50%; padding-left: 10%;');
    expect(box.width!.unit, '%');
    expect(box.paddingLengths.left.unit, '%');

    final layout = box.resolveLayout(
      intrinsicBorderBoxSize: const Size(80, 30),
      constraints: const BoxConstraints(maxWidth: 200, maxHeight: 100),
    );
    expect(layout.size, const Size(100, 50));
    expect(layout.padding.left, 20);
  });

  test('font-relative lengths and slash-separated corner radii resolve', () {
    final box = style(
      'width: 10em; padding: 1em; border-radius: 2px 7px 11px 3px / 4px 5px 6px 7px;',
      fontSize: 12,
    );
    expect(box.width!.resolve(percentageBase: null), 120);
    expect(box.padding, const EdgeInsets.all(12));

    final layout = box.resolveLayout(
      intrinsicBorderBoxSize: const Size(20, 20),
      constraints: const BoxConstraints(maxWidth: 400, maxHeight: 200),
    );
    expect(layout.borderRadius.topLeft, const Radius.elliptical(2, 4));
    expect(layout.borderRadius.topRight, const Radius.elliptical(7, 5));
    expect(layout.borderRadius.bottomRight, const Radius.elliptical(11, 6));
    expect(layout.borderRadius.bottomLeft, const Radius.elliptical(3, 7));
  });

  test('individual corner radius longhand keeps separate axes', () {
    final box = style('border-top-left-radius: 2px 4px;');
    final layout = box.resolveLayout(
      intrinsicBorderBoxSize: const Size(80, 30),
      constraints: const BoxConstraints(maxWidth: 200, maxHeight: 100),
    );
    expect(layout.borderRadius.topLeft, const Radius.elliptical(2, 4));
  });

  test(
    'invalid colors do not replace the last valid color and are diagnosed',
    () {
      final box = style('''
      border-top-color: red;
      border-top-color: not-a-real-color;
      border-top-style: dashed;
      background-color: #123456;
    ''');
      expect(box.border.top.color, const Color(0xffff0000));
      expect(box.border.top.width, 2);
      expect(box.backgroundColor, const Color(0xff123456));
      expect(
        box.diagnostics.map((item) => item.code),
        contains('unsupported-color'),
      );
      expect(
        box.diagnostics.map((item) => item.code),
        isNot(contains('unsupported-border-style')),
      );

      final invalidHex = style(
        'background-color: #123456; background-color: #12345;',
      );
      expect(invalidHex.backgroundColor, const Color(0xff123456));
      expect(
        invalidHex.diagnostics.map((item) => item.code),
        contains('unsupported-color'),
      );
    },
  );

  test('select preset keeps only authored sides changed by the overlay', () {
    final box = style(
      'border-top-width: 3px; padding-left: 9px; width: 50%;',
      uaPreset: NativeHtmlControlBoxUaPreset.select,
    );
    expect(box.border.top.width, 3);
    expect(box.border.right.width, 1);
    expect(box.padding, const EdgeInsets.fromLTRB(9, 0, 2, 0));
    expect(box.specifiedProperties, contains('border-top-width'));
    expect(box.specifiedProperties, contains('padding-left'));
    expect(box.specifiedProperties, isNot(contains('border-right-width')));
  });

  test(
    'unsupported box values are reported without replacing valid winners',
    () {
      final box = style('padding-left: 5px; padding-left: calc(2px + 3px);');
      expect(box.padding.left, 5);
      expect(box.diagnostics, isNotEmpty);
      expect(box.diagnostics.last.property, 'padding-left');
    },
  );
}
