import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/html_document_urls.dart';

void main() {
  test('resolves a relative baseHref against the current document URL', () {
    expect(
      resolveNativeDocumentUrl(
        '../assets/site.css',
        'https://example.test/a/b/page.html',
      ),
      'https://example.test/a/assets/site.css',
    );
    expect(
      resolveNativeDocumentUrl('child/page.html', 'https://example.test/a/b/'),
      'https://example.test/a/b/child/page.html',
    );
  });

  test(
    'normalizes scheme, host, default port, and dot segments while preserving escapes',
    () {
      expect(
        resolveNativeDocumentUrl(
          'HTTP://EXAMPLE.TEST:80/a/%7E/./item?x=%7e%2F#raw%7e',
          'https://base.test/',
        ),
        'http://example.test/a/%7E/item?x=%7e%2F#raw%7e',
      );
    },
  );

  test('resolves network-path references with the base scheme', () {
    expect(
      resolveNativeDocumentUrl(
        '//cdn.example.test/assets/app.js?sig=%2F#part',
        'https://example.test/a/page',
      ),
      'https://cdn.example.test/assets/app.js?sig=%2F#part',
    );
  });

  test('preserves repeated slashes and resolves multiple dot segments', () {
    expect(
      resolveNativeDocumentUrl(
        '../../c//d/../',
        'https://example.test/a/b/page',
      ),
      'https://example.test/c//',
    );
    expect(
      resolveNativeDocumentUrl('%2e%2E/c', 'https://example.test/a/b/page'),
      'https://example.test/a/c',
    );
  });

  test(
    'query-only, fragment-only, empty, and empty-query references preserve the right state',
    () {
      const base = 'https://example.test/a/page?old=%7E#history';

      expect(
        resolveNativeDocumentUrl('#next?part=%2f', base),
        'https://example.test/a/page?old=%7E#next?part=%2f',
      );
      expect(
        resolveNativeDocumentUrl('?new=%2F#next', base),
        'https://example.test/a/page?new=%2F#next',
      );
      expect(
        resolveNativeDocumentUrl('', base),
        'https://example.test/a/page?old=%7E',
      );
      expect(
        resolveNativeDocumentUrl('?', base),
        'https://example.test/a/page?',
      );
    },
  );

  test('UTF-8 percent-encodes raw Unicode in path, query, and fragment', () {
    expect(
      resolveNativeDocumentUrl('café?name=頁#章', 'https://example.test/a/page'),
      'https://example.test/a/caf%C3%A9?name=%E9%A0%81#%E7%AB%A0',
    );
  });

  test('trims edge controls and removes navigation tabs and newlines', () {
    expect(
      resolveNativeDocumentUrl(' \t../c\n ', 'https://example.test/a/b/page'),
      'https://example.test/a/c',
    );
  });

  test(
    'rejects unknown schemes and URL forms outside the supported subset',
    () {
      for (final reference in [
        'javascript:alert(1)',
        'mailto:user@example.test',
        'http:relative-path',
        r'..\secret',
        'https://例え.test/path',
        'https://xn--r8jz45g.test/path',
        'https://[::1]/path',
        'https://127.1/path',
        'https://user@example.test/path',
      ]) {
        expect(
          () => resolveNativeDocumentUrl(reference, 'https://example.test/'),
          throwsA(isA<UnsupportedError>()),
          reason: reference,
        );
      }
    },
  );

  test(
    'same-document fragment shortcut requires explicit hash and raw URL equality',
    () {
      expect(
        nativeSameDocumentFragment(
          'https://example.test/a?q=%7E#new',
          'https://example.test/a?q=%7E#old',
        ),
        isTrue,
      );
      expect(
        nativeSameDocumentFragment(
          'https://example.test/a?q=%7E#',
          'https://example.test/a?q=%7E',
        ),
        isTrue,
      );
      expect(
        nativeSameDocumentFragment(
          'https://example.test/a?q=%7E',
          'https://example.test/a?q=%7E',
        ),
        isFalse,
      );
      expect(
        nativeSameDocumentFragment(
          'https://example.test/a?q=~#new',
          'https://example.test/a?q=%7E#old',
        ),
        isFalse,
      );
      expect(
        nativeSameDocumentFragment(
          'https://example.test/a?q=other#new',
          'https://example.test/a?q=%7E#old',
        ),
        isFalse,
      );
    },
  );
}
