import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/document_html_image.dart';

void main() {
  test('HTML image state refers only to an owned decoded image', () {
    final result = decodeNativeDocumentHtmlImages(
      [
        {'id': 'pirc-1', 'status': 'empty'},
        {'id': 'pirc-2', 'status': 'pending'},
        {'id': 'pirc-3', 'status': 'loaded', 'imageId': 'owned-1'},
        {'id': 'pirc-4', 'status': 'loaded', 'imageId': 'owned-svg'},
        {'id': 'pirc-5', 'status': 'error'},
      ],
      available: {'owned-1', 'owned-svg'},
      vectors: {'owned-svg'},
    );
    expect(result['pirc-3']!.imageId, 'owned-1');
    expect(result['pirc-3']!.vector, isFalse);
    expect(result['pirc-4']!.vector, isTrue);
    expect(() => result.clear(), throwsUnsupportedError);
  });
  test(
    'unavailable handles, wrong states and duplicate identities are rejected',
    () {
      for (final input in [
        {},
        [false],
        [
          {'id': 'external', 'status': 'pending'},
        ],
        [
          {'id': 'pirc-1', 'status': 'loaded'},
        ],
        [
          {'id': 'pirc-1', 'status': 'loaded', 'imageId': 'foreign-document'},
        ],
        [
          {'id': 'pirc-1', 'status': 'pending', 'imageId': 'owned-1'},
        ],
        [
          {'id': 'pirc-1', 'status': 'invented'},
        ],
        [
          {'id': 'pirc-1', 'status': 'empty'},
          {'id': 'pirc-1', 'status': 'empty'},
        ],
      ]) {
        expect(
          () => decodeNativeDocumentHtmlImages(input, available: {'owned-1'}),
          throwsFormatException,
          reason: '$input',
        );
      }
    },
  );
  test('HTML image metadata respects the existing 5000-node ceiling', () {
    final valid = [
      for (var i = 1; i <= 5000; i++) {'id': 'pirc-$i', 'status': 'pending'},
    ];
    expect(
      decodeNativeDocumentHtmlImages(valid, available: {}),
      hasLength(5000),
    );
    expect(
      () => decodeNativeDocumentHtmlImages([
        ...valid,
        {'id': 'pirc-5001', 'status': 'pending'},
      ], available: {}),
      throwsFormatException,
    );
  });
}
