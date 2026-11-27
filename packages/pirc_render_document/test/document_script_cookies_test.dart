// Resource lifecycle, containment and limits: safety regressions, so the
// default suite runs them (plans/client.md, Testing).
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render_document/src/document_scripts.dart';
import 'package:pirc_render_document/src/scripts_platform.dart';
import 'support/legacy_scripts_platform.dart';
import 'document_script_resources_test.dart' as resources;

/// Cookies stay in the session store (Kotlin); this fake logs each
/// `cookies` call and each `syncCookies` evaluation into [calls] in order.
class CookieGateway extends resources.ResourceGateway {
  bool failCookies = false;
  String canonicalValue = 'native';
  int? generation;

  @override
  Future<String> cookies(
    DocumentScriptSession session, [
    List<String> writes = const [],
  ]) async {
    calls.add(('documentScriptCookies', {'writes': writes}));
    if (failCookies) throw StateError('Cookie scope retired');
    return 'visible=$canonicalValue';
  }

  @override
  Future<String> evaluate(DocumentScriptSession session, String source) {
    if (source.startsWith('__pircDocument.syncCookies(')) {
      calls.add(('documentScriptEvaluate', {'source': source}));
    }
    return super.evaluate(session, source);
  }

  @override
  Future<dynamic> call(String method, [Json args = const {}]) async {
    final result = await super.call(method, args);
    final source = '${args['source']}';
    if (method == 'documentScriptEvaluate' &&
        source.startsWith('__pircDocument.init(')) {
      final init = obj(jsonDecode(source.substring(20, source.length - 1)));
      generation = obj(init['cookieState'])['generation'] as int;
      return {
        'value': jsonEncode({
          ...obj(jsonDecode(result['value'] as String)),
          'cookieWrites': [
            {
              'url': 'https://example.test/nested/page',
              'line': 'js=one; Path=/',
              'generation': generation,
            },
          ],
        }),
      };
    }
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'initial cookie writes are canonicalized before any resource starts',
    () async {
      final g = CookieGateway()..requests = [resources.request('fetch-1')];
      final state = NativeDocumentScripts(g);
      try {
        await state.start(source: '', url: 'https://example.test/nested/page');
        await resources.settle();
        expect(state.ready, true);
        final flush = g.calls.indexWhere(
          (c) =>
              c.$1 == 'documentScriptCookies' &&
              (c.$2['writes'] as List).isNotEmpty,
        );
        final sync = g.calls.indexWhere(
          (c) =>
              c.$1 == 'documentScriptEvaluate' &&
              '${c.$2['source']}'.startsWith('__pircDocument.syncCookies('),
        );
        final request = g.calls.indexWhere(
          (c) => c.$1 == 'documentScriptResource',
        );
        expect(flush, greaterThan(-1));
        expect(sync, greaterThan(flush));
        expect(request, greaterThan(sync));
        expect(g.calls[flush].$2['writes'], ['js=one; Path=/']);
      } finally {
        state.dispose();
        await state.closed;
      }
    },
  );
  test(
    'fetch completion refreshes native response cookies before JS callback',
    () async {
      final g = CookieGateway()..requests = [resources.request('fetch-1')];
      final state = NativeDocumentScripts(g);
      try {
        await state.start(source: '', url: 'https://example.test/nested/page');
        await resources.settle();
        final before = g.calls.length;
        g.canonicalValue = 'set-by-response';
        g.pending['fetch-1']!.complete(resources.response('complete'));
        await resources.settle();
        final calls = g.calls.skip(before).toList();
        final fresh = calls.indexWhere((c) => c.$1 == 'documentScriptCookies');
        final sync = calls.indexWhere(
          (c) =>
              c.$1 == 'documentScriptEvaluate' &&
              '${c.$2['source']}'.startsWith('__pircDocument.syncCookies('),
        );
        final callback = calls.indexWhere(
          (c) =>
              c.$1 == 'documentScriptEvaluate' &&
              '${c.$2['source']}'.startsWith(
                '__pircDocument.completeResource(',
              ),
        );
        expect(fresh, greaterThan(-1));
        expect(sync, greaterThan(fresh));
        expect(callback, greaterThan(sync));
        expect('${calls[sync].$2['source']}', contains('set-by-response'));
      } finally {
        state.dispose();
        await state.closed;
      }
    },
  );
  test(
    'retired cookie scope fails visibly and does not launch queued HTTP work',
    () async {
      final g = CookieGateway()
        ..failCookies = true
        ..requests = [resources.request('fetch-1')];
      final state = NativeDocumentScripts(g);
      try {
        await state.start(source: '', url: 'https://example.test/nested/page');
        expect(state.ready, false);
        expect(state.diagnostics.join(), contains('Cookie scope retired'));
        expect(g.calls.where((c) => c.$1 == 'documentScriptResource'), isEmpty);
        expect(
          g.calls.where((c) => c.$1 == 'documentScriptClose'),
          hasLength(1),
        );
      } finally {
        state.dispose();
        await state.closed;
      }
    },
  );
}
