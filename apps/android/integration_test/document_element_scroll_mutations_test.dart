import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrintSynchronously;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:integration_test/integration_test.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/html_buttons.dart';
import 'package:pirc_render/src/html_form_submission.dart';
import 'package:pirc_mobile/theme.dart';

// These are synthetic mutation contracts, not additional Chromium oracle
// cases. They exercise changing/replacing a scroll owner, calling scrollTo in
// that same JavaScript turn, then reading after native layout frames apply it.
const _scenarios = <_Scenario>[
  _Scenario(
    name: 'resize_scroll_owner_and_scroll_in_same_turn',
    actions: [
      "function(){document.getElementById('scroller').scrollTo(0,120);}",
      "function(){var owner=document.getElementById('scroller');owner.style.height='180px';owner.scrollTo(0,350);}",
    ],
    states: [
      _State(height: 120, clientHeight: 116, scrollTop: 0, generation: '1'),
      _State(height: 120, clientHeight: 116, scrollTop: 120, generation: '1'),
      // 180px content height + padding/border gives a 196px client height;
      // the 500px child therefore clamps the same-turn request to 320px.
      _State(height: 200, clientHeight: 196, scrollTop: 320, generation: '1'),
    ],
  ),
  _Scenario(
    name: 'replace_scrolled_owner_and_scroll_new_owner_in_same_turn',
    actions: [
      "function(){document.getElementById('scroller').scrollTo(0,120);}",
      "function(){var oldOwner=document.getElementById('scroller');var host=oldOwner.parentNode;oldOwner.remove();var owner=document.createElement('div');owner.id='scroller';owner.dataset.generation='2';owner.style.height='80px';var child=document.createElement('div');child.id='child';child.dataset.generation='2';owner.appendChild(child);host.appendChild(owner);owner.scrollTo(0,40);}",
    ],
    states: [
      _State(height: 120, clientHeight: 116, scrollTop: 0, generation: '1'),
      _State(height: 120, clientHeight: 116, scrollTop: 120, generation: '1'),
      // The id is reused by a new node; its 40px position must not inherit the
      // removed owner's prior 120px offset.
      _State(height: 100, clientHeight: 96, scrollTop: 40, generation: '2'),
    ],
  ),
];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native scroll state follows same-turn DOM owner mutations', (
    tester,
  ) async {
    final gateway = Gateway();
    final theme = await PircTheme.load();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final origin = 'http://127.0.0.1:${server.port}';
    final token = 'pirc_dev_${List.filled(43, 'A').join()}';
    var page = '';
    final receipts = <String>[];
    final failures = <String>[];
    final accepted = <String>[];
    final listener = server.listen((request) async {
      try {
        await request.drain<void>();
        if (request.headers.value('authorization') != 'Bearer $token') {
          failures.add('Missing synthetic bearer');
        }
        receipts.add(request.uri.path);
        if (request.uri.path == '/api/sessions') {
          request.response.headers.contentType = ContentType.json;
          request.response.write('{"sessions":[]}');
        } else if (request.uri.path == '/page') {
          request.response.headers.contentType = ContentType(
            'text',
            'html',
            charset: 'utf-8',
          );
          request.response.write(page);
        } else {
          failures.add('Unexpected path ${request.uri}');
          request.response.statusCode = 404;
        }
        await request.response.close();
      } catch (error) {
        failures.add('$error');
      }
    });

    try {
      await gateway.call('pair', {
        'link': Uri(
          scheme: 'pirc',
          host: 'pair',
          queryParameters: {'url': origin, 'token': token},
        ).toString(),
      });
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 1000);

      for (final scenario in _scenarios) {
        page = _pageFor(scenario);
        final windows = NativeDocumentWindows(gateway);
        final window = windows.target('', null, sourceUrl: '$origin/page');
        NativeFetchedDocument? document;
        try {
          expect(
            await window.load(
              NativeHtmlFormRequest(
                url: '$origin/page',
                method: 'GET',
                target: '',
              ),
              baseUrl: origin,
            ),
            NativeDocumentLoadResult.committed,
            reason: scenario.name,
          );
          windows.select(window);
          document = window.currentDocument!;
          await tester.pumpWidget(
            MaterialApp(
              theme: theme.build(Brightness.light),
              home: Scaffold(
                body: NativeDocumentScope(
                  documentUrl: '$origin/page',
                  windows: windows,
                  window: window,
                  child: NativeFetchedDocumentView(
                    document: document,
                    gateway: gateway,
                    onLink: (_) {},
                    onSubmit: (_) {},
                  ),
                ),
              ),
            ),
          );

          await _waitForDOMContentLoaded(tester, document);
          var observed = await _tapReadAndWait(tester, document, 0);
          _expectState(observed, scenario.states.first, scenario.name, 0);

          for (
            var actionIndex = 0;
            actionIndex < scenario.actions.length;
            actionIndex++
          ) {
            await _tapApplyAndWait(tester, document, actionIndex + 1);
            // Native scroll/layout work settles between the action tap and
            // the separate read tap, avoiding a same-turn measurement.
            await tester.pump();
            await tester.pump();
            observed = await _tapReadAndWait(tester, document, actionIndex + 1);
            _expectState(
              observed,
              scenario.states[actionIndex + 1],
              scenario.name,
              actionIndex + 1,
            );
          }

          expect(tester.takeException(), isNull, reason: scenario.name);
          accepted.add(scenario.name);
        } finally {
          await tester.pumpWidget(const SizedBox());
          windows.dispose();
          if (document?.scripts case final scripts?) await scripts.closed;
        }
      }

      expect(failures, isEmpty);
      expect(receipts, isNotEmpty);
      debugPrintSynchronously(
        'PIRC_ELEMENT_SCROLL_MUTATIONS ${jsonEncode({'contract': 'synthetic-common-dom-mutation-and-same-turn-scrollTo', 'cases': accepted, 'httpReceipts': receipts, 'failures': failures})}',
      );
    } finally {
      tester.view.reset();
      await listener.cancel();
      await server.close(force: true);
    }
  });
}

String _pageFor(_Scenario scenario) =>
    '''
<!doctype html>
<html><head><meta charset="utf-8"><meta name="color-scheme" content="light dark">
<style>
html,body{margin:0;padding:0}
#scroller{box-sizing:content-box;width:120px;height:100px;padding:8px;border:2px solid;overflow-x:hidden;overflow-y:auto}
#child{width:80px;height:500px}
/* Diagnostic overlays must not obscure the real native controls. */
#scroll-stage-label,#scroll-json-probe{pointer-events:none}
#scroll-stage-label{position:fixed;left:0;top:0;z-index:2147483647;background:white;color:black;white-space:nowrap}
#scroll-json-probe{position:fixed;left:0;top:0;width:0;height:0;overflow:hidden}
</style></head><body>
<div id="mutation-controls"><button id="apply-mutation" type="button">Apply next mutation</button><button id="read-native-frame" type="button">Read native frame</button></div>
<div id="scroll-stage-label"></div><pre id="scroll-json-probe"></pre>
<div id="host"><div id="scroller" data-generation="1"><div id="child" data-generation="1"></div></div></div>
<script>
window.__targets=['scroller','child'];
window.__actions=[${scenario.actions.join(',')}];
window.__applied=0;
window.__snapshot=function(){
  var targets={};
  window.__targets.forEach(function(id){
    var e=document.getElementById(id),r=e.getBoundingClientRect();
    targets[id]={rect:r.toJSON(),clientWidth:e.clientWidth,clientHeight:e.clientHeight,
      clientLeft:e.clientLeft,clientTop:e.clientTop,offsetWidth:e.offsetWidth,offsetHeight:e.offsetHeight,
      scrollWidth:e.scrollWidth,scrollHeight:e.scrollHeight,scrollLeft:e.scrollLeft,scrollTop:e.scrollTop,
      generation:e.dataset.generation||null};
  });
  return {stage:window.__applied,targets:targets};
};
document.getElementById('apply-mutation').addEventListener('click',function(){
  var action=window.__actions[window.__applied];
  if(!action)throw new Error('No mutation action at stage '+window.__applied);
  action();window.__applied++;
  document.getElementById('scroll-stage-label').textContent='applied '+window.__applied;
});
document.getElementById('read-native-frame').addEventListener('click',function(){
  document.getElementById('scroll-json-probe').textContent=JSON.stringify(window.__snapshot());
  document.getElementById('scroll-stage-label').textContent='read stage '+window.__applied;
});
document.addEventListener('DOMContentLoaded',function(){
  document.getElementById('scroll-stage-label').textContent='DOMContentLoaded';
});
</script></body></html>
''';

Future<void> _waitForDOMContentLoaded(
  WidgetTester tester,
  NativeFetchedDocument document,
) async {
  for (var turn = 0; turn < 120; turn++) {
    await tester.pump(const Duration(milliseconds: 25));
    final scripts = document.scripts;
    if (scripts == null || !scripts.ready) continue;
    final label = html
        .parse(scripts.content?.text ?? '')
        .getElementById('scroll-stage-label')
        ?.text;
    if (label == 'DOMContentLoaded') return;
  }
  fail('DOMContentLoaded and native script readiness did not arrive in time.');
}

Finder _nativeButton(String label) => find.byWidgetPredicate(
  (widget) => widget is NativeHtmlButtonWidget && widget.button.label == label,
);

Future<void> _tapApplyAndWait(
  WidgetTester tester,
  NativeFetchedDocument document,
  int expectedApplied,
) async {
  final button = _nativeButton('Apply next mutation');
  await tester.ensureVisible(button);
  await tester.tap(button);
  for (var turn = 0; turn < 80; turn++) {
    await tester.pump(const Duration(milliseconds: 25));
    final scripts = document.scripts;
    if (scripts == null || !scripts.ready) continue;
    final label = html
        .parse(scripts.content?.text ?? '')
        .getElementById('scroll-stage-label')
        ?.text;
    if (label == 'applied $expectedApplied') {
      // DOM publication precedes native command commit. As in the independent
      // scroll oracle, finish the host's post-frame work before the read tap.
      for (var frame = 0; frame < 8; frame++) {
        await tester.pump(const Duration(milliseconds: 25));
      }
      return;
    }
  }
  fail('The mutation button did not publish action $expectedApplied.');
}

Future<Map<String, dynamic>> _tapReadAndWait(
  WidgetTester tester,
  NativeFetchedDocument document,
  int expectedStage,
) async {
  final button = _nativeButton('Read native frame');
  await tester.ensureVisible(button);
  await tester.tap(button);
  for (var turn = 0; turn < 120; turn++) {
    await tester.pump(const Duration(milliseconds: 25));
    final scripts = document.scripts;
    if (scripts == null || !scripts.ready) continue;
    final page = html.parse(scripts.content?.text ?? '');
    final probe = page.getElementById('scroll-json-probe')?.text;
    if (probe == null || !probe.startsWith('{')) continue;
    final result = Map<String, dynamic>.from(jsonDecode(probe) as Map);
    final label = page.getElementById('scroll-stage-label')?.text;
    if (result['stage'] == expectedStage &&
        label == 'read stage $expectedStage') {
      return result;
    }
  }
  fail('Native-frame read did not publish stage $expectedStage in time.');
}

void _expectState(
  Map<String, dynamic> observed,
  _State expected,
  String scenario,
  int stage,
) {
  final targets = Map<String, dynamic>.from(observed['targets'] as Map);
  expect(targets.keys.toSet(), {
    'scroller',
    'child',
  }, reason: '$scenario $stage targets');
  final owner = Map<String, dynamic>.from(targets['scroller'] as Map);
  final child = Map<String, dynamic>.from(targets['child'] as Map);
  final ownerRect = Map<String, dynamic>.from(owner['rect'] as Map);
  final childRect = Map<String, dynamic>.from(child['rect'] as Map);
  expect(
    owner['generation'],
    expected.generation,
    reason: '$scenario $stage owner generation',
  );
  expect(
    ownerRect['width'],
    closeTo(140, .5),
    reason: '$scenario $stage owner width',
  );
  expect(
    ownerRect['height'],
    closeTo(expected.height, .5),
    reason: '$scenario $stage owner height',
  );
  expect(
    owner['clientWidth'],
    136,
    reason: '$scenario $stage owner clientWidth',
  );
  expect(
    owner['clientHeight'],
    expected.clientHeight,
    reason: '$scenario $stage owner clientHeight',
  );
  expect(
    owner['offsetWidth'],
    140,
    reason: '$scenario $stage owner offsetWidth',
  );
  expect(
    owner['offsetHeight'],
    expected.height,
    reason: '$scenario $stage owner offsetHeight',
  );
  expect(
    owner['scrollWidth'],
    136,
    reason: '$scenario $stage owner scrollWidth',
  );
  expect(
    owner['scrollHeight'],
    516,
    reason: '$scenario $stage owner scrollHeight',
  );
  expect(
    (owner['scrollLeft'] as num).toDouble(),
    closeTo(0, .3),
    reason: '$scenario $stage owner scrollLeft',
  );
  expect(
    (owner['scrollTop'] as num).toDouble(),
    closeTo(expected.scrollTop, .3),
    reason: '$scenario $stage owner scrollTop',
  );
  expect(
    child['generation'],
    expected.generation,
    reason: '$scenario $stage child generation',
  );
  expect(
    childRect['width'],
    closeTo(80, .5),
    reason: '$scenario $stage child width',
  );
  expect(
    childRect['height'],
    closeTo(500, .5),
    reason: '$scenario $stage child height',
  );
  expect(
    (childRect['x'] as num).toDouble(),
    closeTo((ownerRect['x'] as num).toDouble() + 10, .5),
    reason: '$scenario $stage child x within owner padding',
  );
  expect(
    (childRect['y'] as num).toDouble(),
    closeTo((ownerRect['y'] as num).toDouble() + 10 - expected.scrollTop, .5),
    reason: '$scenario $stage child y follows owner scrollTop',
  );
}

class _Scenario {
  const _Scenario({
    required this.name,
    required this.actions,
    required this.states,
  });

  final String name;
  final List<String> actions;
  final List<_State> states;
}

class _State {
  const _State({
    required this.height,
    required this.clientHeight,
    required this.scrollTop,
    required this.generation,
  });

  final int height;
  final int clientHeight;
  final int scrollTop;
  final String generation;
}
