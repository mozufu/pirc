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
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await (FontLoader('sans-serif')..addFont(
          File(
            'tool/parity/vendor/canvas-text-fixture-font/Roboto-Regular.ttf',
          ).readAsBytes().then(ByteData.sublistView),
        ))
        .load();
  });
  for (final profile in [
    (390.0, 796.0, Brightness.light),
    (768.0, 976.0, Brightness.dark),
  ]) {
    testWidgets(
      'modal dialog ${profile.$1} ${profile.$3} blocks backdrop taps and restores the page',
      (t) async {
        const markup = '''<!doctype html><html><body>
<button id="outside">Outside</button>
<button id="open">Open</button>
<dialog id="dialog"><button id="inside">Inside</button></dialog>
<script>
window.outsideClicks = 0;
window.blockCancel = false;
window.cancelCount = 0;
window.backdropEvents = [];
document.getElementById('dialog').addEventListener('cancel', event => {
  backdropEvents.push('cancel');
  cancelCount++;
  if (blockCancel) event.preventDefault();
});
for (const type of ['pointerdown', 'pointerup', 'click']) {
  document.getElementById('dialog').addEventListener(type, () =>
    backdropEvents.push(type));
}
document.getElementById('outside').onclick = () => outsideClicks++;
document.getElementById('open').onclick = () =>
  document.getElementById('dialog').showModal();
document.getElementById('inside').onclick = () =>
  document.getElementById('dialog').close('done');
document.getElementById('dialog').showModal();
</script></body></html>''';
        final g = (await t.runAsync(DocumentVmGateway.start))!
          ..responses.add({
            ...response('/test', markup),
            'finalUrl': 'https://dialog-modal.example/test',
          });
        final windows = NativeDocumentWindows(g);
        final window = windows.target(
          'dialog-modal',
          null,
          sourceUrl: 'https://dialog-modal.example/',
        );
        await window.load(
          const NativeHtmlFormRequest(url: '/test', method: 'GET', target: ''),
          baseUrl: window.sourceUrl,
        );
        windows.select(window);
        final doc = window.currentDocument!;
        final paintKey = GlobalKey();
        doc.scripts = NativeDocumentScripts(
          g,
          loadRuntime: () async =>
              File('assets/document-script-runtime.js').readAsStringSync(),
        );
        Finder button(String label) => find.byWidgetPredicate(
          (w) => w is NativeHtmlButtonWidget && w.button.label == label,
        );
        final dialog = find.byWidgetPredicate(
          (w) =>
              w is NativeDocumentBox &&
              w.geometryOwner is dom.Element &&
              (w.geometryOwner as dom.Element).id == 'dialog',
        );
        t.view.physicalSize = Size(profile.$1, profile.$2 + 48);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.reset);
        try {
          await t.pumpWidget(
            RepaintBoundary(
              key: paintKey,
              child: MaterialApp(
                theme: theme.build(profile.$3),
                home: NativeDocumentWorkspace(windows: windows),
              ),
            ),
          );
          await driveDocumentVm(
            t,
            () => doc.scripts!.ready && dialog.evaluate().length == 1,
            reason: 'modal painted',
            diagnostic: () =>
                'ready=${doc.scripts!.ready} '
                'modal=${doc.scripts!.modalDialogIds} '
                'diagnostics=${doc.scripts!.diagnostics}',
          );
          final box = t.getRect(dialog);
          expect(box.center.dx, closeTo(profile.$1 / 2, 2));
          expect(box.center.dy, closeTo(48 + profile.$2 / 2, 2));
          expect(
            box.width,
            closeTo(89.671875, 0.2),
            reason: 'Chromium 153 with the same Roboto fixture',
          );
          expect(box.width, lessThan(profile.$1));
          expect(box.height, lessThan(profile.$2));
          final bitmap = (await t.runAsync(
            () => t
                .renderObject<RenderRepaintBoundary>(find.byKey(paintKey))
                .toImage(pixelRatio: 1),
          ))!;
          try {
            final rgba = (await t.runAsync(
              () =>
                  bitmap.toByteData(format: ui.ImageByteFormat.rawStraightRgba),
            ))!;
            final offset = (200 * bitmap.width + 20) * 4;
            for (var channel = 0; channel < 3; channel++) {
              expect(
                rgba.getUint8(offset + channel),
                inInclusiveRange(228, 231),
                reason: 'Chromium 153 uses a 10% black modal backdrop',
              );
            }
            expect(rgba.getUint8(offset + 3), 255);
          } finally {
            bitmap.dispose();
          }
          expect(
            await t.runAsync(() => g.inspect('document.activeElement.id')),
            'inside',
          );
          final outside = t.getRect(button('Outside'));
          await t.tapAt(outside.center);
          await t.pump();
          expect(await t.runAsync(() => g.inspect('outsideClicks')), 0);
          expect(dialog, findsOneWidget);
          await t.tap(button('Inside'));
          await driveDocumentVm(
            t,
            () => dialog.evaluate().isEmpty,
            reason: 'modal closed',
          );
          expect(
            await t.runAsync(
              () => g.inspect("document.getElementById('dialog').returnValue"),
            ),
            'done',
          );
          await t.tap(button('Outside'));
          for (var i = 0; i < 30; i++) {
            if (await t.runAsync(() => g.inspect('outsideClicks')) == 1) break;
            await t.pump(const Duration(milliseconds: 16));
          }
          expect(await t.runAsync(() => g.inspect('outsideClicks')), 1);
          await t.tap(button('Open'));
          await driveDocumentVm(
            t,
            () => dialog.evaluate().length == 1,
            reason: 'reopened for Escape',
          );
          await t.sendKeyEvent(LogicalKeyboardKey.tab);
          await t.pump();
          expect(
            await t.runAsync(() => g.inspect('document.activeElement.id')),
            'inside',
          );
          final insideControl = t.widget<NativeHtmlButtonWidget>(
            button('Inside'),
          );
          await driveDocumentVm(
            t,
            () => insideControl.state
                .focusNodeFor(insideControl.button.key)
                .hasPrimaryFocus,
            reason:
                'reopened modal native focus settles after touch compatibility events',
          );
          expect(
            insideControl.state
                .focusNodeFor(insideControl.button.key)
                .hasPrimaryFocus,
            isTrue,
            reason: 'Tab must remain in the top modal natively',
          );
          await t.sendKeyEvent(LogicalKeyboardKey.escape);
          await driveDocumentVm(
            t,
            () => dialog.evaluate().isEmpty,
            reason: 'Escape closed modal',
          );
          expect(t.takeException(), isNull, reason: 'after Escape');
          await t.tap(button('Open'));
          await t.pump();
          expect(t.takeException(), isNull, reason: 'after reopen tap');
          await driveDocumentVm(
            t,
            () => dialog.evaluate().length == 1,
            reason: 'reopened for Back',
          );
          await t.runAsync(() => g.inspect('window.blockCancel=true'));
          await t.binding.handlePopRoute();
          for (var i = 0; i < 30; i++) {
            if (await t.runAsync(() => g.inspect('cancelCount')) == 1) break;
            await t.pump(const Duration(milliseconds: 16));
          }
          expect(await t.runAsync(() => g.inspect('cancelCount')), 1);
          expect(dialog, findsOneWidget);
          expect(identical(window.currentDocument, doc), isTrue);
          await t.runAsync(() => g.inspect('window.blockCancel=false'));
          await t.binding.handlePopRoute();
          await driveDocumentVm(
            t,
            () => dialog.evaluate().isEmpty,
            reason: 'Back closed modal',
          );
          expect(identical(window.currentDocument, doc), isTrue);
          await t.runAsync(
            () => g.inspect(
              "(document.getElementById('dialog').setAttribute('closedby','any'),true)",
            ),
          );
          await t.tap(button('Open'));
          await driveDocumentVm(
            t,
            () => dialog.evaluate().length == 1,
            reason: 'reopened for light dismiss',
          );
          await t.runAsync(() => g.inspect('window.backdropEvents=[]'));
          await t.tapAt(const Offset(20, 200));
          await driveDocumentVm(
            t,
            () => dialog.evaluate().isEmpty,
            reason: 'backdrop light-dismissed modal',
          );
          for (var i = 0; i < 30; i++) {
            if (await t.runAsync(
                  () => g.inspect('JSON.stringify(backdropEvents)'),
                ) ==
                '["pointerdown","cancel","pointerup"]') {
              break;
            }
            await t.pump(const Duration(milliseconds: 16));
          }
          expect(
            await t.runAsync(() => g.inspect('JSON.stringify(backdropEvents)')),
            '["pointerdown","cancel","pointerup"]',
          );
          expect(await t.runAsync(() => g.inspect('outsideClicks')), 1);

          await t.tap(button('Open'));
          await driveDocumentVm(
            t,
            () => dialog.evaluate().length == 1,
            reason: 'reopened for canceled light dismiss',
          );
          await driveDocumentVm(
            t,
            () => !doc.scripts!.hasPendingPublication,
            reason: 'reopened dialog event publication settled',
          );
          await t.runAsync(() => g.inspect('window.blockCancel=true'));
          await t.runAsync(() => g.inspect('window.backdropEvents=[]'));
          final beforeCancel = await t.runAsync(() => g.inspect('cancelCount'));
          await t.tapAt(const Offset(20, 200));
          for (var i = 0; i < 30; i++) {
            if (await t.runAsync(() => g.inspect('cancelCount')) ==
                (beforeCancel as int) + 1) {
              break;
            }
            await t.pump(const Duration(milliseconds: 16));
          }
          expect(
            await t.runAsync(() => g.inspect('cancelCount')),
            (beforeCancel as int) + 1,
            reason: 'cancel listener received backdrop close request',
          );
          expect(dialog, findsOneWidget);
          for (var i = 0; i < 30; i++) {
            if (await t.runAsync(
                  () => g.inspect('JSON.stringify(backdropEvents)'),
                ) ==
                '["pointerdown","cancel","pointerup","click"]') {
              break;
            }
            await t.pump(const Duration(milliseconds: 16));
          }
          expect(
            await t.runAsync(() => g.inspect('JSON.stringify(backdropEvents)')),
            '["pointerdown","cancel","pointerup","click"]',
          );
          await t.runAsync(() => g.inspect('window.blockCancel=false'));
          await t.runAsync(
            () => g.inspect(
              "(document.getElementById('dialog').setAttribute('closedby','none'),true)",
            ),
          );
          final noCloseCount = await t.runAsync(() => g.inspect('cancelCount'));
          await t.runAsync(() => g.inspect('window.backdropEvents=[]'));
          await t.tapAt(const Offset(20, 200));
          for (var i = 0; i < 30; i++) {
            if (await t.runAsync(
                  () => g.inspect('JSON.stringify(backdropEvents)'),
                ) ==
                '["pointerdown","pointerup","click"]') {
              break;
            }
            await t.pump(const Duration(milliseconds: 16));
          }
          expect(
            await t.runAsync(() => g.inspect('JSON.stringify(backdropEvents)')),
            '["pointerdown","pointerup","click"]',
          );
          expect(dialog, findsOneWidget);
          expect(
            await t.runAsync(() => g.inspect('cancelCount')),
            noCloseCount,
          );
          expect(await t.runAsync(() => g.inspect('outsideClicks')), 1);
          await t.runAsync(
            () => g.inspect(
              "(document.getElementById('dialog').setAttribute('closedby','any'),true)",
            ),
          );
          await t.runAsync(() => g.inspect('window.backdropEvents=[]'));
          final mouse = await t.createGesture(kind: ui.PointerDeviceKind.mouse);
          await mouse.down(const Offset(20, 200));
          await mouse.up();
          await driveDocumentVm(
            t,
            () => dialog.evaluate().isEmpty,
            reason: 'mouse backdrop light-dismissed modal',
          );
          for (var i = 0; i < 30; i++) {
            if (await t.runAsync(
                  () => g.inspect('JSON.stringify(backdropEvents)'),
                ) ==
                '["pointerdown","cancel","pointerup","click"]') {
              break;
            }
            await t.pump(const Duration(milliseconds: 16));
          }
          expect(
            await t.runAsync(() => g.inspect('JSON.stringify(backdropEvents)')),
            '["pointerdown","cancel","pointerup","click"]',
          );
          expect(t.takeException(), isNull);
        } finally {
          await t.pumpWidget(const SizedBox.shrink());
          final scripts = doc.scripts;
          windows.dispose();
          var closed = false;
          (scripts?.closed ?? Future<void>.value()).then((_) => closed = true);
          await driveDocumentVm(
            t,
            () => closed && g.closes == g.opens,
            reason: 'retire',
          );
          await t.runAsync(g.close);
          await t.pump();
        }
      },
    );
  }
}
