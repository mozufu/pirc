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
import 'package:pirc_render/src/html_buttons.dart';
import 'package:pirc_render/src/html_controls.dart';
import 'package:pirc_render/src/html_select.dart';
import 'package:pirc_render/src/html_text_fields.dart';
import 'package:pirc_render/src/native_markdown.dart';
import '../../test/live_test.dart' show theme;
import '../../test/native_html_test.dart' show tapText;
import 'capture_fonts.dart';

void main() {
  final fixture =
      jsonDecode(
            File(
              '../../fixtures/mobile-parity/html-form-actions.json',
            ).readAsStringSync(),
          )
          as Map;
  final expected =
      jsonDecode(
            File(
              '../../fixtures/mobile-parity/html-form-actions-expected.json',
            ).readAsStringSync(),
          )
          as Map;
  for (final brightness in Brightness.values) {
    for (final width in fixture['widths'] as List) {
      testWidgets('HTML form actions ${brightness.name} $width', (
        tester,
      ) async {
        await tester.runAsync(loadParityFonts);
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(
          (width as num).toDouble(),
          (fixture['height'] as num).toDouble(),
        );
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final boundary = GlobalKey();
        final measured = <Map<String, Object?>>[];
        final references =
            (expected['themes'][brightness.name]['widths'] as List).singleWhere(
                  (row) => row['width'] == width,
                )['cases']
                as List;
        final writes = <String>[];
        var rejectClipboard = false;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              writes.add(call.arguments['text'] as String);
              if (rejectClipboard) throw PlatformException(code: 'denied');
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        dom.Element node(String selector) {
          for (final widget in tester.widgetList<HtmlWidget>(
            find.byType(HtmlWidget),
          )) {
            final element = html
                .parseFragment(widget.html)
                .querySelector(selector);
            if (element != null) return element;
          }
          throw StateError('Missing selector $selector');
        }

        Widget control(dom.Element element) {
          for (final w in tester.widgetList<NativeHtmlTextFieldWidget>(
            find.byType(NativeHtmlTextFieldWidget),
          )) {
            if (w.state.resolveControl(element)?.key == w.field.key) return w;
          }
          for (final w in tester.widgetList<NativeHtmlControlWidget>(
            find.byType(NativeHtmlControlWidget),
          )) {
            if (w.state.resolveControl(element)?.key == w.control.key) return w;
          }
          for (final w in tester.widgetList<NativeHtmlSelectWidget>(
            find.byType(NativeHtmlSelectWidget),
          )) {
            if (w.state.resolveControl(element)?.key == w.control.key) return w;
          }
          for (final w in tester.widgetList<NativeHtmlButtonWidget>(
            find.byType(NativeHtmlButtonWidget),
          )) {
            if (w.state.resolveControl(element)?.key == w.button.key) return w;
          }
          throw StateError('Missing native control ${element.outerHtml}');
        }

        Map<String, Object?> state(Widget widget, dom.Element element) {
          if (widget is NativeHtmlTextFieldWidget) {
            return {
              'id': element.id,
              'value': widget.state.valueFor(widget.field.key),
              'disabled': widget.field.disabled,
              'focused': widget.state.focusNodeFor(widget.field.key).hasFocus,
            };
          }
          if (widget is NativeHtmlControlWidget) {
            return {
              'id': element.id,
              'checked': widget.state.isChecked(widget.control.key),
              'value': element.attributes['value'] ?? 'on',
              'disabled': widget.control.disabled,
              'focused':
                  tester
                      .widget<Focus>(
                        find
                            .descendant(
                              of: find.byWidget(widget),
                              matching: find.byType(Focus),
                            )
                            .first,
                      )
                      .focusNode
                      ?.hasFocus ??
                  false,
            };
          }
          if (widget is NativeHtmlSelectWidget) {
            return {
              'id': element.id,
              'value': widget.state.valueFor(widget.control.key),
              'selectedIndices': widget.state.selectedIndices(
                widget.control.key,
              ),
              'disabled': widget.control.disabled,
              'focused': widget.state.focusNodeFor(widget.control.key).hasFocus,
            };
          }
          final button = widget as NativeHtmlButtonWidget;
          return {
            'id': element.id,
            'text': button.state.displayText(button.button.key) ?? element.text,
            'value': element.attributes['value'] ?? '',
            'accessibleName': button.button.contentName
                ? button.state.displayText(button.button.key) ??
                      button.button.label
                : button.button.label,
            'disabled': button.button.disabled,
            'focused': button.state.focusNodeFor(button.button.key).hasFocus,
          };
        }

        var mount = 0;
        for (final item in fixture['cases'] as List) {
          writes.clear();
          rejectClipboard = false;
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
                          key: ValueKey(mount++),
                          source: item['source'] as String,
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
          final phases =
              references.singleWhere(
                    (row) => row['id'] == item['id'],
                  )['observations']
                  as List;
          Future<void> check(int index) async {
            final reference = phases[index] as Map;
            final observations = <Map<String, Object?>>[];
            for (final row in [
              ...reference['controls'] as List,
              ...reference['buttons'] as List,
            ]) {
              final element = node('#${row['id']}');
              final widget = control(element);
              final snapshot = state(widget, element);
              for (final key in [
                'value',
                'checked',
                'disabled',
                'accessibleName',
                'selectedIndices',
              ]) {
                if (snapshot.containsKey(key) && row.containsKey(key)) {
                  expect(
                    snapshot[key],
                    row[key],
                    reason:
                        '${item['id']} ${reference['phase']} ${row['id']} $key',
                  );
                }
              }
              if (widget is NativeHtmlButtonWidget && !widget.button.input) {
                expect(
                  snapshot['text'],
                  row['textContent'],
                  reason: 'button content ${row['id']} ${reference['phase']}',
                );
              }
              // DOM getBoundingClientRect excludes control margins. Measure
              // the painted checkbox/radio border box, not its flow wrapper.
              final boxFinder = widget is NativeHtmlControlWidget
                  ? find
                        .descendant(
                          of: find.byWidget(widget),
                          matching: find.byType(CustomPaint),
                        )
                        .first
                  : find.byWidget(widget);
              final rect = tester.getRect(boxFinder);
              final box = row['box'] as Map;
              observations.add({
                ...snapshot,
                'box': {
                  'x': rect.left,
                  'y': rect.top,
                  'width': rect.width,
                  'height': rect.height,
                },
                'delta': {
                  'x': rect.left - (box['x'] as num),
                  'y': rect.top - (box['y'] as num),
                  'width': rect.width - (box['width'] as num),
                  'height': rect.height - (box['height'] as num),
                },
                'focusMatches':
                    snapshot['focused'] ==
                    (row['focused'] ??
                        ((reference['activeElement'] as Map?)?['id'] ==
                            row['id'])),
              });
            }
            expect(writes, reference['clipboardWrites']);
            expect(tester.takeException(), isNull);
            measured.add({
              'case': item['id'],
              'phase': reference['phase'],
              'actionIndex': reference['actionIndex'],
              'controls': observations,
              'clipboardWrites': List<String>.of(writes),
            });
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
                  'build/parity/html-form-actions-native-${brightness.name}-$width-${item['id']}-$index.png',
                );
                await output.parent.create(recursive: true);
                await output.writeAsBytes(bytes!.buffer.asUint8List());
              } finally {
                image.dispose();
              }
            });
          }

          await check(0);
          final actions = item['actions'] as List;
          for (var i = 0; i < actions.length; i++) {
            final action = actions[i] as Map;
            final mode = action['mode'];
            if (mode == 'clipboard') {
              rejectClipboard = action['result'] == 'reject';
            } else if (mode == 'wait') {
              await tester.pump(Duration(milliseconds: action['ms'] as int));
            } else {
              final element = node(action['selector'] as String);
              if (mode == 'click' && element.localName == 'label') {
                await tapText(tester, element.text);
              } else {
                final widget = control(element);
                if (mode == 'setValue') {
                  final field = widget as NativeHtmlTextFieldWidget;
                  field.state.controllerFor(field.field.key).text =
                      action['value'] as String;
                } else if (mode == 'setChecked') {
                  final checkable = widget as NativeHtmlControlWidget;
                  if (checkable.state.isChecked(checkable.control.key) !=
                      action['value']) {
                    checkable.state.activateControl(checkable.control.key);
                  }
                } else if (mode == 'select') {
                  final select = widget as NativeHtmlSelectWidget;
                  final option = select.control.options.firstWhere(
                    (o) => o.value == action['value'],
                  );
                  select.state.select(select.control.key, option.index);
                } else if (mode == 'domClick') {
                  final button = widget as NativeHtmlButtonWidget;
                  await button.state.activate(button.button.key);
                } else if (mode == 'key') {
                  final button = widget as NativeHtmlButtonWidget;
                  button.state.focusNodeFor(button.button.key).requestFocus();
                  await tester.pump();
                  await tester.sendKeyEvent(
                    action['key'] == 'Space'
                        ? LogicalKeyboardKey.space
                        : LogicalKeyboardKey.enter,
                  );
                } else {
                  final finder = find.byWidget(widget);
                  await tester.ensureVisible(finder);
                  await tester.tap(finder);
                }
              }
            }
            await tester.pump();
            await check(i + 1);
          }
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(seconds: 2));
        }
        await tester.runAsync(
          () => File(
            'build/parity/html-form-actions-native-${brightness.name}-$width.json',
          ).writeAsString(const JsonEncoder.withIndent('  ').convert(measured)),
        );
      });
    }
  }
}
