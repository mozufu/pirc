import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/document_style_loading.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/html_buttons.dart';
import 'package:pirc_render/src/html_control_border_painter.dart';
import 'package:pirc_render/src/html_document_content.dart';
import 'package:pirc_render/src/html_document_urls.dart';
import 'package:pirc_render/src/html_form_submission.dart';
import 'package:pirc_render/src/html_select.dart';
import 'package:pirc_render/src/html_text_fields.dart';

import '../../test/live_test.dart' show theme;
import 'capture_fonts.dart';

const _fixturePath = '../../fixtures/mobile-parity/html-control-styles.json';
const _webPath =
    '../../fixtures/mobile-parity/html-control-styles-expected.json';

Map<String, Object?> _rectJson(ui.Rect rect) => {
  'x': rect.left,
  'y': rect.top,
  'width': rect.width,
  'height': rect.height,
};

String? _colorCss(Color? color) {
  if (color == null) return null;
  final argb = color.toARGB32();
  final red = (argb >> 16) & 0xff;
  final green = (argb >> 8) & 0xff;
  final blue = argb & 0xff;
  final alpha = (argb >> 24) & 0xff;
  if (alpha == 255) return 'rgb($red, $green, $blue)';
  return 'rgba($red, $green, $blue, ${(alpha / 255).toStringAsFixed(3)})';
}

Map<String, Object?>? _borderSideJson(BorderSide? side) => side == null
    ? null
    : {
        'width': side.width,
        'style': side.style.name,
        'colorArgb': side.color.toARGB32(),
        'colorCss': _colorCss(side.color),
      };

Map<String, Object?>? _decorationJson(
  Container? container, {
  required TextDirection textDirection,
}) {
  if (container == null || container.decoration is! BoxDecoration) return null;
  final decoration = container.decoration! as BoxDecoration;
  final border = decoration.border;
  final padding = container.padding?.resolve(textDirection);
  final radius = decoration.borderRadius?.resolve(textDirection);
  return {
    'containerPadding': padding == null
        ? null
        : {
            'top': padding.top,
            'right': padding.right,
            'bottom': padding.bottom,
            'left': padding.left,
          },
    'backgroundColorArgb': decoration.color?.toARGB32(),
    'backgroundColorCss': _colorCss(decoration.color),
    'border': border is Border
        ? {
            'top': _borderSideJson(border.top),
            'right': _borderSideJson(border.right),
            'bottom': _borderSideJson(border.bottom),
            'left': _borderSideJson(border.left),
          }
        : null,
    'borderRadius': radius == null
        ? null
        : {
            'topLeft': {'x': radius.topLeft.x, 'y': radius.topLeft.y},
            'topRight': {'x': radius.topRight.x, 'y': radius.topRight.y},
            'bottomRight': {
              'x': radius.bottomRight.x,
              'y': radius.bottomRight.y,
            },
            'bottomLeft': {'x': radius.bottomLeft.x, 'y': radius.bottomLeft.y},
          },
  };
}

Container? _controlContainer(WidgetTester tester, Finder outer) {
  for (final container in tester.widgetList<Container>(
    find.descendant(of: outer, matching: find.byType(Container)),
  )) {
    final decoration = container.decoration;
    if (decoration is BoxDecoration &&
        (decoration.color != null ||
            decoration.border != null ||
            decoration.borderRadius != null)) {
      return container;
    }
  }
  return null;
}

Map<String, Object?>? _selectDecorationJson(
  WidgetTester tester,
  Finder outer,
  TextDirection textDirection,
) {
  BoxDecoration? decoration;
  for (final decorated in tester.widgetList<DecoratedBox>(
    find.descendant(of: outer, matching: find.byType(DecoratedBox)),
  )) {
    if (decorated.decoration is BoxDecoration) {
      final candidate = decorated.decoration as BoxDecoration;
      if (candidate.border != null || candidate.color != null) {
        decoration = candidate;
        break;
      }
    }
  }
  if (decoration == null) return null;
  final border = decoration.border;
  final rawPadding = tester
      .widgetList<Padding>(
        find.descendant(of: outer, matching: find.byType(Padding)),
      )
      .firstOrNull
      ?.padding;
  final actualPadding = rawPadding?.resolve(textDirection);
  final borderBox = border is Border ? border : null;
  final cssPadding = actualPadding != null && borderBox != null
      ? EdgeInsets.fromLTRB(
          actualPadding.left - borderBox.left.width,
          actualPadding.top - borderBox.top.width,
          actualPadding.right - borderBox.right.width,
          actualPadding.bottom - borderBox.bottom.width,
        )
      : null;
  final radius = decoration.borderRadius?.resolve(textDirection);
  return {
    'containerPadding': cssPadding == null
        ? null
        : {
            'top': cssPadding.top,
            'right': cssPadding.right,
            'bottom': cssPadding.bottom,
            'left': cssPadding.left,
          },
    'containerPaddingSource': actualPadding == null || borderBox == null
        ? null
        : 'Resolved native Padding widget edges minus actual BoxDecoration border widths.',
    'renderedOuterInsets': actualPadding == null
        ? null
        : {
            'top': actualPadding.top,
            'right': actualPadding.right,
            'bottom': actualPadding.bottom,
            'left': actualPadding.left,
          },
    'backgroundColorArgb': decoration.color?.toARGB32(),
    'backgroundColorCss': _colorCss(decoration.color),
    'border': borderBox == null
        ? null
        : {
            'top': _borderSideJson(borderBox.top),
            'right': _borderSideJson(borderBox.right),
            'bottom': _borderSideJson(borderBox.bottom),
            'left': _borderSideJson(borderBox.left),
          },
    'borderRadius': radius == null
        ? null
        : {
            'topLeft': {'x': radius.topLeft.x, 'y': radius.topLeft.y},
            'topRight': {'x': radius.topRight.x, 'y': radius.topRight.y},
            'bottomRight': {
              'x': radius.bottomRight.x,
              'y': radius.bottomRight.y,
            },
            'bottomLeft': {'x': radius.bottomLeft.x, 'y': radius.bottomLeft.y},
          },
  };
}

Map<String, Object?>? _controlBorderPainterJson(
  WidgetTester tester,
  Finder outer,
) {
  final painters = tester
      .widgetList<CustomPaint>(
        find.descendant(of: outer, matching: find.byType(CustomPaint)),
      )
      .where(
        (customPaint) =>
            customPaint.foregroundPainter is NativeHtmlControlBorderPainter,
      )
      .toList();
  if (painters.isEmpty) return null;
  if (painters.length != 1) {
    throw StateError(
      'Expected one native control border painter, found ${painters.length}.',
    );
  }

  final customPaint = painters.single;
  final painter =
      customPaint.foregroundPainter! as NativeHtmlControlBorderPainter;
  final renderBox = tester.getRect(find.byWidget(customPaint));
  Map<String, Object?> sideJson(String name, BorderSide side) {
    final cssStyle =
        (painter.styleNames[name] ??
                painter.styleNames['border-$name-style'] ??
                'solid')
            .trim()
            .toLowerCase();
    final paintedPattern = switch (cssStyle) {
      'none' || 'hidden' => 'none',
      'solid' || 'dashed' || 'dotted' => cssStyle,
      'double' => side.width < 3 ? 'solid' : 'double',
      _ => 'solid',
    };
    return {
      ...?_borderSideJson(side),
      'cssStyleName': cssStyle,
      'paintedPattern': paintedPattern,
      'styleFallbackApplied':
          !const {'none', 'hidden'}.contains(cssStyle) &&
          cssStyle != paintedPattern,
      'unsupportedCssStyleFallback':
          painter.unsupportedStyles[name] == cssStyle,
    };
  }

  final border = painter.border;
  final radius = painter.borderRadius.resolve(TextDirection.ltr);
  return {
    'renderCustomPaintRect': _rectJson(renderBox),
    'border': {
      'top': sideJson('top', border.top),
      'right': sideJson('right', border.right),
      'bottom': sideJson('bottom', border.bottom),
      'left': sideJson('left', border.left),
    },
    'borderRadius': {
      'topLeft': {'x': radius.topLeft.x, 'y': radius.topLeft.y},
      'topRight': {'x': radius.topRight.x, 'y': radius.topRight.y},
      'bottomRight': {'x': radius.bottomRight.x, 'y': radius.bottomRight.y},
      'bottomLeft': {'x': radius.bottomLeft.x, 'y': radius.bottomLeft.y},
    },
    'styleNames': Map<String, String>.of(painter.styleNames),
    'unsupportedStyles': painter.unsupportedStyles,
    'source':
        'NativeHtmlControlBorderPainter.foregroundPainter on this actual RenderCustomPaint box.',
  };
}

Map<String, Object?>? _withNativeBorderPainter(
  Map<String, Object?>? decoration,
  Map<String, Object?>? borderPainter, {
  bool decorationPaddingIncludesBorder = false,
}) {
  if (decoration == null && borderPainter == null) return null;
  final result = <String, Object?>{
    ...?decoration,
    if (borderPainter != null) ...{
      'border': borderPainter['border'],
      'borderRadius': borderPainter['borderRadius'],
      'borderSource': 'NativeHtmlControlBorderPainter',
      'borderPainter': borderPainter,
    },
  };
  final padding = decoration?['containerPadding'];
  if (decorationPaddingIncludesBorder &&
      padding is Map<String, Object?> &&
      borderPainter?['border'] is Map<String, Object?>) {
    final border = borderPainter!['border'] as Map<String, Object?>;
    final cssPadding = <String, double>{};
    for (final side in const ['top', 'right', 'bottom', 'left']) {
      final outerInset = padding[side];
      final borderSide = border[side];
      if (outerInset is! num || borderSide is! Map<String, Object?>) {
        continue;
      }
      final borderWidth = borderSide['width'];
      if (borderWidth is! num) continue;
      cssPadding[side] = outerInset.toDouble() - borderWidth.toDouble();
    }
    if (cssPadding.length == 4) {
      result['containerPadding'] = cssPadding;
      result['renderedOuterInsets'] = padding;
      result['containerPaddingSource'] =
          'Actual Container.padding minus the side widths drawn by NativeHtmlControlBorderPainter.';
    }
  }
  return result;
}

Map<String, Object?> _textStyleJson(TextStyle style) => {
  'fontFamily': style.fontFamily,
  'fontFamilyFallback': style.fontFamilyFallback,
  'fontSize': style.fontSize,
  'fontWeight': style.fontWeight?.value,
  'fontStyle': style.fontStyle?.name,
  'lineHeightFactor': style.height,
  'letterSpacing': style.letterSpacing,
  'colorArgb': style.color?.toARGB32(),
  'colorCss': _colorCss(style.color),
};

String _elementKind(dom.Element element) {
  if (element.localName == 'textarea') return 'textarea';
  if (element.localName == 'select') return 'select';
  return (element.attributes['type'] ?? 'text').toLowerCase();
}

String _sourceLabel(dom.Element element) {
  dom.Node? parent = element.parent;
  while (parent != null) {
    if (parent is dom.Element && parent.localName == 'label') {
      return parent.text.replaceAll(RegExp(r'\s+'), ' ').trim();
    }
    parent = parent.parent;
  }
  return '';
}

Map<String, Object?> _selectionJson(TextEditingController controller) {
  final selection = controller.selection;
  return {
    'supported': selection.isValid,
    'baseOffset': selection.baseOffset,
    'extentOffset': selection.extentOffset,
    'start': selection.isValid && selection.start >= 0 ? selection.start : null,
    'end': selection.isValid && selection.end >= 0 ? selection.end : null,
    'affinity': selection.affinity.name,
    'isDirectional': selection.isDirectional,
  };
}

class _ControlSource {
  const _ControlSource({
    required this.key,
    required this.selector,
    required this.element,
  });
  final String key;
  final String selector;
  final dom.Element element;
}

NativeHtmlTextFieldWidget _matchTextField(
  WidgetTester tester,
  _ControlSource source,
) {
  final name = source.element.attributes['name'];
  final kind = _elementKind(source.element);
  final initialValue = source.element.localName == 'textarea'
      ? source.element.text
      : source.element.attributes['value'] ?? '';
  final matches = tester
      .widgetList<NativeHtmlTextFieldWidget>(
        find.byType(NativeHtmlTextFieldWidget),
      )
      .where(
        (widget) =>
            widget.field.name == name &&
            widget.field.kind.name == kind &&
            widget.field.initialValue == initialValue &&
            widget.field.label == _sourceLabel(source.element),
      )
      .toList();
  if (matches.length != 1) {
    throw StateError(
      'DOM selector ${source.selector} matched ${matches.length} text-field descriptors; expected one for name=$name kind=$kind value=$initialValue.',
    );
  }
  return matches.single;
}

NativeHtmlSelectWidget _matchSelect(
  WidgetTester tester,
  _ControlSource source,
) {
  final name = source.element.attributes['name'];
  final expectedOptions = source.element.querySelectorAll('option').map((
    option,
  ) {
    final text = option.text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return (
      value: option.attributes.containsKey('value')
          ? option.attributes['value'] ?? ''
          : text,
      label: option.attributes.containsKey('label')
          ? option.attributes['label'] ?? ''
          : text,
    );
  }).toList();
  final matches = tester
      .widgetList<NativeHtmlSelectWidget>(find.byType(NativeHtmlSelectWidget))
      .where(
        (widget) =>
            widget.control.name == name &&
            widget.control.options.length == expectedOptions.length &&
            List.generate(expectedOptions.length, (index) {
              final actual = widget.control.options[index];
              final expected = expectedOptions[index];
              return actual.value == expected.value &&
                  actual.label == expected.label;
            }).every((matches) => matches),
      )
      .toList();
  if (matches.length != 1) {
    throw StateError(
      'DOM selector ${source.selector} matched ${matches.length} select descriptors; expected one for name=$name and options=${expectedOptions.map((option) => option.value).toList()}.',
    );
  }
  return matches.single;
}

Finder _textOuter(NativeHtmlTextFieldWidget widget) =>
    find.byKey(ValueKey('native-html-text-field-${widget.field.key}'));

Finder _selectOuter(NativeHtmlSelectWidget widget) =>
    find.byKey(ValueKey('native-html-select-${widget.control.key}'));

NativeHtmlButtonWidget _matchButton(
  WidgetTester tester,
  NativeHtmlButtonType type,
) {
  final matches = tester
      .widgetList<NativeHtmlButtonWidget>(find.byType(NativeHtmlButtonWidget))
      .where((widget) => widget.button.type == type)
      .toList();
  if (matches.length != 1) {
    throw StateError(
      'Expected one native ${type.name} button, found ${matches.length}.',
    );
  }
  return matches.single;
}

Map<String, Object?> _textState(
  _ControlSource source,
  NativeHtmlTextFieldWidget widget,
) {
  final field = widget.field;
  final controller = widget.state.controllerFor(field.key);
  return {
    'tag': source.element.localName,
    'type': _elementKind(source.element),
    'name': field.name,
    'value': widget.state.valueFor(field.key),
    'disabled': field.disabled,
    'readOnly': field.readOnly,
    'required': field.required,
    'visible': field.visible,
    'selection': _selectionJson(controller),
    'stateSource': 'NativeHtmlTextFieldState controller and descriptor',
  };
}

Map<String, Object?> _selectState(
  _ControlSource source,
  NativeHtmlSelectWidget widget,
) {
  final control = widget.control;
  final indices = widget.state.selectedIndices(control.key);
  return {
    'tag': source.element.localName,
    'type': control.multiple || control.size > 1
        ? 'select-multiple'
        : 'select-one',
    'name': control.name,
    'value': widget.state.valueFor(control.key),
    'selectedIndex': indices.isEmpty ? -1 : indices.first,
    'selectedValues': [for (final i in indices) control.options[i].value],
    'disabled': control.disabled,
    'readOnly': false,
    'required': source.element.attributes.containsKey('required'),
    'visible': control.visible,
    'selection': {
      'supported': false,
      'reason': 'A native select has no text selection range.',
    },
    'stateSource': 'NativeHtmlSelectState selected indices and descriptor',
  };
}

Map<String, Object?> _captureControl(
  WidgetTester tester,
  _ControlSource source,
) {
  if (source.element.localName != 'select') {
    final widget = _matchTextField(tester, source);
    final field = widget.field;
    final outer = _textOuter(widget);
    final outerRect = tester.getRect(outer);
    final editable = find.descendant(
      of: outer,
      matching: find.byType(EditableText),
    );
    final editableRect = editable.evaluate().isEmpty
        ? null
        : tester.getRect(editable.first);
    final insets = editableRect == null
        ? null
        : {
            'top': editableRect.top - outerRect.top,
            'right': outerRect.right - editableRect.right,
            'bottom': outerRect.bottom - editableRect.bottom,
            'left': editableRect.left - outerRect.left,
          };
    final decorationPaint = _decorationJson(
      _controlContainer(tester, outer),
      textDirection: Directionality.of(tester.element(outer)),
    );
    final borderPainter = _controlBorderPainterJson(tester, outer);
    final paint = _withNativeBorderPainter(
      decorationPaint,
      borderPainter,
      decorationPaddingIncludesBorder: true,
    );
    return {
      'selector': source.selector,
      'descriptorJoin':
          'Fixture selector resolves to a source DOM control; matching uses name, control kind, initial value, and the associated label exposed by the native descriptor.',
      'tag': source.element.localName,
      'type': _elementKind(source.element),
      'name': field.name,
      'descriptor': {
        'key': field.key,
        'kind': field.kind.name,
        'initialValue': field.initialValue,
        'disabled': field.disabled,
        'readOnly': field.readOnly,
        'required': field.required,
        'visible': field.visible,
        'rows': field.rows,
        'cols': field.cols,
        'size': field.size,
        'min': field.min,
        'max': field.max,
        'step': field.step,
        'label': field.label,
      },
      'state': _textState(source, widget),
      'renderedStyle': _textStyleJson(widget.textStyle),
      'geometry': {
        'controlBorderBox': _rectJson(outerRect),
        'editableTextBox': editableRect == null
            ? null
            : _rectJson(editableRect),
        'editableRenderBoxInsets': insets,
        'geometrySemantics':
            'Control bounds are actual native widget bounds. EditableText bounds and insets measure Flutter render objects, including native text-control internals; they are not asserted as CSS DOMRects or content-box dimensions.',
      },
      'paint': paint,
      'paintMeasurement': paint == null
          ? {
              'available': false,
              'reason':
                  'No native control paint was exposed below this control widget.',
            }
          : {
              'available': true,
              'boxDecorationAvailable': decorationPaint != null,
              'borderPainterAvailable': borderPainter != null,
              'borderPainterRect': borderPainter?['renderCustomPaintRect'],
              'source': borderPainter == null
                  ? 'Actual descendant BoxDecoration container and padding.'
                  : 'Actual descendant BoxDecoration container plus NativeHtmlControlBorderPainter and its RenderCustomPaint bounds.',
            },
    };
  }

  final widget = _matchSelect(tester, source);
  final control = widget.control;
  final state = _selectState(source, widget);
  final selectedIndex = state['selectedIndex'] as int;
  final selectedLabel = selectedIndex < 0
      ? ''
      : control.options[selectedIndex].label;
  final outer = _selectOuter(widget);
  final outerRect = tester.getRect(outer);
  final decorationPaint = _selectDecorationJson(
    tester,
    outer,
    Directionality.of(tester.element(outer)),
  );
  final borderPainter = _controlBorderPainterJson(tester, outer);
  final paint = _withNativeBorderPainter(decorationPaint, borderPainter);
  final selectedTexts = tester
      .widgetList<RichText>(
        find.descendant(of: outer, matching: find.byType(RichText)),
      )
      .where(
        (item) =>
            selectedLabel.isNotEmpty &&
            item.text.toPlainText().contains(selectedLabel),
      )
      .toList();
  Map<String, Object?>? selectedText;
  if (selectedTexts.isNotEmpty) {
    selectedText = {
      'label': selectedLabel,
      'rect': _rectJson(tester.getRect(find.byWidget(selectedTexts.first))),
      'geometrySemantics':
          'Actual Flutter RichText bounds for selected option label; not a CSS DOMRect or select content box.',
    };
  }
  return {
    'selector': source.selector,
    'descriptorJoin':
        'Fixture selector resolves to a source DOM select; matching uses name and associated label exposed by the native descriptor.',
    'tag': source.element.localName,
    'type': state['type'],
    'name': control.name,
    'descriptor': {
      'key': control.key,
      'label': control.label,
      'disabled': control.disabled,
      'visible': control.visible,
      'multiple': control.multiple,
      'size': control.size,
      'displaySize': control.displaySize,
      'options': [
        for (final option in control.options)
          {
            'index': option.index,
            'value': option.value,
            'label': option.label,
            'disabled': option.disabled,
          },
      ],
    },
    'state': state,
    'renderedStyle': _textStyleJson(widget.textStyle),
    'geometry': {
      'controlBorderBox': _rectJson(outerRect),
      'selectedOptionText': selectedText,
      'selectedOptionTextMeasurement': selectedText == null
          ? {
              'available': false,
              'reason': selectedLabel.isEmpty
                  ? 'No selected option has a visible label.'
                  : 'Selected label RichText was not found inside the select widget.',
            }
          : {'available': true},
      'geometrySemantics':
          'Control bounds are native widget bounds. Selected option text is glyph widget geometry, not a CSS DOMRect.',
    },
    'paint': paint,
    'paintMeasurement': paint == null
        ? {
            'available': false,
            'reason':
                'No native control paint was exposed below this select widget.',
          }
        : {
            'available': true,
            'boxDecorationAvailable': decorationPaint != null,
            'borderPainterAvailable': borderPainter != null,
            'borderPainterRect': borderPainter?['renderCustomPaintRect'],
            'source': borderPainter == null
                ? 'Actual descendant BoxDecoration and padding.'
                : 'Actual descendant BoxDecoration and NativeHtmlControlBorderPainter with its RenderCustomPaint bounds.',
          },
  };
}

Map<String, Object?> _captureControls(
  WidgetTester tester,
  Map<String, _ControlSource> sources,
) => {
  for (final entry in sources.entries)
    entry.key: _captureControl(tester, entry.value),
};

Map<String, Object?> _submissionJson(
  NativeHtmlFormSubmission submission,
  String documentUrl,
) {
  final request = submission.buildRequest(documentUrl: documentUrl);
  final body = request.body;
  final bytes = body == null ? null : utf8.encode(body);
  return {
    'action': submission.action,
    'method': submission.method,
    'enctype': submission.enctype,
    'target': submission.target,
    'targetSpecified': submission.targetSpecified,
    'submitterId': submission.submitterId,
    'entries': [
      for (final entry in submission.entries) [entry.name, entry.value],
    ],
    'request': {
      'url': request.url,
      'resolvedUrl': request.url.startsWith('/')
          ? resolveNativeDocumentUrl(request.url, documentUrl)
          : request.url,
      'method': request.method,
      'contentType': request.contentType,
      'bodyUtf8': body,
      'bodyByteLength': bytes?.length,
      'bodyHex': bytes?.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
    },
  };
}

Future<List<String>> _loadHostAlias(String alias, String facePrefix) async {
  const dir = '/System/Library/Fonts/Supplemental/';
  final paths = [
    '$dir$facePrefix.ttf',
    '$dir$facePrefix Bold.ttf',
    '$dir$facePrefix Italic.ttf',
    '$dir$facePrefix Bold Italic.ttf',
  ].where((path) => File(path).existsSync()).toList();
  if (paths.isEmpty) {
    throw StateError('No host $facePrefix font files were found.');
  }
  final loader = FontLoader(alias);
  for (final path in paths) {
    loader.addFont(File(path).readAsBytes().then(ByteData.sublistView));
  }
  await loader.load();
  return paths;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final fixture =
      jsonDecode(File(_fixturePath).readAsStringSync()) as Map<String, dynamic>;
  final web =
      jsonDecode(File(_webPath).readAsStringSync()) as Map<String, dynamic>;
  if (fixture['webRevision'] != 'bd3d90981271e1f93cf3d1d1a5bbf9b61136b74c' ||
      web['reference'] != fixture['webRevision'] ||
      web['fixture'] != fixture['id']) {
    throw StateError(
      'Raw HTML control capture does not match its pinned Chrome fixture.',
    );
  }

  final responseHtml = fixture['responseHtml'] as String;
  final origin = web['origin'] as String;
  final responsePath = fixture['responsePath'];
  final responseUrl = '$origin$responsePath?via=markdown-form';
  final responseBytes = Uint8List.fromList(utf8.encode(responseHtml));
  final parsedResponse = html_parser.parse(responseHtml);
  final sources = <String, _ControlSource>{};
  for (final entry
      in (fixture['snapshotControls'] as Map<String, dynamic>).entries) {
    final selector = entry.value.toString();
    final element = parsedResponse.querySelector(selector);
    if (element == null) {
      throw StateError('Fixture selector not found: $selector');
    }
    sources[entry.key] = _ControlSource(
      key: entry.key,
      selector: selector,
      element: element,
    );
  }
  if (sources.length != 14) {
    throw StateError('Expected fourteen source controls.');
  }

  final styleSources = fixture['stylesheets'] is Map<String, dynamic>
      ? fixture['stylesheets'] as Map<String, dynamic>
      : const <String, dynamic>{};
  final interactions = fixture['interactions'] as Map<String, dynamic>;
  final editedValues = interactions['editedValues'] as Map<String, dynamic>;
  final submitValues = interactions['submitValues'] as Map<String, dynamic>;
  final matrix =
      <({double width, Brightness brightness, double dpr, bool diagnostic})>[
        for (final width in [390.0, 768.0])
          for (final brightness in [Brightness.light, Brightness.dark])
            (width: width, brightness: brightness, dpr: 1, diagnostic: false),
        (width: 390, brightness: Brightness.light, dpr: 2, diagnostic: true),
      ];

  for (final config in matrix) {
    final width = config.width;
    final brightness = config.brightness;
    final dpr = config.dpr;
    final widthLabel = width.toInt();
    final scaleLabel = dpr.toInt();
    final schemeLabel = brightness.name;
    final diagnosticSuffix = config.diagnostic ? '-diagnostic' : '';
    final suffix = '$schemeLabel-$widthLabel-dpr$scaleLabel$diagnosticSuffix';
    testWidgets('native raw control styles $suffix', (tester) async {
      final steps = <String>[];
      final frameworkLayoutErrors = <Map<String, Object?>>[];
      final previousFlutterErrorHandler = FlutterError.onError;
      FlutterError.onError = (details) {
        final message = details.exceptionAsString();
        if (message.startsWith('A RenderHtmlFlex overflowed by ')) {
          frameworkLayoutErrors.add({
            'message': message,
            'library': details.library,
            'context': details.context?.toDescription(),
            'stackTrace': details.stack?.toString(),
          });
        }
        if (previousFlutterErrorHandler != null) {
          previousFlutterErrorHandler(details);
        } else {
          FlutterError.presentError(details);
        }
      };
      addTearDown(() {
        FlutterError.onError = previousFlutterErrorHandler;
      });
      void mark(String value) {
        steps.add(value);
        debugPrint('HTML control styles capture step: $value');
      }

      late List<String> arialFiles;
      late List<String> georgiaFiles;
      mark('font-load-start');
      await tester.runAsync(() async {
        await loadParityFonts();
        arialFiles = await _loadHostAlias('sans-serif', 'Arial');
        georgiaFiles = await _loadHostAlias('Georgia', 'Georgia');
      });
      mark('font-load-complete');

      tester.view.devicePixelRatio = dpr;
      tester.view.physicalSize = ui.Size(width * dpr, 844 * dpr);
      tester.platformDispatcher.platformBrightnessTestValue = brightness;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

      final styleRequests = <Map<String, Object?>>[];
      final styleLoader = NativeDocumentStyleLoader(
        fetch: (reference, baseUrl) async {
          final cssText = styleSources[Uri.parse(reference).path];
          if (cssText == null) {
            throw StateError(
              'No local stylesheet fixture for $reference from $baseUrl.',
            );
          }
          styleRequests.add({
            'url': reference,
            'baseUrl': baseUrl,
            'status': 200,
            'mimeType': 'text/css',
          });
          return <String, dynamic>{
            'status': 200,
            'mimeType': 'text/css',
            'charset': 'utf-8',
            'bytes': Uint8List.fromList(utf8.encode('$cssText')),
            'finalUrl': reference,
          };
        },
        resolve: (reference, baseUrl) async =>
            resolveNativeDocumentUrl(reference, baseUrl),
        isCurrent: () => true,
      );
      mark('stylesheet-loader-start');
      final loaded = await styleLoader.load(
        responseHtml,
        baseUrl: responseUrl,
        documentEncoding: 'utf-8',
      );
      mark('stylesheet-loader-complete');

      final content = NativeHtmlDocumentContent.fromBytes(
        responseBytes,
        mimeType: 'text/html',
        charset: 'utf-8',
      );
      final document = NativeFetchedDocument(
        id: 0,
        url: responseUrl,
        status: 200,
        bytes: responseBytes,
        mimeType: 'text/html',
        content: content,
        headers: const {'Content-Type': 'text/html; charset=utf-8'},
        stylesheets: loaded.stylesheets,
        styleDiagnostics: loaded.diagnostics,
      );
      final submitted = <NativeHtmlFormSubmission>[];
      var cleanedUp = false;
      Future<void> cleanup() async {
        if (cleanedUp) return;
        mark('teardown-start');
        mark('widget-unmount-start');
        await tester.pumpWidget(const SizedBox.shrink());
        mark('widget-unmount-complete');
        await tester.pump(const Duration(seconds: 2));
        mark('post-unmount-pump-complete');
        document.dispose();
        mark('document-dispose-complete');
        cleanedUp = true;
        mark('teardown-complete');
      }

      addTearDown(cleanup);

      final viewportBoundary = GlobalKey();
      mark('pump-widget-start');
      await tester.pumpWidget(
        RepaintBoundary(
          key: viewportBoundary,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: theme.build(brightness),
            home: Material(
              type: MaterialType.transparency,
              child: NativeFetchedDocumentView(
                document: document,
                gateway: Gateway(),
                onLink: (_) {},
                onSubmit: submitted.add,
              ),
            ),
          ),
        ),
      );
      mark('pump-widget-complete');
      await tester.pumpAndSettle();
      mark('pump-and-settle-complete');
      expect(tester.takeException(), isNull);
      expect(find.byType(HtmlWidget), findsOneWidget);
      expect(find.byType(NativeHtmlTextFieldWidget), findsNWidgets(12));
      expect(find.byType(NativeHtmlSelectWidget), findsNWidgets(2));
      expect(find.byType(NativeHtmlButtonWidget), findsNWidgets(2));

      final initialControls = _captureControls(tester, sources);
      final nativeBorderPainterCount = initialControls.values.where((value) {
        if (value is! Map<String, Object?>) return false;
        final paint = value['paint'];
        return paint is Map<String, Object?> &&
            paint['borderPainter'] is Map<String, Object?>;
      }).length;
      expect(nativeBorderPainterCount, 14);
      final viewRect = tester.getRect(find.byType(NativeFetchedDocumentView));
      final rootFragmentRect = tester.getRect(find.byType(HtmlWidget));
      expect(viewRect.size, ui.Size(width, 844));
      final selectionInteractions = <Map<String, Object?>>[];
      final textSelectionInteractions = <Map<String, Object?>>[];
      final buttonInteractions = <Map<String, Object?>>[];

      final pngPath = 'build/parity/html-control-styles-native-$suffix.png';
      final jsonPath = 'build/parity/html-control-styles-native-$suffix.json';
      late Map<String, int> viewportCornerPixel;
      mark('capture-runAsync-start');
      await tester.runAsync(() async {
        mark('to-image-start');
        final image =
            await (viewportBoundary.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: dpr);
        mark('to-image-complete');
        try {
          expect(image.width, (width * dpr).toInt());
          expect(image.height, (844 * dpr).toInt());
          mark('png-byte-data-start');
          final pngBytes = await image.toByteData(
            format: ui.ImageByteFormat.png,
          );
          mark('png-byte-data-complete');
          final rgba = await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          mark('rgba-byte-data-complete');
          final offset =
              ((image.height - 1) * image.width + image.width - 1) * 4;
          viewportCornerPixel = {
            'x': image.width - 1,
            'y': image.height - 1,
            'r': rgba!.getUint8(offset),
            'g': rgba.getUint8(offset + 1),
            'b': rgba.getUint8(offset + 2),
            'a': rgba.getUint8(offset + 3),
          };
          mark('png-write-start');
          final file = File(pngPath);
          await file.parent.create(recursive: true);
          await file.writeAsBytes(pngBytes!.buffer.asUint8List());
          mark('png-write-complete');
        } finally {
          mark('image-dispose-start');
          image.dispose();
          mark('image-dispose-complete');
        }
      });
      mark('capture-runAsync-complete');

      Future<void> enterText(
        String key,
        String value, {
        bool selectLastCharacter = false,
      }) async {
        final source = sources[key]!;
        final widget = _matchTextField(tester, source);
        final outer = _textOuter(widget);
        await tester.ensureVisible(outer);
        await tester.pumpAndSettle();
        final editable = find.descendant(
          of: outer,
          matching: find.byType(EditableText),
        );
        if (editable.evaluate().isEmpty) {
          throw StateError('No EditableText exposed for ${source.selector}.');
        }
        await tester.enterText(editable.first, value);
        await tester.pump();
        if (selectLastCharacter) {
          await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
          await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowLeft);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowLeft);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
          await tester.pump();
          final selection = widget.state
              .controllerFor(widget.field.key)
              .selection;
          final matchesBrowserAction =
              selection.baseOffset == value.length &&
              selection.extentOffset == value.length - 1;
          if (!matchesBrowserAction) {
            throw StateError(
              'Shift+ArrowLeft selected ${selection.baseOffset}:${selection.extentOffset} for ${source.selector}, expected ${value.length}:${value.length - 1}.',
            );
          }
          textSelectionInteractions.add({
            'selector': source.selector,
            'method':
                'tester Shift+ArrowLeft after typing, matching the actual browser keyboard action',
            'textLength': value.length,
            'selection': _selectionJson(
              widget.state.controllerFor(widget.field.key),
            ),
          });
        }
      }

      Future<void> chooseOption(String key, String value) async {
        final source = sources[key]!;
        final widget = _matchSelect(tester, source);
        final option = widget.control.options.singleWhere(
          (candidate) => candidate.value == value,
        );
        final outer = _selectOuter(widget);
        await tester.ensureVisible(outer);
        await tester.pumpAndSettle();
        final controlRect = tester.getRect(outer);
        final visibleRect = controlRect.intersect(
          Rect.fromLTWH(0, 0, width, 844),
        );
        var popupOpened = false;
        if (!visibleRect.isEmpty) {
          await tester.tapAt(visibleRect.center);
          await tester.pumpAndSettle();
          final optionFinder = find.text(option.label);
          if (optionFinder.evaluate().isNotEmpty) {
            await tester.tap(optionFinder.last);
            await tester.pumpAndSettle();
            popupOpened = true;
            selectionInteractions.add({
              'selector': source.selector,
              'value': value,
              'method': 'pointer tap on the native select and popup option',
              'controlRect': _rectJson(controlRect),
              'tapPoint': {
                'x': visibleRect.center.dx,
                'y': visibleRect.center.dy,
              },
            });
          }
        }
        if (!popupOpened) {
          final changed = widget.state.select(widget.control.key, option.index);
          await tester.pump();
          if (!changed) {
            throw StateError(
              'Native select state did not change for ${source.selector}.',
            );
          }
          selectionInteractions.add({
            'selector': source.selector,
            'value': value,
            'method': 'NativeHtmlSelectState.select fallback',
            'controlRect': _rectJson(controlRect),
            'reason': visibleRect.isEmpty
                ? 'The control has no visible viewport intersection for a pointer action.'
                : 'A pointer action did not open the native option popup.',
          });
        }
        final selectedValue = widget.state.valueFor(widget.control.key);
        if (selectedValue != value) {
          throw StateError(
            'Select interaction for ${source.selector} produced $selectedValue, expected $value.',
          );
        }
      }

      Future<void> activateButton(NativeHtmlButtonType type) async {
        final widget = _matchButton(tester, type);
        final finder = find.byWidget(widget);
        await tester.ensureVisible(finder);
        await tester.pumpAndSettle();
        final buttonRect = tester.getRect(finder);
        final visibleRect = buttonRect.intersect(
          Rect.fromLTWH(0, 0, width, 844),
        );
        if (!visibleRect.isEmpty) {
          await tester.tapAt(visibleRect.center);
          await tester.pumpAndSettle();
          buttonInteractions.add({
            'type': type.name,
            'label': widget.button.label,
            'method': 'pointer tap on the native button widget',
            'buttonRect': _rectJson(buttonRect),
          });
        } else {
          final activated = await widget.state.activate(widget.button.key);
          await tester.pump();
          if (!activated) {
            throw StateError('Native ${type.name} button did not activate.');
          }
          buttonInteractions.add({
            'type': type.name,
            'label': widget.button.label,
            'method': 'NativeHtmlButtonState.activate',
            'buttonRect': _rectJson(buttonRect),
            'reason':
                'The button has no visible viewport intersection for a pointer action.',
          });
        }
      }

      for (final entry in editedValues.entries) {
        if (sources[entry.key]!.element.localName == 'select') {
          await chooseOption(entry.key, entry.value.toString());
        } else {
          await enterText(
            entry.key,
            entry.value.toString(),
            selectLastCharacter: const {
              'textInherit',
              'passwordInherit',
              'textareaInherit',
            }.contains(entry.key),
          );
        }
      }
      mark('user-edits-complete');
      final afterEdits = _captureControls(tester, sources);

      Future<Map<String, Object?>> attemptEdit(
        String key,
        String attempt,
      ) async {
        final widget = _matchTextField(tester, sources[key]!);
        final before = widget.state.valueFor(widget.field.key);
        final outer = _textOuter(widget);
        await tester.ensureVisible(outer);
        await tester.pumpAndSettle();
        final editable = find.descendant(
          of: outer,
          matching: find.byType(EditableText),
        );
        String? inputError;
        try {
          await tester.enterText(editable.first, attempt);
          await tester.pump();
        } catch (error) {
          inputError = '$error';
        }
        final after = widget.state.valueFor(widget.field.key);
        return {
          'before': before,
          'attempt': attempt,
          'after': after,
          'unchanged': before == after,
          'inputChannelError': inputError,
          'measurement':
              'Flutter text-input attempt against the live native control.',
        };
      }

      final readonlyAttempt = await attemptEdit(
        'textReadonly',
        interactions['readonlyAttempt'].toString(),
      );
      final disabledAttempt = await attemptEdit(
        'textDisabled',
        interactions['disabledAttempt'].toString(),
      );
      await activateButton(NativeHtmlButtonType.reset);
      mark('form-reset-complete');
      final afterReset = _captureControls(tester, sources);
      final resetRestoredInitialValues = <String, bool>{};
      for (final key in sources.keys) {
        final initialState =
            (initialControls[key] as Map<String, Object?>)['state']
                as Map<String, Object?>;
        final resetState =
            (afterReset[key] as Map<String, Object?>)['state']
                as Map<String, Object?>;
        resetRestoredInitialValues[key] =
            initialState['value'] == resetState['value'];
      }
      expect(
        resetRestoredInitialValues.values.every((restored) => restored),
        isTrue,
        reason: 'Native reset must restore all fourteen source values.',
      );
      for (final entry in submitValues.entries) {
        if (sources[entry.key]!.element.localName == 'select') {
          await chooseOption(entry.key, entry.value.toString());
        } else {
          await enterText(entry.key, entry.value.toString());
        }
      }
      final beforeSubmit = _captureControls(tester, sources);
      await activateButton(NativeHtmlButtonType.submit);
      mark('form-submit-callback-complete');
      expect(submitted, hasLength(1));
      final submission = _submissionJson(submitted.single, responseUrl);

      final capture = <String, Object?>{
        'schemaVersion': 1,
        'fixture': fixture['id'],
        'reference': fixture['webRevision'],
        'responseUrl': responseUrl,
        'mimeType': 'text/html',
        'status': 200,
        'width': width.toInt(),
        'height': 844,
        'devicePixelRatio': dpr,
        'diagnosticScaleOnly': config.diagnostic,
        'colorScheme': brightness.name,
        'viewportRect': _rectJson(viewRect),
        'htmlWidgetRootFragmentRect': _rectJson(rootFragmentRect),
        'htmlWidgetRootFragmentRectNote':
            'The HtmlWidget fragment box is not a CSS body or form box.',
        'controls': initialControls,
        'interactions': {
          'afterEdits': afterEdits,
          'selectActions': selectionInteractions,
          'textSelectionActions': textSelectionInteractions,
          'buttonActions': buttonInteractions,
          'readonlyAttempt': readonlyAttempt,
          'disabledAttempt': disabledAttempt,
          'afterReset': afterReset,
          'resetRestoredInitialValues': resetRestoredInitialValues,
          'beforeSubmit': beforeSubmit,
          'submission': submission,
        },
        'loadedStylesheets': [
          for (var index = 0; index < loaded.stylesheets.length; index++)
            {
              'order': index,
              'baseUrl': loaded.stylesheets[index].baseUrl,
              'media': loaded.stylesheets[index].media,
              'cssText': loaded.stylesheets[index].cssText,
            },
        ],
        'stylesheetRequests': styleRequests,
        'styleLoaderDiagnostics': loaded.diagnostics,
        'renderingDiagnostics': {
          'document': document.renderingDiagnostics,
          'frameworkLayoutErrors': frameworkLayoutErrors,
          'knownLayoutErrorPolicy':
              'RenderHtmlFlex overflows are recorded and forwarded to the normal test binding; the post-layout assertion requires zero framework errors.',
        },
        'viewportCornerPixel': viewportCornerPixel,
        'pngPath': pngPath,
        'diagnosticSteps': List<String>.of(steps),
        'hostFontAliases': {
          'Arial': {'comparisonOnly': true, 'files': arialFiles},
          'sans-serif': {
            'comparisonOnly': true,
            'resolvedFaceFamily': 'Arial',
            'files': arialFiles,
          },
          'Georgia': {'comparisonOnly': true, 'files': georgiaFiles},
        },
        'measurementLimits': [
          'Host Arial and Georgia files are comparison-only aliases and are not bundled in the app.',
          'The capture records Flutter widget TextStyle and painted BoxDecoration values; it does not treat them as a browser computed-style table.',
          'The 2x capture is only a native diagnostic at 390px light mode and has no web reference.',
          'EditableText and selected-option text boxes are Flutter render geometry, not CSS DOMRects.',
        ],
        'coverage': {
          'expectedControls': 14,
          'capturedControls': initialControls.length,
          'textFields': 12,
          'selects': 2,
          'actualRenderedTextStyle': true,
          'actualControlBorderBox': true,
          'actualPaintedDecorationWhenExposed': true,
          'typedEdits': true,
          'selectionState': true,
          'readOnlyDisabledAttempts': true,
          'reset': true,
          'formSubmission': true,
          'frameworkLayoutErrorsRecorded': true,
          'frameworkLayoutErrorCount': frameworkLayoutErrors.length,
          'textSelectionActions': textSelectionInteractions.length,
          'nativeControlBorderPainters': nativeBorderPainterCount,
          'fullVisualScopeAccepted': false,
        },
        'visualParityAccepted': false,
      };
      mark('json-write-start');
      final jsonText = const JsonEncoder.withIndent('  ').convert(capture);
      await tester.runAsync(() async {
        final file = File(jsonPath);
        await file.parent.create(recursive: true);
        await file.writeAsString('$jsonText\n');
      });
      mark('json-write-complete');
      expect(viewportCornerPixel['a'], 255);
      mark('explicit-cleanup-start');
      await cleanup();
      mark('test-body-complete');
    });
  }
}
