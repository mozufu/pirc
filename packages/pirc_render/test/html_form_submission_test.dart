import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/html_form_submission.dart';

void main() {
  group('nativeHtmlFormEncode', () {
    test('uses the HTML form safe set, plus for space, and UTF-8 bytes', () {
      expect(
        nativeHtmlFormEncode(const [NativeHtmlFormEntry('a b+&~!', '雪 猫+!~&')]),
        'a+b%2B%26%7E%21=%E9%9B%AA+%E7%8C%AB%2B%21%7E%26',
      );
    });

    test('normalizes CR and LF in both names and values to CRLF', () {
      expect(
        nativeHtmlFormEncode(const [
          NativeHtmlFormEntry('n\rx\n\r\ny', 'a\rb\nc\r\nd'),
        ]),
        'n%0D%0Ax%0D%0A%0D%0Ay=a%0D%0Ab%0D%0Ac%0D%0Ad',
      );
    });

    test('preserves entry order and repeated names', () {
      expect(
        nativeHtmlFormEncode(const [
          NativeHtmlFormEntry('tag', 'one'),
          NativeHtmlFormEntry('tag', 'two'),
          NativeHtmlFormEntry('', ''),
        ]),
        'tag=one&tag=two&=',
      );
    });
  });

  group('forged encodings and methods', () {
    const standardTypes = {
      'application/x-www-form-urlencoded',
      'text/plain',
      'multipart/form-data',
    };
    final entries = const [NativeHtmlFormEntry('a', '1')];

    test(
      'content cannot choose an encoding outside the three standard ones',
      () {
        for (final forged in [
          'application/json',
          'APPLICATION/JSON',
          'application/json; charset=utf-8',
          'text/html',
          'application/octet-stream',
          'text/plain; boundary=x',
          ' text/plain\r\nX-Pirc-Request: 1',
          'application/x-www-form-urlencoded, application/json',
          '',
          'x' * 5000,
        ]) {
          final request = _submission(
            action: '/submit',
            method: 'post',
            enctype: forged,
            entries: entries,
          ).buildRequest();
          final type = request.contentType!.split(';').first;
          expect(
            standardTypes,
            contains(type),
            reason:
                'enctype "${forged.replaceAll('\r\n', ' ')}" produced $type',
          );
          expect(request.contentType, isNot(contains('json')));
          expect(request.contentType, isNot(contains('\n')));
        }
      },
    );

    test(
      'odd casing of a standard encoding is normalised, not passed through',
      () {
        expect(
          _submission(
            action: '/s',
            method: 'POST',
            enctype: 'TEXT/PLAIN',
            entries: entries,
          ).buildRequest().contentType,
          'text/plain',
        );
        expect(
          _submission(
            action: '/s',
            method: 'Post',
            enctype: 'Multipart/Form-Data',
            entries: entries,
          ).buildRequest().contentType,
          startsWith('multipart/form-data; boundary='),
        );
      },
    );

    test('only GET and POST can come out of a method attribute', () {
      for (final forged in [
        'put',
        'PUT',
        'delete',
        'patch',
        'head',
        'options',
        'trace',
        'connect',
        '',
        ' post',
        'post ',
        'po\u0073t\u0000',
        'get\r\nX-Pirc-Request: 1',
      ]) {
        final request = _submission(
          action: '/s',
          method: forged,
          entries: entries,
        ).buildRequest();
        expect(
          ['GET', 'POST'],
          contains(request.method),
          reason: 'method "$forged"',
        );
      }
      expect(
        _submission(
          action: '/s',
          method: 'post',
          entries: entries,
        ).buildRequest().method,
        'POST',
      );
      expect(
        () => _submission(
          action: '/s',
          method: 'dialog',
          entries: entries,
        ).buildRequest(),
        throwsUnsupportedError,
      );
    });

    test(
      'a request carries no header field, only url, method, body and type',
      () {
        final request = _submission(
          action: '/s',
          method: 'post',
          enctype: 'application/json',
          entries: const [NativeHtmlFormEntry('X-Pirc-Request', '1')],
        ).buildRequest();
        // A control named like a header is only form data in the body.
        expect(request.body, 'X-Pirc-Request=1');
        expect(request.contentType, 'application/x-www-form-urlencoded');
      },
    );
  });

  group('NativeHtmlFormSubmission.buildRequest', () {
    test('GET replaces a relative action query and keeps its fragment', () {
      final request = _submission(
        action: '../search?old=1&keep=2#section',
        entries: const [NativeHtmlFormEntry('q', 'a b')],
      ).buildRequest();

      expect(request.url, '../search?q=a+b#section');
      expect(request.method, 'GET');
      expect(request.query, 'q=a+b');
      expect(request.body, isNull);
      expect(request.contentType, isNull);
    });

    test('blank action stays blank until caller supplies the document URL', () {
      final submission = _submission(
        action: '',
        entries: const [NativeHtmlFormEntry('q', 'cat')],
      );

      final unresolved = submission.buildRequest();
      expect(unresolved.url, '');
      expect(unresolved.query, 'q=cat');

      final resolved = submission.buildRequest(
        documentUrl: 'https://example.test/find?old=1#results',
      );
      expect(resolved.url, 'https://example.test/find?q=cat#results');
    });

    test('POST exposes encoded body and form content type', () {
      final request = _submission(
        action: '/submit?keep=1',
        method: 'post',
        entries: const [NativeHtmlFormEntry('a', 'x y')],
        target: 'result',
        submitterId: 'save',
      ).buildRequest();

      expect(request.url, '/submit?keep=1');
      expect(request.method, 'POST');
      expect(request.body, 'a=x+y');
      expect(request.contentType, 'application/x-www-form-urlencoded');
      expect(request.target, 'result');
      expect(request.submitterId, 'save');
      expect(request.query, isNull);
    });

    test('missing or invalid method and enctype use HTML defaults', () {
      final request = _submission(
        action: '/submit',
        method: 'unknown',
        enctype: 'unknown',
        entries: const [NativeHtmlFormEntry('x', '1')],
      ).buildRequest();

      expect(request.method, 'GET');
      expect(request.url, '/submit?x=1');
    });

    test('POST text/plain and multipart build transport-ready bodies', () {
      for (final enctype in ['text/plain', 'multipart/form-data']) {
        final request = _submission(
          action: '/submit',
          method: 'post',
          enctype: enctype,
          entries: const [NativeHtmlFormEntry('message', 'hello')],
        ).buildRequest();
        expect(request.method, 'POST');
        expect(request.contentType, startsWith(enctype));
        if (enctype == 'text/plain') {
          expect(request.body, 'message=hello\r\n');
          expect(request.bodyBytes, isNull);
        } else {
          expect(request.body, isNull);
          expect(request.bodyBytes, isNotEmpty);
        }
      }
    });

    test('copies and freezes ordered entries', () {
      final entries = <NativeHtmlFormEntry>[
        const NativeHtmlFormEntry('first', '1'),
      ];
      final submission = _submission(action: '/submit', entries: entries);
      entries.add(const NativeHtmlFormEntry('second', '2'));

      expect(submission.entries, hasLength(1));
      expect(
        () => submission.entries.add(const NativeHtmlFormEntry('x', '3')),
        throwsUnsupportedError,
      );
    });
  });
}

NativeHtmlFormSubmission _submission({
  required String action,
  String method = 'get',
  String enctype = 'application/x-www-form-urlencoded',
  String target = '',
  required Iterable<NativeHtmlFormEntry> entries,
  String? submitterId,
}) => NativeHtmlFormSubmission(
  action: action,
  method: method,
  enctype: enctype,
  target: target,
  entries: entries,
  submitterId: submitterId,
);
