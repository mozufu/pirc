import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:pirc_render/src/html_media_spec.dart';

NativeHtmlMediaSpec parseMedia(String source) {
  final document = html.parse(source);
  final element = document.querySelector('audio, video');
  if (element == null) throw StateError('No media element in test source.');
  return NativeHtmlMediaSpec.fromElement(element);
}

void main() {
  test('video src is selected ahead of ordered source children', () {
    final spec = parseMedia('''
      <video src="../clips/direct.mp4">
        <source src="first.webm" type="video/webm; codecs=vp9">
        <source src="second.mp4" type="video/mp4">
      </video>
    ''');

    expect(spec.kind, NativeHtmlMediaKind.video);
    expect(spec.hasSrcAttribute, isTrue);
    expect(spec.srcCandidate?.url, '../clips/direct.mp4');
    expect(
      spec.srcCandidate?.origin,
      NativeHtmlMediaCandidateOrigin.srcAttribute,
    );
    expect(spec.sourceCandidates.map((item) => item.url), [
      'first.webm',
      'second.mp4',
    ]);
    expect(spec.sourceCandidates.map((item) => item.typeHint), [
      'video/webm; codecs=vp9',
      'video/mp4',
    ]);
    expect(spec.candidates, [spec.srcCandidate]);
  });

  test('without src, candidate order follows child source order', () {
    final spec = parseMedia('''
      <audio>
        <source src="first.ogg" type="audio/ogg; codecs=opus">
        <source src="second.mp3" type="audio/mpeg">
      </audio>
    ''');

    expect(spec.kind, NativeHtmlMediaKind.audio);
    expect(spec.hasSrcAttribute, isFalse);
    expect(spec.srcCandidate, isNull);
    expect(spec.candidates, spec.sourceCandidates);
    expect(spec.candidates.map((item) => item.url), [
      'first.ogg',
      'second.mp3',
    ]);
    expect(
      spec.candidates.every(
        (item) => item.origin == NativeHtmlMediaCandidateOrigin.sourceElement,
      ),
      isTrue,
    );
  });

  test('empty src remains distinct and prevents source fallback', () {
    final spec = parseMedia('''
      <video src="">
        <source src="fallback.mp4" type="video/mp4">
      </video>
    ''');

    expect(spec.hasSrcAttribute, isTrue);
    expect(spec.rawSrc, '');
    expect(spec.srcCandidate, isNull);
    expect(spec.sourceCandidates.single.url, 'fallback.mp4');
    expect(spec.candidates, isEmpty);
  });

  test('boolean attributes use presence, not their textual values', () {
    final spec = parseMedia(
      '<video controls="false" autoplay="" muted="0" loop="false"></video>',
    );

    expect(spec.controls, isTrue);
    expect(spec.autoplay, isTrue);
    expect(spec.muted, isTrue);
    expect(spec.loop, isTrue);
  });

  test('missing boolean and preload attributes remain unset', () {
    final spec = parseMedia('<audio></audio>');

    expect(spec.controls, isFalse);
    expect(spec.autoplay, isFalse);
    expect(spec.muted, isFalse);
    expect(spec.loop, isFalse);
    expect(spec.preload, isNull);
  });

  test('preload and relative poster are preserved literally', () {
    final spec = parseMedia(
      '<video preload="metadata" poster="../images/poster.jpg"></video>',
    );

    expect(spec.preload, 'metadata');
    expect(spec.poster, '../images/poster.jpg');
  });

  test(
    'valid dimensions parse as nonnegative integers and retain raw values',
    () {
      final spec = parseMedia('<video width="0" height=" 360 "></video>');

      expect(spec.width, 0);
      expect(spec.height, 360);
      expect(spec.rawWidth, '0');
      expect(spec.rawHeight, ' 360 ');
    },
  );

  test('invalid dimensions keep their raw attributes but are not applied', () {
    final spec = parseMedia('<video width="bad" height="-1"></video>');

    expect(spec.width, isNull);
    expect(spec.height, isNull);
    expect(spec.rawWidth, 'bad');
    expect(spec.rawHeight, '-1');
  });

  test('dimension parsing follows Chrome nonnegative numeric prefix rules', () {
    final suffixed = parseMedia('<video width="12px"></video>');
    expect(suffixed.width, 12);
    expect(suffixed.rawWidth, '12px');

    final signed = parseMedia('<video height="+12"></video>');
    expect(signed.height, isNull);

    final unicodeWhitespace = parseMedia(
      '<video width="\u00a012\u00a0"></video>',
    );
    expect(unicodeWhitespace.width, isNull);
  });

  test(
    'unsafe direct src throws instead of falling through to source children',
    () {
      expect(
        () => parseMedia('''
        <video src="javascript:alert(1)">
          <source src="safe.mp4" type="video/mp4">
        </video>
      '''),
        throwsA(isA<FormatException>()),
      );
    },
  );

  test('unsafe child source is diagnosed and omitted from candidates', () {
    final spec = parseMedia('''
      <video>
        <source src="file:///private/video.mp4" type="video/mp4">
        <source src="safe.mp4" type="video/mp4">
      </video>
    ''');

    expect(spec.candidates.map((item) => item.url), ['safe.mp4']);
    expect(spec.diagnostics, hasLength(1));
    expect(spec.diagnostics.single.location, 'source[0].src');
    expect(spec.diagnostics.single.value, 'file:///private/video.mp4');
  });

  test('unsafe poster is omitted and reported', () {
    final spec = parseMedia('<video poster="javascript:alert(1)"></video>');

    expect(spec.poster, isNull);
    expect(spec.diagnostics, hasLength(1));
    expect(spec.diagnostics.single.location, 'poster');
  });

  test('inert media data URLs are allowed while data HTML is rejected', () {
    final spec = parseMedia('<audio src="data:audio/ogg;base64,AAAA"></audio>');
    expect(spec.srcCandidate?.url, 'data:audio/ogg;base64,AAAA');

    expect(
      () => parseMedia('<audio src="data:text/html,<script>"></audio>'),
      throwsA(isA<FormatException>()),
    );
  });

  test('source children are limited to direct children in DOM order', () {
    final spec = parseMedia('''
      <video>
        <source src="first.mp4" type="video/mp4">
        <span><source src="nested.mp4" type="video/mp4"></span>
        <source src="last.webm" type="video/webm">
      </video>
    ''');

    expect(spec.candidates.map((item) => item.url), ['first.mp4', 'last.webm']);
  });

  test('unsupported element names are rejected', () {
    expect(
      () => NativeHtmlMediaSpec.fromElement(
        html.parse('<img>').querySelector('img')!,
      ),
      throwsA(isA<FormatException>()),
    );
  });
}
