import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_mobile/live/document_referrer.dart';

void main() {
  final oracle =
      jsonDecode(
            File(
              '../../packages/pirc_render/test/fixtures/parity/document-referrer-chromium153.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  for (final raw in oracle['cases'] as List) {
    final entry = raw as Map<String, dynamic>;
    test(
      'offline policy matches actual Chromium 153 navigation: ${entry['caseId']}',
      () {
        final meta = entry['metaPolicy'] as String?;
        var policy = NativeDocumentReferrer.fromDocument(
          url: entry['sourceUrl'] as String,
          source: meta == null ? '' : '<meta name="referrer" content="$meta">',
          headerPolicy: entry['headerPolicy'] as String?,
          elementPolicy: entry['elementPolicy'] as String?,
          noreferrer: (entry['rel'] as String? ?? '')
              .split(' ')
              .contains('noreferrer'),
        );
        final hops = entry['requestHops'] as List;
        expect(hops, isNotEmpty);
        for (final rawHop in hops) {
          final hop = rawHop as Map<String, dynamic>;
          final target = hop['url'] as String;
          final actual = policy.forTarget(target);
          expect(actual, hop['referer'], reason: 'hop ${hop['hop']}');
          if (hop['documentReferrer'] != null) {
            expect(
              actual,
              hop['documentReferrer'],
              reason: 'final document.referrer',
            );
          }
          policy = policy.afterRequestTo(
            target,
            responsePolicy: hop['responseReferrerPolicy'] as String?,
          );
        }
      },
    );
  }

  const source = 'https://example.test/page?query=1#private-fragment';
  const full = 'https://example.test/page?query=1';
  const origin = 'https://example.test/';
  const policies = {
    'no-referrer': ['', '', ''],
    'no-referrer-when-downgrade': [full, full, ''],
    'origin': [origin, origin, origin],
    'origin-when-cross-origin': [full, origin, origin],
    'same-origin': [full, '', ''],
    'strict-origin': [origin, origin, ''],
    'strict-origin-when-cross-origin': [full, origin, ''],
    'unsafe-url': [full, full, full],
  };
  for (final entry in policies.entries) {
    test('offline ${entry.key}: same/cross/downgrade', () {
      final policy = NativeDocumentReferrer(source, entry.key);
      expect([
        policy.forTarget('https://example.test/to'),
        policy.forTarget('https://other.test/to'),
        policy.forTarget('http://other.test/to'),
      ], entry.value);
    });
  }
  test('policy precedence and unknown tokens', () {
    NativeDocumentReferrer parse({String? element, bool no = false}) =>
        NativeDocumentReferrer.fromDocument(
          url: source,
          headerPolicy: 'no-referrer, origin, unknown',
          source:
              '<meta name="referrer" content="same-origin">'
              '<meta name="REFERRER" content="unknown">',
          elementPolicy: element,
          noreferrer: no,
        );
    expect(parse().policy, 'same-origin');
    expect(parse(element: ' UNSAFE-URL ').policy, 'unsafe-url');
    expect(parse(element: 'origin,unsafe-url').policy, 'same-origin');
    expect(parse(element: 'unsafe-url', no: true).policy, 'no-referrer');
    expect(
      NativeDocumentReferrer.fromDocument(
        url: source,
        headerPolicy: 'ORIGIN',
      ).policy,
      'origin',
    );
  });
  test('credentials/fragment stripped; long URL reduced to origin', () {
    expect(
      const NativeDocumentReferrer(
        'https://user:secret@example.test/p?q=1#s',
        'unsafe-url',
      ).forTarget('https://other.test/'),
      'https://example.test/p?q=1',
    );
    expect(
      NativeDocumentReferrer(
        'https://example.test/${'x' * 4100}',
        'unsafe-url',
      ).forTarget('https://example.test/'),
      origin,
    );
    expect(
      const NativeDocumentReferrer(
        'https://example.test',
        'unsafe-url',
      ).forTarget('https://example.test/'),
      origin,
    );
  });
  test('local schemes never become referrers', () {
    for (final url in [
      'blob:https://example.test/id',
      'data:text/plain,x',
      'file:///private/path',
      'about:blank',
      'relative',
    ]) {
      expect(
        NativeDocumentReferrer(
          url,
          'unsafe-url',
        ).forTarget('https://example.test/'),
        '',
      );
    }
  });
  test('redirect policies cannot recover a removed source or path', () {
    const policy = NativeDocumentReferrer(source, 'same-origin');
    final reduced = policy.afterRequestTo(
      'https://other.test/',
      responsePolicy: 'unknown, UNSAFE-URL',
    );
    expect(reduced.policy, 'unsafe-url');
    expect(reduced.forTarget('https://example.test/'), '');
    const originPolicy = NativeDocumentReferrer(source, 'origin');
    expect(
      originPolicy
          .afterRequestTo('https://other.test/', responsePolicy: 'unsafe-url')
          .forTarget('https://example.test/'),
      origin,
    );
  });
  test('4096 source length boundary and invalid targets', () {
    final exact = 'https://example.test/${'x' * (4096 - origin.length)}';
    expect(exact.length, 4096);
    expect(
      NativeDocumentReferrer(exact, 'unsafe-url').forTarget(origin),
      exact,
    );
    expect(
      NativeDocumentReferrer('${exact}x', 'unsafe-url').forTarget(origin),
      origin,
    );
    for (final destination in ['https:opaque', 'relative', 'file:///p']) {
      expect(
        const NativeDocumentReferrer(
          source,
          'unsafe-url',
        ).forTarget(destination),
        '',
      );
    }
  });
  test('loopback and localhost are potentially trustworthy', () {
    const policy = NativeDocumentReferrer(source, 'strict-origin');
    for (final target in [
      'http://localhost:8080/',
      'http://127.0.0.1/',
      'http://127.3.4.5/',
      'http://[::1]/',
      'http://sub.localhost/',
    ]) {
      expect(policy.forTarget(target), origin, reason: target);
    }
    for (final target in ['http://localhost.evil.test/', 'http://128.0.0.1/']) {
      expect(policy.forTarget(target), '', reason: target);
    }
    expect(
      const NativeDocumentReferrer(
        'http://127.0.0.1/private',
        'strict-origin',
      ).forTarget('http://example.test/'),
      '',
    );
  });
}
