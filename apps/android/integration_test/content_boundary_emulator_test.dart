// Device-side check of the content boundary, against local servers.
//
//   node apps/android/dev/emulator-fixture.mjs            # on the host
//   flutter test integration_test/content_boundary_emulator_test.dart \
//     -d <emulator> --dart-define=PIRC_EMULATOR_FIXTURE=true
//
// The servers record what really arrives, so every assertion is about requests
// observed at a receiver, not about widget output. The Gateways are the
// fixture's stand-ins (apps/android/dev/emulator-fixture.mjs), not the real
// Gateway: this covers the app's native client, rendering and pairing, and the
// real Gateway's own checks are covered by its tests.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pirc_mobile/live/common.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_mobile/theme.dart';

const _host = '10.0.2.2';
final _tokenA = 'pirc_dev_${'a' * 43}', _tokenB = 'pirc_dev_${'b' * 43}';
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

Future<Map<String, dynamic>> _fixture(int port, [String path = '__log']) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse('http://$_host:$port/$path'));
    final response = await request.close();
    return jsonDecode(await utf8.decoder.bind(response).join())
        as Map<String, dynamic>;
  } finally {
    client.close(force: true);
  }
}

Future<List<Map<String, dynamic>>> _log(int port) async =>
    ((await _fixture(port))['log'] as List).cast<Map<String, dynamic>>();

String _link(int port, String token) => Uri(
  scheme: 'pirc',
  host: 'pair',
  queryParameters: {'url': 'http://$_host:$port', 'token': token},
).toString();

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'inline images, remote images on tap, uploads, forms and pairing switch',
    (t) async {
      expect(
        const bool.fromEnvironment('PIRC_EMULATOR_FIXTURE'),
        isTrue,
        reason:
            'Run with --dart-define=PIRC_EMULATOR_FIXTURE=true against '
            'apps/android/dev/emulator-fixture.mjs on an isolated emulator',
      );
      final gateway = Gateway();
      final theme = await PircTheme.load();
      for (final port in [18701, 18702, 18703]) {
        await _fixture(port, '__reset');
      }

      Future<void> until(Future<bool> Function() ready, String step) async {
        for (var i = 0; i < 60; i++) {
          if (await ready()) return;
          await t.pump(const Duration(milliseconds: 250));
        }
        fail('Timed out: $step');
      }

      NativeDocumentWindows? windows;
      Future<void> show(String content, {required int gatewayPort}) async {
        windows?.dispose();
        final w = windows = NativeDocumentWindows(
          gateway,
          appDocumentUrl: () => 'http://$_host:$gatewayPort/?session=s1',
        );
        await t.pumpWidget(
          MaterialApp(
            theme: theme.build(Brightness.light),
            home: NativeDocumentScope(
              windows: w,
              documentUrl: 'http://$_host:$gatewayPort/?session=s1',
              sourceIdentity: w.accountIdentity,
              child: NativeDocumentHost(
                windows: w,
                child: Scaffold(
                  body: SingleChildScrollView(
                    child: RichTextBody(content, gateway: gateway),
                  ),
                ),
              ),
            ),
          ),
        );
        await t.pump(const Duration(milliseconds: 500));
      }

      String content(String suffix, int gatewayPort) =>
          '''
![remote $suffix](http://$_host:18703/img-$suffix.png)

![inline $suffix](data:image/png;base64,${base64Encode(_png)})

<form action="http://$_host:18703/form" method="post"><input name="alpha" value="one two"><input name="beta" value="é&amp;=%"><button>Send external $suffix</button></form>

<form action="http://$_host:$gatewayPort/api/memory/p1/approve" method="post"><button>Send to gateway $suffix</button></form>
''';

      Future<void> exercise(
        String suffix,
        int gatewayPort,
        String token,
      ) async {
        // Attachment upload through the app's own client carries the token and
        // the request-shape header.
        final uploaded = obj(
          await gateway.call('uploadAttachment', {
            'sessionId': 's1',
            'name': 'a.png',
            'mimeType': 'image/png',
            'bytes': Uint8List.fromList(_png),
          }),
        );
        expect(uploaded['id'], 'u-${suffix.toUpperCase()}');
        final upload = (await _log(
          gatewayPort,
        )).lastWhere((e) => (e['path'] as String).endsWith('/uploads'));
        expect(upload['authorization'], 'Bearer $token');
        expect(upload['shape'], '1');

        // Inline image displays; the remote one is a placeholder and nothing
        // reached the receiver before the tap.
        await show(content(suffix, gatewayPort), gatewayPort: gatewayPort);
        await until(
          () async => find.byType(RawImage).evaluate().isNotEmpty,
          'the inline image displays',
        );
        expect(
          (await _log(
            18703,
          )).where((e) => (e['path'] as String).contains('img-$suffix')),
          isEmpty,
        );
        final placeholder = find.byKey(
          const ValueKey('remote-content-placeholder'),
        );
        expect(placeholder, findsOneWidget);
        await t.tap(placeholder);
        await until(
          () async => (await _log(
            18703,
          )).any((e) => (e['path'] as String).contains('img-$suffix')),
          'the tapped image is fetched',
        );
        final fetched = (await _log(
          18703,
        )).where((e) => (e['path'] as String).contains('img-$suffix')).toList();
        expect(fetched, hasLength(1));
        expect(fetched.single['authorization'], isNull);
        expect(fetched.single['cookie'], isNull);
        expect(fetched.single['referer'], isNull);

        // A form to an external receiver delivers its fields, without any
        // credential and with an opaque origin.
        await show(content(suffix, gatewayPort), gatewayPort: gatewayPort);
        await t.tap(
          find.textContaining('Send external $suffix', findRichText: true),
        );
        await until(
          () async => (await _log(
            18703,
          )).any((e) => e['path'] == '/form' && e['method'] == 'POST'),
          'the external form is delivered',
        );
        final form = (await _log(18703)).lastWhere((e) => e['path'] == '/form');
        final fields = Uri.splitQueryString(form['body'] as String);
        expect(fields['alpha'], 'one two');
        expect(fields['beta'], 'é&=%');
        expect(form['authorization'], isNull);
        expect(form['cookie'], isNull);
        expect(form['origin'], anyOf(isNull, 'null'));

        // A form aimed at the paired Gateway changes nothing.
        await show(content(suffix, gatewayPort), gatewayPort: gatewayPort);
        await t.tap(
          find.textContaining('Send to gateway $suffix', findRichText: true),
        );
        await until(
          () async => (await _log(
            gatewayPort,
          )).any((e) => (e['path'] as String).startsWith('/api/memory/')),
          'the gateway-bound form is sent',
        );
        final hit = (await _log(
          gatewayPort,
        )).lastWhere((e) => (e['path'] as String).startsWith('/api/memory/'));
        expect(hit['authorization'], isNull);
        expect(hit['shape'], isNull);
        expect(((await _fixture(gatewayPort))['state'] as Map)['applied'], 0);
      }

      await gateway.call('pair', {'link': _link(18701, _tokenA)});
      await gateway.call('completeOnboarding');
      await exercise('a', 18701, _tokenA);

      final switchedAt = [
        ...await _log(18701),
        ...await _log(18702),
        ...await _log(18703),
      ].map((e) => e['n'] as int).reduce((a, b) => a > b ? a : b);

      await gateway.call('pair', {'link': _link(18702, _tokenB)});
      await exercise('b', 18702, _tokenB);

      // After the switch no request to A carries any credential, and nothing
      // sent to B carries A's. The receiver never saw a credential at all.
      final a = await _log(18701), b = await _log(18702), r = await _log(18703);
      expect(
        a
            .where((e) => (e['n'] as int) > switchedAt)
            .map((e) => e['authorization']),
        everyElement(isNull),
      );
      expect(
        b.map((e) => e['authorization']),
        everyElement(anyOf(isNull, 'Bearer $_tokenB')),
      );
      expect(r.map((e) => e['authorization']), everyElement(isNull));
      expect(
        [...b, ...r].where((e) => '${e['authorization']}'.contains(_tokenA)),
        isEmpty,
        reason: "A's credential never reached B or the receiver",
      );
      expect(
        [...a, ...r]
            .where((e) => (e['n'] as int) > switchedAt)
            .where((e) => '${e['authorization']}'.contains(_tokenB)),
        isEmpty,
        reason: "B's credential never reached A or the receiver",
      );
      windows?.dispose();
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
