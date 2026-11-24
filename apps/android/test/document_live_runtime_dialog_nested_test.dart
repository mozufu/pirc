import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/dom.dart' as dom;
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/document_scripts.dart';
import 'package:pirc_render/src/html_buttons.dart';
import 'package:pirc_render/src/html_document_box.dart';
import 'package:pirc_render/src/html_form_submission.dart';

import 'document_navigation_widget_test.dart' show response;
import 'live_test.dart' show theme;
import 'support/document_vm_gateway.dart';

void main() {
  testWidgets('nested native modals match Chromium paint and bounded touch input', (
    t,
  ) async {
    final fixture =
        jsonDecode(
              File(
                'tool/parity/fixtures/document-dialog-nested-chromium153.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    const markup = '''<!doctype html><html><head><style>
body { background:white; }
dialog { background:white; width:160px; height:120px; }
#first { z-index:9999; } #second { z-index:-1; }
</style></head><body>
<button id="outside">Outside</button>
<dialog id="first" closedby="any"><button id="one">One</button></dialog>
<dialog id="second" closedby="any"><button id="two">Two</button></dialog>
<script>
window.clicks={outside:0,one:0,two:0};
window.backdropEvents=[];
for(const type of ['pointerdown','pointerup','mousedown','mouseup','click',
  'focus','blur','focusin','focusout','cancel'])
  document.addEventListener(type,event=>backdropEvents.push({
    type,target:event.target.id||event.target.tagName.toLowerCase(),
    activeElement:document.activeElement.id,
    trusted:event.isTrusted,
  }),true);
for(const id of Object.keys(clicks))
  document.getElementById(id).addEventListener('click',()=>clicks[id]++);
document.getElementById('first').showModal();
document.getElementById('second').showModal();
</script></body></html>''';
    final g = (await t.runAsync(DocumentVmGateway.start))!
      ..responses.add({
        ...response('/nested', markup),
        'finalUrl': 'https://dialog-nested.example/nested',
      });
    final windows = NativeDocumentWindows(g);
    final window = windows.target(
      'dialog-nested',
      null,
      sourceUrl: 'https://dialog-nested.example/',
    );
    await window.load(
      const NativeHtmlFormRequest(url: '/nested', method: 'GET', target: ''),
      baseUrl: window.sourceUrl,
    );
    windows.select(window);
    final doc = window.currentDocument!;
    doc.scripts = NativeDocumentScripts(
      g,
      loadRuntime: () async =>
          File('assets/document-script-runtime.js').readAsStringSync(),
    );
    final paintKey = GlobalKey();
    Finder button(String label) => find.byWidgetPredicate(
      (w) => w is NativeHtmlButtonWidget && w.button.label == label,
    );
    Finder dialog(String id) => find.byWidgetPredicate(
      (w) =>
          w is NativeDocumentBox &&
          w.geometryOwner is dom.Element &&
          (w.geometryOwner as dom.Element).id == id,
    );
    Future<void> expectState(String key) async {
      final expected = (fixture['touch'] as Map)[key] as Map;
      await driveDocumentVm(
        t,
        () =>
            doc.scripts!.modalDialogIds.length ==
            (expected['modalIds'] as List).length,
        reason: key,
        diagnostic: () =>
            'modals=${doc.scripts!.modalDialogIds} diagnostics=${doc.scripts!.diagnostics}',
      );
      String? focus;
      Map<String, dynamic> clicks = {};
      for (var i = 0; i < 30; i++) {
        final observed =
            jsonDecode(
                  await t.runAsync(
                        () => g.inspect(
                          'JSON.stringify([document.activeElement.id, window.clicks])',
                        ),
                      )
                      as String,
                )
                as List;
        focus = observed[0] as String;
        clicks = Map<String, dynamic>.from(observed[1] as Map);
        if (focus == expected['activeElement'] &&
            (expected['clicks'] as Map).entries.every(
              (entry) => clicks[entry.key] == entry.value,
            )) {
          break;
        }
        await t.pump(const Duration(milliseconds: 16));
      }
      expect(focus, expected['activeElement'], reason: '$key touch focus');
      expect(clicks, expected['clicks'], reason: '$key clicks');
    }

    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final semantics = t.ensureSemantics();
    try {
      await t.pumpWidget(
        RepaintBoundary(
          key: paintKey,
          child: MaterialApp(
            theme: theme.build(Brightness.light),
            home: NativeDocumentWorkspace(windows: windows),
          ),
        ),
      );
      await driveDocumentVm(
        t,
        () =>
            doc.scripts!.ready &&
            dialog('first').evaluate().length == 1 &&
            dialog('second').evaluate().length == 1,
        reason: 'nested dialogs painted',
        diagnostic: () =>
            'modals=${doc.scripts!.modalDialogIds} '
            'diagnostics=${doc.scripts!.diagnostics}',
      );
      await expectState('initial');
      String semanticTree() {
        // Widget tests attach their view to the legacy child pipeline owner.
        // ignore: deprecated_member_use
        return t.binding.pipelineOwner.semanticsOwner?.rootSemanticsNode
                ?.toStringDeep() ??
            '';
      }

      expect(semanticTree(), contains('label: "Two"'));
      expect(semanticTree(), isNot(contains('label: "One"')));
      expect(semanticTree(), isNot(contains('label: "Outside"')));
      for (final id in ['one', 'outside']) {
        expect(
          await t.runAsync(
            () => g.inspect(
              "(document.getElementById('$id').focus(), document.activeElement.id)",
            ),
          ),
          (fixture['blockedScriptFocus'] as Map)[id == 'one'
              ? 'afterLower'
              : 'afterOutside'],
          reason: 'script focus must not leave the top modal',
        );
      }
      for (var i = 0; i < 2; i++) {
        await t.sendKeyEvent(LogicalKeyboardKey.tab);
        await t.pump();
        final upper = t.widget<NativeHtmlButtonWidget>(button('Two'));
        expect(
          upper.state.focusNodeFor(upper.button.key).hasPrimaryFocus,
          isTrue,
          reason: 'Tab must stay in the top modal',
        );
        for (final label in ['One', 'Outside']) {
          final lower = t.widget<NativeHtmlButtonWidget>(button(label));
          expect(
            lower.state.focusNodeFor(lower.button.key).hasFocus,
            isFalse,
            reason: '$label must remain inert while the top modal is open',
          );
        }
      }
      await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await t.pump();
      final topControl = t.widget<NativeHtmlButtonWidget>(button('Two'));
      expect(
        topControl.state.focusNodeFor(topControl.button.key).hasPrimaryFocus,
        isTrue,
        reason: 'Shift+Tab must stay in the top modal',
      );
      final bitmap = (await t.runAsync(
        () => t
            .renderObject<RenderRepaintBoundary>(find.byKey(paintKey))
            .toImage(pixelRatio: 1),
      ))!;
      try {
        final rgba = (await t.runAsync(
          () => bitmap.toByteData(format: ui.ImageByteFormat.rawStraightRgba),
        ))!;
        final offset = (200 * bitmap.width + 20) * 4;
        final expected = fixture['backdropPixel'] as List;
        for (var channel = 0; channel < 4; channel++) {
          expect(
            rgba.getUint8(offset + channel),
            closeTo(expected[channel] as num, 2),
            reason: 'Chromium 153 two-layer backdrop channel $channel',
          );
        }
      } finally {
        bitmap.dispose();
      }

      await t.tapAt(t.getRect(button('One')).center);
      await expectState('blockedFirstClick');
      await t.runAsync(() => g.inspect('(backdropEvents.length=0)'));
      await t.tapAt(const Offset(20, 200));
      await expectState('afterTopBackdrop');
      final observedBackdropEvents =
          jsonDecode(
                await t.runAsync(
                      () => g.inspect('JSON.stringify(backdropEvents)'),
                    )
                    as String,
              )
              as List;
      final oracleBackdropEvents =
          (fixture['touch'] as Map)['topBackdropEvents'] as List;
      const comparableEvents = {
        'pointerdown',
        'pointerup',
        'mousedown',
        'mouseup',
        'click',
        'focus',
        'blur',
        'focusin',
        'focusout',
        'cancel',
      };
      expect(
        observedBackdropEvents
            .map(
              (event) => {
                'type': (event as Map)['type'],
                'target': event['target'],
                'activeElement': event['activeElement'],
              },
            )
            .toList(),
        oracleBackdropEvents
            .where((event) => comparableEvents.contains((event as Map)['type']))
            .map(
              (event) => {
                'type': (event as Map)['type'],
                'target': event['target'],
                'activeElement': event['activeElement'],
              },
            )
            .toList(),
        reason: 'touch compatibility mouse events retarget to remaining dialog',
      );
      expect(
        observedBackdropEvents
            .where(
              (event) => const {
                'mousedown',
                'mouseup',
                'click',
              }.contains((event as Map)['type']),
            )
            .every((event) => (event as Map)['trusted'] == true),
        isTrue,
        reason: 'retargeted compatibility mouse events are trusted',
      );
      expect(dialog('first'), findsOneWidget);
      expect(dialog('second'), findsNothing);
      expect(semanticTree(), contains('label: "One"'));
      expect(semanticTree(), isNot(contains('label: "Two"')));
      expect(semanticTree(), isNot(contains('label: "Outside"')));
      final lowerControl = t.widget<NativeHtmlButtonWidget>(button('One'));
      final dialogFocusId = await t.runAsync(
        () => g.inspect(
          'document.getElementById("first").getAttribute("data-pirc-script-id")',
        ),
      );
      await driveDocumentVm(
        t,
        () =>
            FocusManager.instance.primaryFocus?.debugLabel ==
            'HTML script focus $dialogFocusId',
        reason: 'retarget touch mouse focus to remaining dialog',
      );
      expect(
        lowerControl.state.focusNodeFor(lowerControl.button.key).hasFocus,
        isFalse,
        reason: 'touch mousedown focuses the dialog before Tab',
      );
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pump();
      expect(
        lowerControl.state
            .focusNodeFor(lowerControl.button.key)
            .hasPrimaryFocus,
        isTrue,
        reason: 'Tab must stay in the remaining modal',
      );
      await t.tap(button('One'));
      await expectState('afterFirstClick');
      await t.runAsync(() => g.inspect('(backdropEvents.length=0)'));
      await t.tapAt(const Offset(20, 200));
      await expectState('afterBothBackdrops');
      final observedFinalEvents =
          jsonDecode(
                await t.runAsync(
                      () => g.inspect('JSON.stringify(backdropEvents)'),
                    )
                    as String,
              )
              as List;
      final oracleFinalEvents =
          (fixture['touch'] as Map)['finalBackdropEvents'] as List;
      expect(
        observedFinalEvents
            .map(
              (event) => {
                'type': (event as Map)['type'],
                'target': event['target'],
                'activeElement': event['activeElement'],
              },
            )
            .toList(),
        oracleFinalEvents
            .where((event) => comparableEvents.contains((event as Map)['type']))
            .map(
              (event) => {
                'type': (event as Map)['type'],
                'target': event['target'],
                'activeElement': event['activeElement'],
              },
            )
            .toList(),
        reason: 'final backdrop touch retargets blank area to document root',
      );
      expect(semanticTree(), contains('label: "Outside"'));
      await t.runAsync(
        () => g.inspect(
          '(document.getElementById("first").showModal(), document.getElementById("first").open)',
        ),
      );
      await driveDocumentVm(
        t,
        () => doc.scripts!.modalDialogIds.length == 1,
        reason: 'reopen modal over underlying button',
      );
      await t.runAsync(() => g.inspect('(backdropEvents.length=0)'));
      await t.tapAt(t.getRect(button('Outside')).center);
      await expectState('afterUnderlyingButtonBackdrop');
      final underlyingEvents =
          jsonDecode(
                await t.runAsync(
                      () => g.inspect('JSON.stringify(backdropEvents)'),
                    )
                    as String,
              )
              as List;
      final underlyingOracle =
          (fixture['touch'] as Map)['underlyingButtonBackdropEvents'] as List;
      expect(
        underlyingEvents
            .map(
              (event) => {
                'type': (event as Map)['type'],
                'target': event['target'],
                'activeElement': event['activeElement'],
              },
            )
            .toList(),
        underlyingOracle
            .where((event) => comparableEvents.contains((event as Map)['type']))
            .map(
              (event) => {
                'type': (event as Map)['type'],
                'target': event['target'],
                'activeElement': event['activeElement'],
              },
            )
            .toList(),
        reason: 'last modal retargets touch click to exposed button',
      );
      for (var i = 0; i < 30; i++) {
        if (await t.runAsync(() => g.inspect('window.clicks.outside')) == 1) {
          break;
        }
        await t.pump(const Duration(milliseconds: 16));
      }
      expect(await t.runAsync(() => g.inspect('window.clicks.outside')), 1);
      await t.runAsync(
        () => g.inspect('''(() => {
          const first = document.getElementById('first');
          first.showModal();
          first.addEventListener('pointerdown', event => event.preventDefault(), {once:true});
          return first.open;
        })()'''),
      );
      await driveDocumentVm(
        t,
        () => doc.scripts!.modalDialogIds.length == 1,
        reason: 'reopen modal for canceled pointerdown',
      );
      await driveDocumentVm(
        t,
        () => t
            .widget<NativeHtmlButtonWidget>(button('One'))
            .state
            .focusNodeFor(
              t.widget<NativeHtmlButtonWidget>(button('One')).button.key,
            )
            .hasPrimaryFocus,
        reason: 'reopened modal focus settles before canceled pointerdown',
      );
      await t.runAsync(() => g.inspect('(backdropEvents.length=0)'));
      await t.tapAt(const Offset(20, 200));
      await expectState('afterPreventedBackdrop');
      for (var i = 0; i < 30; i++) {
        if (await t.runAsync(
              () => g.inspect(
                'backdropEvents.some(event => event.type === "click" && event.target === "html")',
              ),
            ) ==
            true) {
          break;
        }
        await t.pump(const Duration(milliseconds: 16));
      }
      final preventedEvents =
          jsonDecode(
                await t.runAsync(
                      () => g.inspect('JSON.stringify(backdropEvents)'),
                    )
                    as String,
              )
              as List;
      final preventedOracle =
          (fixture['touch'] as Map)['preventedBackdropEvents'] as List;
      expect(
        preventedEvents
            .skipWhile((event) => (event as Map)['type'] != 'pointerdown')
            .map(
              (event) => {
                'type': (event as Map)['type'],
                'target': event['target'],
                'activeElement': event['activeElement'],
              },
            )
            .toList(),
        preventedOracle
            .where((event) => comparableEvents.contains((event as Map)['type']))
            .map(
              (event) => {
                'type': (event as Map)['type'],
                'target': event['target'],
                'activeElement': event['activeElement'],
              },
            )
            .toList(),
        reason: 'prevented pointerdown suppresses mouse events but keeps click',
      );
      expect(t.takeException(), isNull);
    } finally {
      semantics.dispose();
      await t.pumpWidget(const SizedBox.shrink());
      final scripts = doc.scripts;
      windows.dispose();
      var closed = false;
      (scripts?.closed ?? Future<void>.value()).then((_) => closed = true);
      await driveDocumentVm(
        t,
        () => closed && g.closes == g.opens,
        reason: 'retire nested document',
      );
      await t.runAsync(g.close);
      await t.pump();
    }
  });
}
