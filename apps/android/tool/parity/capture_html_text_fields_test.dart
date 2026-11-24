import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:pirc_render/src/html_text_fields.dart';
import 'package:pirc_render/src/native_markdown.dart';
import '../../test/live_test.dart' show theme;
import '../../test/native_html_test.dart' show tapText;
import 'capture_fonts.dart';

void main() {
  final fixture =
      jsonDecode(
            File(
              '../../fixtures/mobile-parity/html-text-fields.json',
            ).readAsStringSync(),
          )
          as Map;
  final expected =
      jsonDecode(
            File(
              '../../fixtures/mobile-parity/html-text-fields-expected.json',
            ).readAsStringSync(),
          )
          as Map;
  for (final brightness in Brightness.values) {
    for (final width in fixture['widths'] as List) {
      testWidgets(
        'HTML text fields ${brightness.name} $width browser behavior and capture',
        (tester) async {
          await tester.runAsync(loadParityFonts);
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = Size(
            (width as num).toDouble(),
            (fixture['height'] as num).toDouble(),
          );
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final boundary = GlobalKey();
          final observations = <Map<String, Object?>>[];
          final reference =
              ((expected['themes'][brightness.name]['widths'] as List)
                          .singleWhere((row) => row['width'] == width)
                      as Map)['cases']
                  as List;
          var mountId = 0;
          Future<void> mount(String source) async {
            final base = theme.build(brightness);
            await tester.pumpWidget(
              RepaintBoundary(
                key: boundary,
                child: MaterialApp(
                  debugShowCheckedModeBanner: false,
                  theme: base.copyWith(
                    textTheme: base.textTheme.apply(fontFamily: 'Arial'),
                  ),
                  home: Scaffold(
                    body: SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          NativeMarkdown(
                            key: ValueKey(mountId),
                            source: source,
                            fontSize: 15,
                            lineHeight: 1.65,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
          }

          dom.Element element(String selector) {
            for (final widget in tester.widgetList<HtmlWidget>(
              find.byType(HtmlWidget),
            )) {
              final result = html
                  .parseFragment(widget.html)
                  .querySelector(selector);
              if (result != null) return result;
            }
            throw StateError('Missing DOM selector $selector');
          }

          NativeHtmlTextFieldWidget field(dom.Element element) {
            for (final widget in tester.widgetList<NativeHtmlTextFieldWidget>(
              find.byType(NativeHtmlTextFieldWidget),
            )) {
              if (widget.state.resolveControl(element)?.key ==
                  widget.field.key) {
                return widget;
              }
            }
            throw StateError('Missing native field ${element.outerHtml}');
          }

          for (final item in fixture['cases'] as List) {
            mountId++;
            await mount(item['source'] as String);
            final phases =
                (reference.singleWhere((row) => row['id'] == item['id'])
                        as Map)['observations']
                    as List;
            Future<void> check(String phase) async {
              final web =
                  phases.singleWhere((row) => row['phase'] == phase) as Map;
              final measured = <Map<String, Object?>>[];
              for (final control in web['controls'] as List) {
                if (control['rendered'] != true) continue;
                // Duplicate IDs intentionally resolve to the actual control tag.
                final node = element(
                  '${control['tag']}[id="${control['id']}"]',
                );
                final native = field(node);
                final state = native.state;
                final descriptor = native.field;
                expect(
                  state.controllerFor(descriptor.key).text,
                  control['value'],
                  reason: '${item['id']} $phase ${control['id']}',
                );
                expect(descriptor.disabled, control['state']['disabled']);
                expect(descriptor.readOnly, control['state']['readOnly']);
                expect(descriptor.label, control['accessibleName']);
                if (descriptor.kind == NativeHtmlTextFieldKind.number) {
                  expect(descriptor.min, control['attributes']['min']);
                  expect(descriptor.max, control['attributes']['max']);
                  expect(descriptor.step, control['attributes']['step']);
                  expect(
                    tester
                        .widget<TextField>(
                          find.descendant(
                            of: find.byWidget(native),
                            matching: find.byType(TextField),
                          ),
                        )
                        .keyboardType,
                    const TextInputType.numberWithOptions(
                      decimal: true,
                      signed: true,
                    ),
                  );
                }
                expect(
                  state.focusNodeFor(descriptor.key).hasFocus,
                  control['focused'],
                  reason: 'focus ${control['id']} $phase',
                );
                final box = tester.getRect(find.byWidget(native));
                measured.add({
                  'id': control['id'],
                  'x': box.left,
                  'y': box.top,
                  'width': box.width,
                  'height': box.height,
                  'deltaX': box.left - (control['box']['x'] as num),
                  'deltaY': box.top - (control['box']['y'] as num),
                  'deltaWidth': box.width - (control['box']['width'] as num),
                  'deltaHeight': box.height - (control['box']['height'] as num),
                });
              }
              expect(tester.takeException(), isNull);
              await tester.runAsync(() async {
                final image =
                    await (boundary.currentContext!.findRenderObject()
                            as RenderRepaintBoundary)
                        .toImage();
                try {
                  final bytes = await image.toByteData(
                    format: ui.ImageByteFormat.png,
                  );
                  final output = File(
                    'build/parity/html-text-fields-native-${brightness.name}-$width-${item['id']}-$phase.png',
                  );
                  await output.parent.create(recursive: true);
                  await output.writeAsBytes(bytes!.buffer.asUint8List());
                } finally {
                  image.dispose();
                }
              });
              observations.add({
                'case': item['id'],
                'phase': phase,
                'controls': measured,
              });
            }

            await check('initial');
            for (final action in item['actions'] as List) {
              if (action['mode'] == 'replace-markdown') {
                await mount(action['source'] as String);
              } else {
                final node = element(action['selector'] as String);
                if (action['mode'] == 'insert') {
                  final widget = field(node);
                  final controller = widget.state.controllerFor(
                    widget.field.key,
                  );
                  widget.state.focusControl(widget.field.key);
                  final start = action['start'] as int,
                      end = action['end'] as int;
                  controller.selection = TextSelection(
                    baseOffset: start,
                    extentOffset: end,
                  );
                  await tester.pump();
                  final inserted = action['value'] as String;
                  tester.testTextInput.updateEditingValue(
                    TextEditingValue(
                      text: controller.text.replaceRange(start, end, inserted),
                      selection: TextSelection.collapsed(
                        offset: start + inserted.length,
                      ),
                    ),
                  );
                } else if (action['mode'] == 'dom-click') {
                  // Browser HTMLElement.click() has no pointer-down blur.
                  for (final widget
                      in tester.widgetList<NativeHtmlTextFieldWidget>(
                        find.byType(NativeHtmlTextFieldWidget),
                      )) {
                    if (widget.state.resolveLabel(node) != null) {
                      widget.state.activateLabel(node);
                      break;
                    }
                  }
                } else if (action['mode'] == 'fill') {
                  final widget = field(node);
                  final editable = find.descendant(
                    of: find.byWidget(widget),
                    matching: find.byType(EditableText),
                  );
                  await tester.ensureVisible(editable);
                  await tester.enterText(editable, action['value'] as String);
                } else if (action['mode'] == 'key') {
                  final widget = field(node);
                  widget.state.focusControl(widget.field.key);
                  await tester.pump();
                  final key = switch (action['key']) {
                    'ArrowUp' => LogicalKeyboardKey.arrowUp,
                    'ArrowDown' => LogicalKeyboardKey.arrowDown,
                    _ => LogicalKeyboardKey.keyX,
                  };
                  await tester.sendKeyEvent(key);
                } else {
                  await tapText(tester, node.text.trim());
                }
                await tester.pumpAndSettle();
              }
              await check(action['id'] as String);
            }
            await tester.pumpWidget(const SizedBox.shrink());
          }
          await tester.runAsync(
            () =>
                File(
                  'build/parity/html-text-fields-native-${brightness.name}-$width.json',
                ).writeAsString(
                  const JsonEncoder.withIndent('  ').convert(observations),
                ),
          );
        },
      );
    }
  }
}
