import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_mobile/live/markdown_image.dart';
import 'package:pirc_render/src/html_buttons.dart';
import 'package:pirc_render/src/html_document_content.dart';
import 'package:pirc_render/src/native_html.dart';
import 'package:pirc_mobile/theme.dart';

const clicksHtml = '''<!doctype html><html><body>
<p id="inline" onclick="window.inlineCount++; this.textContent = 'Inline ' + window.inlineCount">Inline target</p>
<div id="bubble"><span id="bubble-target">Bubble target</span></div>
<p id="bubble-result">Bubble waiting</p>
<p id="delegated">Delegated target</p><p id="delegated-result">Delegated waiting</p>
<p id="once">Once target</p>
<p id="removed">Removed target</p><p id="removed-result">Removed 0</p>
<a id="prevented" href="/must-not-navigate" onclick="event.preventDefault(); document.querySelector('#prevented-result').textContent = 'Prevented'">Prevent anchor</a>
<p id="prevented-result">Not prevented</p>
<a id="property" href="/must-not-navigate-property" onclick="window.propertyInlineCount++; document.querySelector('#property-result').textContent = 'Inline count ' + window.propertyInlineCount">Property handler target</a>
<p id="property-result">Property 0; inline=0</p>
<a id="mutating" href="/old" target="_self" download="old.txt">Mutating link</a>
<a id="ordinary" href="/ordinary">Ordinary link</a>
<a id="image-link" href="/image"><img id="image-target" width="24" height="24" alt="Tiny link image" src="data:image/gif;base64,R0lGODlhAQABAAD/ACwAAAAAAQABAAACADs="></a>
<p id="image-result">Image not clicked</p>
<button id="button" type="button">Button target</button><p id="button-result">Button 0</p>
<label id="checkbox-label"><span id="label-target">Checkbox label target</span><input id="label-check" type="checkbox"></label>
<p id="label-state">Checkbox checked=false</p><p id="label-change">Label change none</p>
<details id="details"><summary><span id="summary-target">Details summary target</span></summary><p>Details body visible</p></details>
<details id="prevent-details"><summary><span id="prevent-summary" onclick="event.preventDefault(); document.querySelector('#prevent-summary-result').textContent = 'Summary prevented'">Prevented summary target</span></summary><p>Prevented details body visible</p></details>
<p id="prevent-summary-result">Summary not clicked</p>
<script>
window.inlineCount = 0;
window.propertyInlineCount = 0;
let propertyHandlerCount = 0;
let bubbleTargetCount = 0;
let bubbleCount = 0;
document.querySelector('#bubble-target').addEventListener('click', () => {
 bubbleTargetCount++;
});
document.querySelector('#bubble').addEventListener('click', event => {
 bubbleCount++;
 document.querySelector('#bubble-result').textContent =
   'Bubble ' + bubbleTargetCount + '/' + bubbleCount + ' target=' + event.target.id;
});
let delegatedCount = 0;
document.addEventListener('click', event => {
 if (event.target.id === 'delegated') {
  delegatedCount++;
  document.querySelector('#delegated-result').textContent = 'Delegated ' + delegatedCount;
 }
});
let onceCount = 0;
document.querySelector('#once').addEventListener('click', () => {
 onceCount++;
 document.querySelector('#once').textContent = 'Once ' + onceCount;
}, {once: true});
const removed = document.querySelector('#removed');
const removedHandler = () => {
 document.querySelector('#removed-result').textContent = 'Removed handler ran';
};
removed.addEventListener('click', removedHandler);
removed.removeEventListener('click', removedHandler);
document.querySelector('#mutating').addEventListener('click', event => {
 event.currentTarget.href = '/new';
 event.currentTarget.target = '_blank';
 event.currentTarget.download = 'new.txt';
});
document.querySelector('#image-target').addEventListener('click', event => {
 document.querySelector('#image-result').textContent =
   'Image target=' + event.target.id;
});
let buttonCount = 0;
document.querySelector('#button').addEventListener('click', () => {
 buttonCount++;
 document.querySelector('#button-result').textContent = 'Button ' + buttonCount;
});
document.querySelector('#property').onclick = () => {
 propertyHandlerCount++;
 document.querySelector('#property-result').textContent =
   'Property ' + propertyHandlerCount + '; inline=' + window.propertyInlineCount;
 return false;
};
const labelCheck = document.querySelector('#label-check');
labelCheck.addEventListener('change', () => {
 document.querySelector('#label-state').textContent =
   'Checkbox checked=' + labelCheck.checked;
 document.querySelector('#label-change').textContent =
   'Label change checked=' + labelCheck.checked;
});
</script></body></html>''';

Future<void> _tapText(WidgetTester t, String text) async {
  final finder = find.byWidgetPredicate(
    (widget) => widget is RichText && widget.text.toPlainText().contains(text),
    description: 'RichText containing "$text"',
  );
  expect(finder, findsOneWidget);
  await t.ensureVisible(finder);
  final paragraph = t.renderObject<RenderParagraph>(finder);
  final start = paragraph.text.toPlainText().indexOf(text);
  final boxes = paragraph.getBoxesForSelection(
    TextSelection(baseOffset: start, extentOffset: start + text.length),
  );
  expect(boxes, isNotEmpty);
  await t.tapAt(paragraph.localToGlobal(boxes.first.toRect().center));
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Android dispatches general and anchor click scripts once', (
    t,
  ) async {
    final gateway = Gateway();
    final theme = await PircTheme.load();
    final bytes = Uint8List.fromList(utf8.encode(clicksHtml));
    final document = NativeFetchedDocument(
      id: 1,
      url: 'https://example.test/clicks',
      status: 200,
      bytes: bytes,
      mimeType: 'text/html',
      headers: {},
      content: NativeHtmlDocumentContent.fromBytes(
        bytes,
        mimeType: 'text/html',
        charset: 'utf-8',
      ),
    );
    final links = <NativeHtmlLink>[];
    bool visible(String text) =>
        find.text(text, findRichText: true).evaluate().isNotEmpty;
    Future<void> until(bool Function() ready, String label) async {
      for (var i = 0; i < 200 && !ready(); i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      expect(ready(), true, reason: '$label: ${document.scripts?.diagnostics}');
      expect(t.takeException(), isNull, reason: label);
    }

    Finder button(String label) => find.byWidgetPredicate(
      (widget) =>
          widget is NativeHtmlButtonWidget && widget.button.label == label,
    );

    try {
      await t.pumpWidget(
        MaterialApp(
          theme: theme.build(Brightness.light),
          home: Scaffold(
            body: NativeFetchedDocumentView(
              document: document,
              gateway: gateway,
              onLink: links.add,
              onSubmit: (_) {},
            ),
          ),
        ),
      );
      await until(() => document.scripts?.ready == true, 'script ready');
      await t.pumpAndSettle();

      await _tapText(t, 'Inline target');
      await until(() => visible('Inline 1'), 'inline onclick');

      await _tapText(t, 'Bubble target');
      await until(
        () => visible('Bubble 1/1 target=bubble-target'),
        'child click bubbles exactly once',
      );

      await _tapText(t, 'Delegated target');
      await until(() => visible('Delegated 1'), 'document delegated click');

      await _tapText(t, 'Once target');
      await until(() => visible('Once 1'), 'once listener first click');
      await _tapText(t, 'Once 1');
      await t.pump(const Duration(milliseconds: 100));
      expect(visible('Once 1'), true);
      expect(visible('Once 2'), false);

      await _tapText(t, 'Removed target');
      await t.pump(const Duration(milliseconds: 100));
      expect(visible('Removed target'), true);
      expect(visible('Removed handler ran'), false);
      expect(links, isEmpty);

      await _tapText(t, 'Prevent anchor');
      await until(() => visible('Prevented'), 'preventDefault anchor');
      expect(
        links,
        isEmpty,
        reason: 'preventDefault must suppress navigation.',
      );

      await _tapText(t, 'Property handler target');
      await until(
        () => visible('Property 1; inline=0'),
        'onclick property replaces the inline handler and returns false',
      );
      expect(
        links,
        isEmpty,
        reason: 'onclick return false suppresses navigation.',
      );

      await _tapText(t, 'Mutating link');
      await until(() => links.length == 1, 'mutated link callback');
      expect(links.single.href, '/new');
      expect(links.single.target, '_blank');
      expect(links.single.download, 'new.txt');
      expect(links.single.targetSpecified, true);

      await _tapText(t, 'Ordinary link');
      await until(() => links.length == 2, 'ordinary link callback');
      expect(links[1].href, '/ordinary');
      expect(links[1].target, '');
      expect(links[1].download, isNull);
      expect(links[1].targetSpecified, false);
      expect(links.where((link) => link.href == '/ordinary'), hasLength(1));

      final image = find.byType(NativeMarkdownImage);
      await t.ensureVisible(image);
      await t.tap(image);
      await until(() => links.length == 3, 'image inside anchor');
      await until(
        () => visible('Image target=image-target'),
        'image click target is preserved',
      );
      expect(links[2].href, '/image');

      await t.ensureVisible(button('Button target'));
      await t.tap(button('Button target'));
      await until(() => visible('Button 1'), 'button click dispatched once');
      expect(visible('Button 2'), false);

      await _tapText(t, 'Checkbox label target');
      await until(
        () =>
            visible('Checkbox checked=true') &&
            visible('Label change checked=true'),
        'label descendant toggles checkbox and dispatches change',
      );

      await _tapText(t, 'Details summary target');
      await until(
        () => visible('Details body visible'),
        'summary opens details',
      );
      await _tapText(t, 'Details summary target');
      await until(
        () => !visible('Details body visible'),
        'second summary click closes details',
      );

      await _tapText(t, 'Prevented summary target');
      await until(
        () => visible('Summary prevented'),
        'summary preventDefault handler',
      );
      expect(visible('Prevented details body visible'), false);
      expect(links, hasLength(3));
      expect(document.scripts!.diagnostics, isEmpty);
    } finally {
      await t.pumpWidget(const SizedBox());
      document.dispose();
    }
  });
}
