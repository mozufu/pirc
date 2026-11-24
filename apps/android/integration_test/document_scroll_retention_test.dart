import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show debugPrintSynchronously;
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:integration_test/integration_test.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/html_document_content.dart';
import 'package:pirc_render/src/html_document_urls.dart';
import 'package:pirc_render/src/html_form_submission.dart';
import 'package:pirc_mobile/theme.dart';

const fixtureOrigin = String.fromEnvironment('PIRC_CHART_FIXTURE_ORIGIN');
final _nativeGateway = Gateway();

class _FixtureGateway extends Gateway {
  _FixtureGateway(this.source);
  final String source;
  // The app uses one event subscription per native context. Creating another
  // EventChannel subscription retires that context and all its script isolates.
  @override
  Stream<Json> get events => _nativeGateway.events;
  int requests = 0;
  @override
  Future<dynamic> call(String method, [Json args = const {}]) async {
    if (method == 'boot') {
      return {
        'origin': 'https://example.test',
        'pairingStamp': 'synthetic-retention',
      };
    }
    if (method == 'resolveDocumentUrl') {
      return resolveNativeDocumentUrl(
        args['reference'] as String,
        args['baseUrl'] as String,
      );
    }
    if (method == 'documentScriptOpen') {
      // The unpaired fixture has no native storage window; use the sandbox's
      // default isolated reader while keeping real script execution.
      return super.call(
        method,
        Map<String, dynamic>.of(args)..remove('storageSessionKey'),
      );
    }
    if (method == 'documentPrepareRequest') {
      return {
        'nativeCookieRequestKey':
            'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      };
    }
    if (method == 'document') {
      requests++;
      return {
        'status': 200,
        'finalUrl': args['url'],
        'finalMethod': 'GET',
        'mimeType': 'text/html',
        'charset': 'utf-8',
        'bytes': utf8.encode(source),
        'headersRelevant': <String, dynamic>{},
      };
    }
    return super.call(method, args);
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'retained document views keep real script scroll readings through remounts',
    (tester) async {
      final origin = Uri.parse(fixtureOrigin);
      expect(origin.host, '127.0.0.1');
      expect(origin.scheme, 'http');
      final client = HttpClient();
      late Json fixture;
      try {
        final response = await (await client.getUrl(
          origin.resolve('/scroll-retention.json'),
        )).close();
        expect(response.statusCode, 200);
        fixture = obj(jsonDecode(await utf8.decoder.bind(response).join()));
      } finally {
        client.close(force: true);
      }
      expect(fixture['browserVersion'], '153.0.8010.12');
      expect(fixture['cases'], hasLength(8));
      final gateway = _nativeGateway,
          theme = await PircTheme.load(),
          accepted = <Json>[];
      for (final raw in fixture['cases'] as List) {
        final row = obj(raw),
            viewport = obj(row['viewport']),
            dpr = (row['dpr'] as num).toDouble();
        tester.view.devicePixelRatio = dpr;
        tester.view.physicalSize =
            Size(
              (viewport['width'] as num).toDouble(),
              (viewport['height'] as num).toDouble(),
            ) *
            dpr;
        final source = (fixture['html'] as String).replaceFirst(
          '</body>',
          '<script>${fixture['driverSource']}</script></body>',
        );
        NativeFetchedDocument create(int id) {
          final bytes = utf8.encode(source);
          return NativeFetchedDocument(
            id: id,
            url: 'https://example.test/scroll-retention',
            status: 200,
            bytes: bytes,
            mimeType: 'text/html',
            content: NativeHtmlDocumentContent.fromBytes(
              bytes,
              mimeType: 'text/html',
              charset: 'utf-8',
            ),
            headers: {},
          );
        }

        final first = create(1),
            second = create(2),
            states = row['states'] as List;
        Widget view(NativeFetchedDocument d) => MaterialApp(
          theme: theme.build(
            row['theme'] == 'dark' ? Brightness.dark : Brightness.light,
          ),
          home: Scaffold(
            body: NativeFetchedDocumentView(
              key: const ValueKey('retained-view'),
              document: d,
              gateway: gateway,
              onLink: (_) {},
              onSubmit: (_) {},
            ),
          ),
        );
        Future<Json> waitFor(
          NativeFetchedDocument d,
          int after,
          int step,
        ) async {
          Json actual = {};
          for (var attempt = 0; attempt < 250; attempt++) {
            await tester.pump(const Duration(milliseconds: 30));
            final text =
                html
                    .parse(d.scripts?.content?.text ?? '')
                    .getElementById('retention-probe')
                    ?.text ??
                '';
            if (text.startsWith('{')) actual = obj(jsonDecode(text));
            if ((actual['sequence'] as num? ?? 0) > after &&
                actual['step'] == step &&
                d.scripts?.ready == true) {
              break;
            }
          }
          expect(
            (actual['sequence'] as num? ?? 0),
            greaterThan(after),
            reason: '${d.scripts?.diagnostics}',
          );
          expect(actual['step'], step);
          expect(d.scripts!.diagnostics, isEmpty);
          return actual;
        }

        void compare(Json actual, Map expected, {bool root = true}) {
          if (root) {
            expect(
              actual['root'],
              closeTo((expected['root'] as num).toDouble(), .01),
            );
          }
          for (final entry in (expected['scroll'] as Map).entries) {
            for (final key in [
              'left',
              'top',
              'width',
              'height',
              'clientWidth',
              'clientHeight',
            ]) {
              expect(
                obj(obj(actual['scroll'])[entry.key])[key],
                closeTo((entry.value[key] as num).toDouble(), .01),
                reason: '${viewport['width']} ${entry.key}.$key',
              );
            }
          }
        }

        try {
          await tester.pumpWidget(view(first));
          await waitFor(first, 0, 0);
          await tester.tap(find.text('Step', findRichText: true));
          var report = await waitFor(first, 1, 1);
          compare(report, states[0] as Map);
          final retainedScript = first.scripts;
          await tester.pumpWidget(const SizedBox());
          await tester.pump(const Duration(milliseconds: 60));
          await tester.pumpWidget(view(first));
          await tester.pump(const Duration(milliseconds: 90));
          expect(first.scripts, same(retainedScript));
          await tester.tap(find.text('Read', findRichText: true));
          report = await waitFor(first, (report['sequence'] as num).toInt(), 1);
          compare(report, states[0] as Map);
          await tester.pumpWidget(view(second));
          final fresh = await waitFor(second, 0, 0);
          compare(fresh, states.last as Map, root: false);
          expect(fresh['root'], 0);
          await tester.tap(find.text('Step', findRichText: true));
          final secondStep = await waitFor(second, 1, 1);
          compare(secondStep, states[0] as Map);
          await tester.tap(find.text('Step', findRichText: true));
          final secondReport = await waitFor(
            second,
            (secondStep['sequence'] as num).toInt(),
            2,
          );
          compare(secondReport, states[1] as Map);
          await tester.pumpWidget(view(first));
          await tester.pump(const Duration(milliseconds: 90));
          await tester.tap(find.text('Read', findRichText: true));
          report = await waitFor(first, (report['sequence'] as num).toInt(), 1);
          compare(report, states[0] as Map);
          await tester.pumpWidget(view(second));
          await tester.pump(const Duration(milliseconds: 90));
          await tester.tap(find.text('Read', findRichText: true));
          final returned = await waitFor(
            second,
            (secondReport['sequence'] as num).toInt(),
            2,
          );
          compare(returned, states[1] as Map);
          expect(tester.takeException(), isNull);
          accepted.add({
            'viewport': viewport,
            'dpr': dpr,
            'theme': row['theme'],
            'nativeScriptReadings': 'exact',
            'remount': report,
            'secondDocument': returned,
          });
        } finally {
          await tester.pumpWidget(const SizedBox());
          first.dispose();
          second.dispose();
          if (first.scripts != null) await first.scripts!.closed;
          if (second.scripts != null) await second.scripts!.closed;
          tester.view.reset();
        }
      }
      debugPrintSynchronously(
        'PIRC_NATIVE_SCROLL_RETENTION_ACCEPTANCE ${jsonEncode(accepted)}',
      );
    },
    skip: fixtureOrigin.isEmpty,
  );
  testWidgets(
    'native workspace retains the current entry and honors a new offscreen fragment',
    (tester) async {
      final origin = Uri.parse(fixtureOrigin);
      expect(origin.host, '127.0.0.1');
      expect(origin.scheme, 'http');
      final client = HttpClient();
      late Json fixture;
      try {
        final response = await (await client.getUrl(
          origin.resolve('/scroll-retention.json'),
        )).close();
        expect(response.statusCode, 200);
        fixture = obj(jsonDecode(await utf8.decoder.bind(response).join()));
      } finally {
        client.close(force: true);
      }
      final row = obj((fixture['cases'] as List).first),
          source = (fixture['html'] as String).replaceFirst(
            '</body>',
            '<script>${fixture['driverSource']}</script></body>',
          );
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      final gateway = _FixtureGateway(source), theme = await PircTheme.load();
      final liveWindows = NativeDocumentWindows(gateway);
      final window = liveWindows.target(
        'report',
        null,
        sourceUrl: 'https://example.test/',
      );
      await window.load(
        const NativeHtmlFormRequest(
          url: '/retention#outer',
          method: 'GET',
          target: '',
        ),
        baseUrl: window.sourceUrl,
      );
      liveWindows.select(window);
      final document = window.currentDocument!;
      Widget workspace() => MaterialApp(
        theme: theme.build(Brightness.light),
        home: NativeDocumentWorkspace(windows: liveWindows, managed: true),
      );
      Future<Json> read(int after, {bool tap = true}) async {
        if (tap) await tester.tap(find.text('Read', findRichText: true));
        Json report = {};
        for (var attempt = 0; attempt < 250; attempt++) {
          await tester.pump(const Duration(milliseconds: 30));
          final text =
              html
                  .parse(document.scripts?.content?.text ?? '')
                  .getElementById('retention-probe')
                  ?.text ??
              '';
          if (text.startsWith('{')) report = obj(jsonDecode(text));
          if ((report['sequence'] as num? ?? 0) > after) break;
        }
        expect(
          (report['sequence'] as num? ?? 0),
          greaterThan(after),
          reason: '${document.scripts?.diagnostics}',
        );
        expect(document.scripts!.diagnostics, isEmpty);
        return report;
      }

      void compare(Json report, Json reference) {
        expect(report['root'], reference['root']);
        for (final entry in obj(reference['scroll']).entries) {
          for (final key in [
            'left',
            'top',
            'width',
            'height',
            'clientWidth',
            'clientHeight',
          ]) {
            expect(
              obj(obj(report['scroll'])[entry.key])[key],
              obj(entry.value)[key],
            );
          }
        }
      }

      try {
        await tester.pumpWidget(workspace());
        var report = await read(0, tap: false);
        await tester.tap(find.text('Step', findRichText: true));
        report = await read((report['sequence'] as num).toInt(), tap: false);
        document.scroll.jumpTo(160);
        await tester.pump(const Duration(milliseconds: 90));
        report = await read((report['sequence'] as num).toInt());
        compare(report, obj(row['retainedEntry']));
        final scripts = document.scripts;
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(milliseconds: 60));
        await tester.pumpWidget(workspace());
        await tester.pump(const Duration(milliseconds: 90));
        expect(document.scripts, same(scripts));
        report = await read((report['sequence'] as num).toInt());
        compare(report, obj(row['retainedEntry']));
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(milliseconds: 60));
        final result = await window.load(
          const NativeHtmlFormRequest(
            url: '/retention#top',
            method: 'GET',
            target: '',
          ),
          baseUrl: window.sourceUrl,
          fragmentAllowed: true,
        );
        expect(result, NativeDocumentLoadResult.committed);
        expect(window.currentDocument, same(document));
        await tester.pumpWidget(workspace());
        await tester.pump(const Duration(milliseconds: 90));
        report = await read((report['sequence'] as num).toInt());
        compare(report, obj(row['movedEntry']));
        expect(gateway.requests, 1);
        expect(tester.takeException(), isNull);
        debugPrintSynchronously(
          'PIRC_NATIVE_SCROLL_RETENTION_WORKSPACE ${jsonEncode(report)}',
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        liveWindows.dispose();
        if (document.scripts != null) await document.scripts!.closed;
        tester.view.reset();
      }
    },
    skip: fixtureOrigin.isEmpty,
  );
}
