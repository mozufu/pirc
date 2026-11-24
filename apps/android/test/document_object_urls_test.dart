import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/document_object_urls.dart';
import 'package:pirc_mobile/live/gateway.dart' show Json;

Json bridgeValue(
  String url,
  List<int> bytes, {
  String type = 'application/octet-stream',
  bool ok = true,
  int? size,
  String? bytesBase64,
}) => {
  'ok': ok,
  'url': url,
  'type': type,
  'size': size ?? bytes.length,
  'bytesBase64': bytesBase64 ?? base64Encode(bytes),
};

void main() {
  group('NativeDocumentBlob.fromBridge', () {
    test('accepts exact 2 MiB bridge bytes without truncation', () {
      const url = 'blob:https://example.test/maximum';
      final bytes = Uint8List(NativeDocumentBlob.maxBytes);
      for (var i = 0; i < bytes.length; i++) {
        bytes[i] = i % 256;
      }
      final blob = NativeDocumentBlob.fromBridge(url, bridgeValue(url, bytes));
      expect(blob.bytes, bytes);
    });

    test(
      'accepts fragment-stripped bridge URLs and returns owned byte copies',
      () {
        const url = 'blob:https://example.test/document-token-1';
        final bytes = [0x00, 0x41, 0xff, 0x80];
        final blob = NativeDocumentBlob.fromBridge(
          '$url#preview',
          bridgeValue(url, bytes, type: 'image/x-pirc'),
        );

        expect(blob.url, url);
        expect(blob.mimeType, 'image/x-pirc');
        expect(blob.bytes, bytes);
        final exposed = blob.bytes;
        exposed[0] = 99;
        expect(blob.bytes, bytes);
      },
    );

    test('rejects an unavailable, foreign, or non-blob bridge response', () {
      const requestedUrl = 'blob:https://example.test/document-token-1';
      expect(
        () => NativeDocumentBlob.fromBridge(
          requestedUrl,
          bridgeValue(requestedUrl, [1], ok: false),
        ),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => NativeDocumentBlob.fromBridge(
          requestedUrl,
          bridgeValue('blob:https://other.test/foreign-token', [1]),
        ),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => NativeDocumentBlob.fromBridge(
          'https://example.test/file',
          bridgeValue('https://example.test/file', [1]),
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test(
      'rejects malformed metadata and non-canonical or mismatched base64',
      () {
        const url = 'blob:https://example.test/document-token-1';
        final invalidValues = <Json>[
          {'ok': true, 'url': url, 'type': 1, 'size': 0, 'bytesBase64': ''},
          {
            'ok': true,
            'url': url,
            'type': 'text/plain',
            'size': -1,
            'bytesBase64': '',
          },
          {
            'ok': true,
            'url': url,
            'type': 'text/plain',
            'size': 1,
            'bytesBase64': 'YQ',
          },
          {
            'ok': true,
            'url': url,
            'type': 'text/plain',
            'size': 1,
            'bytesBase64': 'AB==',
          },
          {
            'ok': true,
            'url': url,
            'type': 'text/plain',
            'size': 2,
            'bytesBase64': 'YQ==',
          },
        ];
        for (final value in invalidValues) {
          expect(
            () => NativeDocumentBlob.fromBridge(url, value),
            throwsA(isA<FormatException>()),
          );
        }
      },
    );

    test('rejects oversized metadata before decoding its bytes', () {
      const url = 'blob:https://example.test/document-token-1';
      expect(
        () => NativeDocumentBlob.fromBridge(url, {
          'ok': true,
          'url': url,
          'type': 'application/octet-stream',
          'size': NativeDocumentBlob.maxBytes + 1,
          'bytesBase64': '',
        }),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('NativeDocumentObjectUrlBinding', () {
    const url = 'blob:https://example.test/document-token-2';
    final bytes = [0x00, 0xc3, 0xa9, 0xff];

    test(
      'reads only the blob URL and preserves fragment-stripped metadata',
      () async {
        final owner = Object();
        var requestedUrl = '';
        final binding = NativeDocumentObjectUrlBinding(
          owner: owner,
          isCurrent: () => true,
          readBytes: (value) async {
            requestedUrl = value;
            return bridgeValue(url, bytes, type: 'image/png');
          },
        );

        expect(binding.current, isTrue);
        final blob = await binding.read('$url#preview');
        expect(requestedUrl, '$url#preview');
        expect(blob.url, url);
        expect(blob.mimeType, 'image/png');
        expect(blob.bytes, bytes);
      },
    );

    test('rejects non-blob URLs before invoking the bridge', () async {
      var calls = 0;
      final binding = NativeDocumentObjectUrlBinding(
        owner: Object(),
        isCurrent: () => true,
        readBytes: (_) async {
          calls += 1;
          return bridgeValue(url, bytes);
        },
      );

      await expectLater(
        binding.read('https://example.test/image.png'),
        throwsA(isA<StateError>()),
      );
      expect(calls, 0);
    });

    test('rejects stale bindings before starting a bridge read', () async {
      var current = false;
      var calls = 0;
      final binding = NativeDocumentObjectUrlBinding(
        owner: Object(),
        isCurrent: () => current,
        readBytes: (_) async {
          calls += 1;
          return bridgeValue(url, bytes);
        },
      );

      expect(binding.current, isFalse);
      await expectLater(binding.read(url), throwsA(isA<StateError>()));
      expect(calls, 0);
    });

    test(
      'rejects a result if the document becomes stale while bytes are pending',
      () async {
        var current = true;
        final pending = Completer<Json>();
        final binding = NativeDocumentObjectUrlBinding(
          owner: Object(),
          isCurrent: () => current,
          readBytes: (_) => pending.future,
        );

        final read = binding.read(url);
        current = false;
        pending.complete(bridgeValue(url, bytes));
        await expectLater(read, throwsA(isA<StateError>()));
      },
    );

    test('rejects bridge results for a foreign URL', () async {
      final binding = NativeDocumentObjectUrlBinding(
        owner: Object(),
        isCurrent: () => true,
        readBytes: (_) async =>
            bridgeValue('blob:https://other.test/foreign-token', bytes),
      );

      await expectLater(binding.read(url), throwsA(isA<FormatException>()));
    });
  });

  group('activation-captured Blob navigation', () {
    const url = 'blob:https://example.test/activation';
    test(
      'initial navigation survives revoke but reload rechecks the live registry',
      () async {
        final captured = NativeDocumentBlob.fromBridge(
          url,
          bridgeValue(url, [0, 255, 17]),
        );
        var reads = 0;
        final source = NativeDocumentBlobNavigationSource(
          creatorUrl: 'https://example.test/source',
          initialBlob: captured,
          binding: NativeDocumentObjectUrlBinding(
            owner: Object(),
            isCurrent: () => true,
            readBytes: (_) async {
              reads++;
              throw const FormatException('revoked');
            },
          ),
        );
        expect((await source.read('$url#part')).bytes, [0, 255, 17]);
        expect(reads, 0);
        await expectLater(source.read(url), throwsA(isA<FormatException>()));
        expect(reads, 1);
      },
    );
    test('captured bytes cannot bypass invalidated ownership', () async {
      final source = NativeDocumentBlobNavigationSource(
        creatorUrl: 'https://example.test/source',
        initialBlob: NativeDocumentBlob.fromBridge(url, bridgeValue(url, [1])),
        binding: NativeDocumentObjectUrlBinding(
          owner: Object(),
          isCurrent: () => false,
          readBytes: (_) async => throw StateError('must not read'),
        ),
      );
      await expectLater(source.read(url), throwsA(isA<StateError>()));
    });
    test('captured bytes cannot bypass creator-origin validation', () async {
      const foreign = 'blob:https://other.test/activation';
      final source = NativeDocumentBlobNavigationSource(
        creatorUrl: 'https://example.test/source',
        initialBlob: NativeDocumentBlob.fromBridge(
          foreign,
          bridgeValue(foreign, [1]),
        ),
        binding: NativeDocumentObjectUrlBinding(
          owner: Object(),
          isCurrent: () => true,
          readBytes: (_) async => throw StateError('must not read'),
        ),
      );
      await expectLater(source.read(foreign), throwsA(isA<FormatException>()));
    });
  });

  group('NativeDocumentBlobNavigationSource', () {
    const url = 'blob:https://example.test/navigation-token';
    const bytes = [0x00, 0xc3, 0xa9, 0xff];

    test(
      'accepts matching normalized HTTP and single-layer blob origins',
      () async {
        for (final creatorUrl in [
          'https://EXAMPLE.test:443/source/page',
          'blob:https://example.test/creator-token',
        ]) {
          var calls = 0;
          final source = NativeDocumentBlobNavigationSource(
            creatorUrl: creatorUrl,
            binding: NativeDocumentObjectUrlBinding(
              owner: Object(),
              isCurrent: () => true,
              readBytes: (requested) async {
                calls++;
                return bridgeValue(requested, bytes, type: 'text/plain');
              },
            ),
          );

          final blob = await source.read(url);
          expect(blob.bytes, bytes);
          expect(blob.mimeType, 'text/plain');
          expect(calls, 1);
        }
      },
    );

    test('permits a fragment while reading the underlying blob URL', () async {
      const urlWithFragment = '$url#section';
      var requested = '';
      final source = NativeDocumentBlobNavigationSource(
        creatorUrl: 'https://example.test/source',
        binding: NativeDocumentObjectUrlBinding(
          owner: Object(),
          isCurrent: () => true,
          readBytes: (value) async {
            requested = value;
            return bridgeValue(url, bytes);
          },
        ),
      );

      final blob = await source.read(urlWithFragment);
      expect(requested, urlWithFragment);
      expect(blob.url, url);
      expect(blob.bytes, bytes);
    });

    test('origin mismatch is rejected before the bridge is called', () async {
      var calls = 0;
      final source = NativeDocumentBlobNavigationSource(
        creatorUrl: 'https://example.test/source',
        binding: NativeDocumentObjectUrlBinding(
          owner: Object(),
          isCurrent: () => true,
          readBytes: (_) async {
            calls++;
            return bridgeValue(url, bytes);
          },
        ),
      );

      await expectLater(
        source.read('blob:https://other.test/foreign-token'),
        throwsA(isA<FormatException>()),
      );
      expect(calls, 0);
    });

    test(
      'rejects unsupported, credentialed, and nested blob origins',
      () async {
        var calls = 0;
        final binding = NativeDocumentObjectUrlBinding(
          owner: Object(),
          isCurrent: () => true,
          readBytes: (_) async {
            calls++;
            return bridgeValue(url, bytes);
          },
        );

        for (final creatorUrl in [
          '',
          'file:///tmp/source.html',
          'https://user:pass@example.test/source',
          'blob:null/creator-token',
          'blob:blob:https://example.test/nested-token',
        ]) {
          await expectLater(
            NativeDocumentBlobNavigationSource(
              creatorUrl: creatorUrl,
              binding: binding,
            ).read(url),
            throwsA(isA<FormatException>()),
            reason: 'creator URL should be rejected: $creatorUrl',
          );
        }

        final source = NativeDocumentBlobNavigationSource(
          creatorUrl: 'https://example.test/source',
          binding: binding,
        );
        for (final requestedUrl in [
          'https://example.test/image.png',
          'blob:null/object-token',
          'blob:blob:https://example.test/nested-token',
          'blob:https://user:pass@example.test/credentialed-token',
          'blob:https://example.test:8443/other-origin-token',
        ]) {
          await expectLater(
            source.read(requestedUrl),
            throwsA(isA<FormatException>()),
            reason: 'requested URL should be rejected: $requestedUrl',
          );
        }
        expect(calls, 0);
      },
    );

    test('re-reads the creator registry and observes revocation', () async {
      var calls = 0;
      final source = NativeDocumentBlobNavigationSource(
        creatorUrl: 'https://example.test/source',
        binding: NativeDocumentObjectUrlBinding(
          owner: Object(),
          isCurrent: () => true,
          readBytes: (_) async {
            calls++;
            if (calls == 1) return bridgeValue(url, bytes);
            return bridgeValue(url, const [], ok: false);
          },
        ),
      );

      expect((await source.read(url)).bytes, bytes);
      await expectLater(source.read(url), throwsA(isA<FormatException>()));
      expect(calls, 2);
    });

    test(
      'rejects a bridge result after the creator account becomes stale',
      () async {
        var current = true;
        final pending = Completer<Json>();
        final source = NativeDocumentBlobNavigationSource(
          creatorUrl: 'https://example.test/source',
          binding: NativeDocumentObjectUrlBinding(
            owner: Object(),
            isCurrent: () => current,
            readBytes: (_) => pending.future,
          ),
        );

        final read = source.read(url);
        current = false;
        pending.complete(bridgeValue(url, bytes));
        await expectLater(read, throwsA(isA<StateError>()));
      },
    );
  });

  group('nativeBlobNavigationReferrer', () {
    const sourceUrl = 'https://EXAMPLE.test:443/path/page?q=1#section';
    const sourceWithoutFragment = 'https://EXAMPLE.test:443/path/page?q=1';

    test('uses the last valid comma-separated header policy', () {
      expect(
        nativeBlobNavigationReferrer(
          sourceUrl: sourceUrl,
          html: '',
          headerPolicy: 'no-referrer, invalid-policy, origin',
        ),
        'https://example.test/',
      );
    });

    test('last valid meta policy overrides the header', () {
      const markup = '''
        <meta name="referrer" content="no-referrer">
        <meta name="REFERRER" content="unsafe-url">
        <meta name="referrer" content="not-a-policy">
      ''';

      expect(
        nativeBlobNavigationReferrer(
          sourceUrl: sourceUrl,
          html: markup,
          headerPolicy: 'no-referrer',
        ),
        sourceWithoutFragment,
      );
    });

    test('valid element policy overrides both meta and header', () {
      expect(
        nativeBlobNavigationReferrer(
          sourceUrl: sourceUrl,
          html: '<meta name="referrer" content="no-referrer">',
          headerPolicy: 'strict-origin',
          elementPolicy: 'unsafe-url',
        ),
        sourceWithoutFragment,
      );
    });

    test('ignores invalid element, meta, and header policies', () {
      expect(
        nativeBlobNavigationReferrer(
          sourceUrl: sourceUrl,
          html: '<meta name="referrer" content="bad-policy">',
          headerPolicy: 'also-invalid',
          elementPolicy: 'invalid',
        ),
        sourceWithoutFragment,
      );
      expect(
        nativeBlobNavigationReferrer(
          sourceUrl: sourceUrl,
          html: '<meta name="referrer" content="bad-policy">',
          headerPolicy: 'origin',
          elementPolicy: 'invalid',
        ),
        'https://example.test/',
      );
    });

    test('noreferrer overrides every policy and returns an empty referrer', () {
      expect(
        nativeBlobNavigationReferrer(
          sourceUrl: sourceUrl,
          html: '<meta name="referrer" content="unsafe-url">',
          headerPolicy: 'unsafe-url',
          elementPolicy: 'unsafe-url',
          noreferrer: true,
        ),
        '',
      );
    });

    test('origin-only policies return the source origin with a slash', () {
      expect(
        nativeBlobNavigationReferrer(
          sourceUrl: 'https://example.test:8443/path#fragment',
          html: '',
          elementPolicy: 'strict-origin',
        ),
        'https://example.test:8443/',
      );
      expect(
        nativeBlobNavigationReferrer(
          sourceUrl: 'http://example.test:80/path',
          html: '',
          elementPolicy: 'origin',
        ),
        'http://example.test/',
      );
    });

    test('default same-origin policy strips only the source fragment', () {
      expect(
        nativeBlobNavigationReferrer(sourceUrl: sourceUrl, html: ''),
        sourceWithoutFragment,
      );
    });

    test('non-HTTP and credentialed source URLs produce no referrer', () {
      for (final invalidSource in [
        'blob:https://example.test/source-token',
        'file:///tmp/document.html',
        'https://user:pass@example.test/private',
      ]) {
        expect(
          nativeBlobNavigationReferrer(
            sourceUrl: invalidSource,
            html: '',
            elementPolicy: 'unsafe-url',
          ),
          '',
          reason: invalidSource,
        );
      }
    });
  });

  group('NativeDocumentBlobNavigationSource.documentReferrer', () {
    NativeDocumentBlobNavigationSource source({
      required String creatorUrl,
      String? referrer,
    }) => NativeDocumentBlobNavigationSource(
      creatorUrl: creatorUrl,
      referrer: referrer,
      binding: NativeDocumentObjectUrlBinding(
        owner: Object(),
        isCurrent: () => true,
        readBytes: (_) async =>
            bridgeValue('blob:https://example.test/referrer-token', const []),
      ),
    );

    test('defaults to a fragment-free HTTP creator URL', () {
      expect(
        source(
          creatorUrl: 'https://example.test/page?q=1#section',
        ).documentReferrer,
        'https://example.test/page?q=1',
      );
    });

    test('blob creator and explicit empty referrer stay empty', () {
      expect(
        source(
          creatorUrl: 'blob:https://example.test/creator-token',
        ).documentReferrer,
        '',
      );
      expect(
        source(
          creatorUrl: 'https://example.test/page#section',
          referrer: '',
        ).documentReferrer,
        '',
      );
    });
  });

  testWidgets('scope exposes its binding only below its inherited widget', (
    tester,
  ) async {
    final binding = NativeDocumentObjectUrlBinding(
      owner: Object(),
      isCurrent: () => true,
      readBytes: (_) async =>
          bridgeValue('blob:https://example.test/scope-token', []),
    );
    NativeDocumentObjectUrlScope? outside;
    NativeDocumentObjectUrlScope? inside;

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Builder(
          builder: (context) {
            outside = NativeDocumentObjectUrlScope.maybeOf(context);
            return NativeDocumentObjectUrlScope(
              binding: binding,
              child: Builder(
                builder: (context) {
                  inside = NativeDocumentObjectUrlScope.maybeOf(context);
                  return const SizedBox();
                },
              ),
            );
          },
        ),
      ),
    );

    expect(outside, isNull);
    expect(identical(inside?.binding, binding), isTrue);
  });
}
