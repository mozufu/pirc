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
import 'package:pirc_render/src/html_select.dart';
import 'package:pirc_render/src/native_markdown.dart';
import '../../test/live_test.dart' show theme;
import '../../test/native_html_test.dart' show tapText;
import 'capture_fonts.dart';

void main() {
  final fixture =
      jsonDecode(
            File(
              '../../fixtures/mobile-parity/html-select.json',
            ).readAsStringSync(),
          )
          as Map;
  final expected =
      jsonDecode(
            File(
              '../../fixtures/mobile-parity/html-select-expected.json',
            ).readAsStringSync(),
          )
          as Map;
  for (final brightness in Brightness.values) {
    for (final width in fixture['widths'] as List) {
      testWidgets(
        'HTML select ${brightness.name} $width browser behavior and capture',
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

          NativeHtmlSelectWidget field(dom.Element element) {
            for (final widget in tester.widgetList<NativeHtmlSelectWidget>(
              find.byType(NativeHtmlSelectWidget),
            )) {
              if (widget.state.resolveControl(element)?.key ==
                  widget.control.key) {
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
                final descriptor = native.control;
                expect(
                  state.valueFor(descriptor.key),
                  control['value'],
                  reason: '${item['id']} $phase ${control['id']}',
                );
                expect(
                  state.selectedIndices(descriptor.key),
                  control['state']['selectedIndices'],
                );
                expect(descriptor.multiple, control['state']['multiple']);
                expect(descriptor.size, control['state']['size']);
                final groups = control['groups'] as List;
                expect(
                  descriptor.groups.map((g) => g.label).toList(),
                  groups.map((g) => g['label']).toList(),
                );
                expect(
                  descriptor.groups.map((g) => g.beforeOption).toList(),
                  groups.map((g) => g['beforeOption']).toList(),
                );
                if (descriptor.multiple || descriptor.size > 1) {
                  for (final label
                      in descriptor.groups.map((g) => g.label).toSet()) {
                    expect(
                      find.descendant(
                        of: find.byWidget(native),
                        matching: find.text(label),
                      ),
                      findsNWidgets(
                        descriptor.groups.where((g) => g.label == label).length,
                      ),
                    );
                  }
                }
                final options = control['options'] as List;
                expect(descriptor.options.length, options.length);
                for (var i = 0; i < options.length; i++) {
                  expect(descriptor.options[i].value, options[i]['value']);
                  expect(descriptor.options[i].label, options[i]['label']);
                  expect(
                    descriptor.options[i].disabled,
                    options[i]['disabled'],
                    reason:
                        '${item['id']} $phase ${control['id']} option $i disabled',
                  );
                }
                expect(descriptor.disabled, control['state']['disabled']);
                expect(descriptor.label, control['accessibleName']);
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
                    'build/parity/html-select-native-${brightness.name}-$width-${item['id']}-$phase.png',
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
                if (action['mode'] == 'touch-option') {
                  final widget = field(node);
                  final option = widget.control.options[action['index'] as int];
                  final target = find.descendant(
                    of: find.byWidget(widget),
                    matching: find.text(option.label),
                  );
                  await tester.ensureVisible(target);
                  await tester.tap(target);
                } else if (action['mode'] == 'select') {
                  final widget = field(node);
                  final values = (action['values'] as List).cast<String>();
                  if (widget.control.multiple) {
                    for (final option in widget.control.options) {
                      widget.state.select(
                        widget.control.key,
                        option.index,
                        selected: values.contains(option.value),
                      );
                    }
                  } else {
                    final option = widget.control.options.firstWhere(
                      (o) => values.contains(o.value),
                    );
                    widget.state.select(widget.control.key, option.index);
                  }
                } else if (action['mode'] == 'dom-click') {
                  // Browser HTMLElement.click() has no pointer-down blur.
                  for (final widget
                      in tester.widgetList<NativeHtmlSelectWidget>(
                        find.byType(NativeHtmlSelectWidget),
                      )) {
                    if (widget.state.resolveLabel(node) != null) {
                      widget.state.activateLabel(node);
                      break;
                    }
                  }
                } else if (action['mode'] == 'key') {
                  final widget = field(node);
                  widget.state.focusNodeFor(widget.control.key).requestFocus();
                  await tester.pump();
                  if (action['key'] == 'Shift+End') {
                    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
                  }
                  await tester.sendKeyEvent(
                    action['key'] == 'Home'
                        ? LogicalKeyboardKey.home
                        : LogicalKeyboardKey.end,
                  );
                  if (action['key'] == 'Shift+End') {
                    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
                  }
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
                  'build/parity/html-select-native-${brightness.name}-$width.json',
                ).writeAsString(
                  const JsonEncoder.withIndent('  ').convert(observations),
                ),
          );
        },
      );
    }
  }
}
