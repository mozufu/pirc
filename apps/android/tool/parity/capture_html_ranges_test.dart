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
import 'package:pirc_render/src/html_range.dart';
import 'package:pirc_render/src/native_markdown.dart';

import '../../test/live_test.dart' show theme;
import 'capture_fonts.dart';

void main() {
  final fixture =
      jsonDecode(
            File(
              '../../fixtures/mobile-parity/html-ranges.json',
            ).readAsStringSync(),
          )
          as Map;
  final expected =
      jsonDecode(
            File(
              '../../fixtures/mobile-parity/html-ranges-expected.json',
            ).readAsStringSync(),
          )
          as Map;

  for (final brightness in Brightness.values) {
    for (final width in fixture['widths'] as List) {
      testWidgets(
        'native HTML ranges ${brightness.name} $width browser behavior and capture',
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

          NativeHtmlRangeWidget rangeWidget(dom.Element element) {
            for (final widget in tester.widgetList<NativeHtmlRangeWidget>(
              find.byType(NativeHtmlRangeWidget),
            )) {
              final resolved = widget.state.resolveControl(element);
              if (resolved?.key == widget.control.key) return widget;
            }
            throw StateError('Missing native range ${element.outerHtml}');
          }

          LogicalKeyboardKey logicalKey(String value) => switch (value) {
            'ArrowUp' => LogicalKeyboardKey.arrowUp,
            'ArrowDown' => LogicalKeyboardKey.arrowDown,
            'ArrowLeft' => LogicalKeyboardKey.arrowLeft,
            'ArrowRight' => LogicalKeyboardKey.arrowRight,
            'PageUp' => LogicalKeyboardKey.pageUp,
            'PageDown' => LogicalKeyboardKey.pageDown,
            'Home' => LogicalKeyboardKey.home,
            'End' => LogicalKeyboardKey.end,
            _ => throw StateError('Unknown range key $value'),
          };

          Future<void> capture(String caseId, String phase, Map web) async {
            final measured = <Map<String, Object?>>[];
            for (final webControl in web['controls'] as List) {
              final id = webControl['id'] as String?;
              if (id == null) continue;
              final node = element('input[type="range"][id="$id"]');
              final widget = rangeWidget(node);
              final state = widget.state;
              final descriptor = widget.control;
              final value = state.valueFor(descriptor.key);
              if (phase == 'touch-drag') {
                final webValue = double.parse(webControl['value'] as String);
                final min = double.parse(descriptor.effectiveMin);
                final max = double.parse(descriptor.effectiveMax);
                final tolerance = descriptor.stepAny
                    ? (max - min) / 100
                    : double.parse(descriptor.effectiveStep!);
                expect(
                  (double.parse(value) - webValue).abs(),
                  lessThanOrEqualTo(tolerance + 1e-9),
                  reason:
                      '$caseId $phase range#$id differs by more than one step',
                );
              } else {
                expect(
                  value,
                  webControl['value'],
                  reason: '$caseId $phase range#$id value',
                );
              }
              expect(descriptor.disabled, webControl['state']['disabled']);
              expect(descriptor.readOnly, webControl['state']['readOnly']);
              expect(descriptor.required, webControl['state']['required']);
              expect(
                descriptor.willValidate,
                webControl['state']['willValidate'],
              );
              expect(descriptor.min ?? '', webControl['min']);
              expect(descriptor.max ?? '', webControl['max']);
              expect(descriptor.step ?? '', webControl['step']);
              expect(descriptor.label, webControl['accessibility']['name']);
              expect(
                descriptor.hint,
                webControl['accessibility']['description'],
              );
              expect(
                state.focusNodeFor(descriptor.key).hasFocus,
                webControl['focused'],
                reason: '$caseId $phase range#$id focus',
              );

              final semantics = tester
                  .getSemantics(
                    find.byKey(ValueKey('native-html-range-${descriptor.key}')),
                  )
                  .getSemanticsData();
              expect(semantics.flagsCollection.isSlider, isTrue);
              expect(semantics.label, descriptor.label);
              expect(semantics.hint, descriptor.hint);
              expect(semantics.value, value);
              expect(semantics.minValue, descriptor.effectiveMin);
              expect(semantics.maxValue, descriptor.effectiveMax);
              expect(
                semantics.hasAction(SemanticsAction.increase),
                !descriptor.disabled,
              );
              expect(
                semantics.hasAction(SemanticsAction.decrease),
                !descriptor.disabled,
              );

              final box = tester.getRect(
                find.byKey(ValueKey('native-html-range-${descriptor.key}')),
              );
              measured.add({
                'id': id,
                'value': value,
                'focused': state.focusNodeFor(descriptor.key).hasFocus,
                'disabled': descriptor.disabled,
                'readOnlyAttribute': descriptor.readOnly,
                'willValidate': descriptor.willValidate,
                'required': descriptor.required,
                'attributes': {
                  'min': descriptor.min,
                  'max': descriptor.max,
                  'step': descriptor.step,
                },
                'range': {
                  'min': descriptor.effectiveMin,
                  'max': descriptor.effectiveMax,
                  'stepBase': descriptor.stepBase,
                  'step': descriptor.effectiveStep,
                  'stepAny': descriptor.stepAny,
                },
                'label': descriptor.label,
                'hint': descriptor.hint,
                'semantics': {
                  'slider': semantics.flagsCollection.isSlider,
                  'label': semantics.label,
                  'hint': semantics.hint,
                  'value': semantics.value,
                  'minValue': semantics.minValue,
                  'maxValue': semantics.maxValue,
                  'hasIncrease': semantics.hasAction(SemanticsAction.increase),
                  'hasDecrease': semantics.hasAction(SemanticsAction.decrease),
                },
                'box': {
                  'x': box.left,
                  'y': box.top,
                  'width': box.width,
                  'height': box.height,
                  'deltaX': box.left - (webControl['box']['x'] as num),
                  'deltaY': box.top - (webControl['box']['y'] as num),
                  'deltaWidth': box.width - (webControl['box']['width'] as num),
                  'deltaHeight':
                      box.height - (webControl['box']['height'] as num),
                },
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
                  'build/parity/html-ranges-native-${brightness.name}-$width-$caseId-$phase.png',
                );
                await output.parent.create(recursive: true);
                await output.writeAsBytes(bytes!.buffer.asUint8List());
              } finally {
                image.dispose();
              }
            });
            observations.add({
              'case': caseId,
              'phase': phase,
              'controls': measured,
            });
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
              await capture(item['id'] as String, phase, web);
            }

            await check('initial');
            for (final action in item['actions'] as List) {
              if (action['kind'] == 'key' || action['kind'] == 'key-repeat') {
                final node = element(item['selector'] as String);
                final widget = rangeWidget(node);
                widget.state.focusControl(widget.control.key);
                await tester.pump();
                final key = logicalKey(action['key'] as String);
                if (action['kind'] == 'key-repeat') {
                  await tester.sendKeyDownEvent(key);
                  await tester.sendKeyRepeatEvent(key);
                  await tester.sendKeyUpEvent(key);
                } else {
                  await tester.sendKeyEvent(key);
                }
              } else if (action['kind'] == 'label-click') {
                final label = element(action['selector'] as String);
                for (final widget in tester.widgetList<NativeHtmlRangeWidget>(
                  find.byType(NativeHtmlRangeWidget),
                )) {
                  if (widget.state.resolveLabel(label) != null) {
                    widget.state.activateLabel(label);
                    break;
                  }
                }
              } else if (action['kind'] == 'touch-drag') {
                final node = element(item['selector'] as String);
                final widget = rangeWidget(node);
                final finder = find.byKey(
                  ValueKey('native-html-range-${widget.control.key}'),
                );
                final box = tester.getRect(finder);
                final fraction = (action['to'] as num).toDouble();
                final start = Offset(box.left + box.width / 2, box.center.dy);
                final end = Offset(
                  box.left + box.width * fraction,
                  box.center.dy,
                );
                await tester.dragFrom(start, end - start);
              } else {
                throw StateError('Unsupported range action ${action['kind']}');
              }
              await tester.pumpAndSettle();
              await check(action['id'] as String);
            }
            await tester.pumpWidget(const SizedBox.shrink());
          }

          await tester.runAsync(
            () =>
                File(
                  'build/parity/html-ranges-native-${brightness.name}-$width.json',
                ).writeAsString(
                  const JsonEncoder.withIndent('  ').convert(observations),
                ),
          );
        },
      );
    }
  }
}
