import 'package:pirc_mobile/l10n/app_i18n.dart';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';
import 'package:html/parser.dart' as html;
import 'package:pirc_render/src/html_buttons.dart';
import 'package:pirc_render/src/html_form_submission.dart';
import 'package:pirc_render/src/native_html.dart';
import 'package:pirc_render/src/html_named_properties.dart';
import 'native_html_forms_test.dart' show page, forms, entries;
import 'native_html_test.dart' show structure;

Map<String, dynamic> object(Object? v) => (v as Map).cast<String, dynamic>();
final fixture = object(
  jsonDecode(
    File(
      '../../fixtures/mobile-parity/html-form-submission.json',
    ).readAsStringSync(),
  ),
);
final expected = object(
  jsonDecode(
    File(
      '../../fixtures/mobile-parity/html-form-submission-expected.json',
    ).readAsStringSync(),
  ),
);

void main() {
  test(
    'native sanitizer matches submission DOM and captured named-property corpus',
    () {
      expect(
        structure(sanitizeNativeHtml(fixture['source'] as String)),
        structure(object(expected['initial'])['sanitizedDOM'] as String),
      );
      final named = object(
        jsonDecode(
          File(
            '../../fixtures/mobile-parity/html-named-properties.json',
          ).readAsStringSync(),
        ),
      );
      expect(
        nativeHtmlBlockedNamedProperties,
        unorderedEquals(object(named['inventory'])['blockedNames'] as List),
      );
      final corpus = object(named['sanitizedCorpus']);
      expect(
        structure(sanitizeNativeHtml(corpus['source'] as String)),
        structure(corpus['html'] as String),
      );
    },
  );

  testWidgets(
    'real native click and Enter produce pinned browser submissions and clipboard writes',
    (t) async {
      AppI18n.instance.setLanguage('zh-TW');
      addTearDown(() => AppI18n.instance.setLanguage('en'));
      t.binding.platformDispatcher.localeTestValue = const Locale('zh', 'TW');
      addTearDown(t.binding.platformDispatcher.clearLocaleTestValue);
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(1024, 768);
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final sent = <NativeHtmlFormSubmission>[];
      final writes = <String>[];
      final writesAtSubmit = <List<String>>[];
      var phaseWriteStart = 0;
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            writes.add(object(call.arguments)['text'] as String);
          }
          return null;
        },
      );
      addTearDown(
        () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await t.pumpWidget(
        page(
          fixture['source'] as String,
          sent,
          onSubmission: (_) =>
              writesAtSubmit.add(writes.skip(phaseWriteStart).toList()),
        ),
      );
      await t.pumpAndSettle();
      final actions = (fixture['actions'] as List)
          .map(object)
          .where((e) => !['networkGet', 'networkPost'].contains(e['mode']))
          .toList();
      final oracle = (expected['actions'] as List).map(object).toList();
      expect(actions.length, oracle.length);
      for (var i = 0; i < actions.length; i++) {
        final action = actions[i];
        final before = sent.length;
        final writeCount = writes.length;
        phaseWriteStart = writeCount;
        final doc = html.parseFragment(
          t.widget<HtmlWidget>(find.byType(HtmlWidget)).html,
        );
        final element = doc.querySelector(action['selector'] as String)!;
        final current = forms(t);
        if (action['mode'] == 'click') {
          final button = current.buttons.resolveControl(element)!;
          final finder = find.byWidgetPredicate(
            (w) => w is NativeHtmlButtonWidget && w.button.key == button.key,
          );
          await t.ensureVisible(finder);
          await t.pumpAndSettle();
          await t.tap(finder);
        } else {
          final field = current.textFields.resolveControl(element)!;
          final controller = current.textFields.controllerFor(field.key);
          final finder = find.byWidgetPredicate(
            (w) => w is EditableText && identical(w.controller, controller),
          );
          await t.ensureVisible(finder);
          if (action['mode'] == 'fill') {
            await t.enterText(finder, action['value'] as String);
          } else {
            await t.showKeyboard(finder);
            await t.sendKeyEvent(LogicalKeyboardKey.enter);
          }
        }
        await t.pumpAndSettle();
        final events = object(oracle[i]['events']);
        final browserSubmits = (events['submits'] as List).map(object).toList();
        expect(
          sent.length - before,
          browserSubmits.length,
          reason: action['id'] as String,
        );
        for (var j = 0; j < browserSubmits.length; j++) {
          final browser = browserSubmits[j];
          final native = sent[before + j];
          expect(
            writesAtSubmit[before + j],
            browser['clipboardWritesAtSubmit'],
            reason: '${action['id']} copy/default ordering',
          );
          expect(
            entries(native),
            browser['entries'],
            reason: action['id'] as String,
          );
          expect(
            native.submitterId,
            browser['submitter'] == null
                ? null
                : object(browser['submitter'])['id'],
          );
          final browserForm = object(browser['form']);
          expect(native.method.toLowerCase(), browserForm['method']);
          expect(native.enctype, browserForm['enctype']);
          expect(native.target, browserForm['target']);
          final uri = Uri.parse(browserForm['action'] as String);
          expect(
            native.action,
            '${uri.path}${uri.hasQuery ? '?${uri.query}' : ''}${uri.hasFragment ? '#${uri.fragment}' : ''}',
          );
        }
        final invalid = (events['invalid'] as List).map(object).toList();
        if (invalid.isNotEmpty) {
          final invalidElement = doc.querySelector(
            invalid.first['selector'] as String,
          )!;
          final field = current.textFields.resolveControl(invalidElement)!;
          expect(current.invalidKey, field.key);
          expect(current.message, invalid.first['validationMessage']);
          expect(current.textFields.focusNodeFor(field.key).hasFocus, isTrue);
        }
        if (events.containsKey('clipboardWrites')) {
          expect(
            writes.skip(writeCount).toList(),
            events['clipboardWrites'],
            reason: '${action['id']} clipboard',
          );
        }
        expect(t.takeException(), isNull);
      }
    },
  );

  testWidgets(
    'native request bytes match real Chromium local GET and POST requests',
    (t) async {
      AppI18n.instance.setLanguage('zh-TW');
      addTearDown(() => AppI18n.instance.setLanguage('en'));
      t.binding.platformDispatcher.localeTestValue = const Locale('zh', 'TW');
      addTearDown(t.binding.platformDispatcher.clearLocaleTestValue);
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(1024, 768);
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final sent = <NativeHtmlFormSubmission>[];
      await t.pumpWidget(page(fixture['source'] as String, sent));
      await t.pumpAndSettle();
      final doc = html.parseFragment(
        t.widget<HtmlWidget>(find.byType(HtmlWidget)).html,
      );
      for (final raw in expected['defaultNavigations'] as List) {
        final navigation = object(raw);
        final selector = navigation['id'] == 'get-default-navigation'
            ? '#get-submit'
            : '#post-submit';
        final button = forms(
          t,
        ).buttons.resolveControl(doc.querySelector(selector)!)!;
        final finder = find.byWidgetPredicate(
          (w) => w is NativeHtmlButtonWidget && w.button.key == button.key,
        );
        await t.ensureVisible(finder);
        await t.tap(finder);
        await t.pumpAndSettle();
        final native = sent.last.buildRequest();
        final browser = object(navigation['request']);
        expect(native.method, browser['method']);
        final uri = Uri.parse(navigation['finalUrl'] as String);
        expect(
          native.url,
          (navigation['finalUrl'] as String).substring(
            '${uri.scheme}://${uri.authority}'.length,
          ),
        );
        expect(native.contentType, browser['contentType']);
        expect(native.body ?? '', browser['body']);
        if (native.method == 'GET') {
          expect('?${native.query}', browser['rawQuery']);
        }
      }
      expect(sent, hasLength(2));
    },
  );
  testWidgets('native zh-TW feedback matches each captured validation message', (
    t,
  ) async {
    AppI18n.instance.setLanguage('zh-TW');
    addTearDown(() => AppI18n.instance.setLanguage('en'));
    t.binding.platformDispatcher.localeTestValue = const Locale('zh', 'TW');
    addTearDown(t.binding.platformDispatcher.clearLocaleTestValue);
    final doc = html.parseFragment(
      object(expected['initial'])['sanitizedDOM'] as String,
    );
    for (final raw in object(expected['initial'])['fields'] as List) {
      final field = object(raw);
      final id = field['id'] as String?;
      if (id == null || !id.startsWith('locale-')) continue;
      final element = doc.querySelector('#$id')!;
      await t.pumpWidget(
        page(
          '<form>${element.outerHtml}${id == 'locale-radio-peer' ? doc.querySelector('#locale-required-radio')!.outerHtml : ''}<button>Send</button></form>',
          [],
        ),
      );
      await t.pumpAndSettle();
      final button = find.byType(NativeHtmlButtonWidget);
      await t.tap(button);
      await t.pumpAndSettle();
      expect(forms(t).message, field['validationMessage'], reason: id);
      expect(t.takeException(), isNull);
    }
  });
}
