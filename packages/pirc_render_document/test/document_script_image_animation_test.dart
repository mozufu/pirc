@Tags(['tier3'])
library;

import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render_document/src/document_script_images.dart';

void main() {
  testWidgets('animated decoded versions retain the HTML animation provider', (
    t,
  ) async {
    await t.runAsync(() async {
      final pool = NativeDocumentImagePool(
        release: (image) async => image.dispose(),
      );
      try {
        final result = await pool.decode(
          'image-1',
          Uint8List.fromList(
            base64Decode(
              'R0lGODlhAQABAIAAAP8AAAAA/yH5BAABAAAALAAAAAABAAEAAAICRAEAIfkEAAEAAAAsAAAAAAEAAQAAAgJMAQA7',
            ),
          ),
          'image/gif',
          originClean: true,
        );
        expect(pool.animatedImageIds, {result['imageId']});
        expect(pool.vectorImageIds, isEmpty);
        expect(pool.images[result['imageId']]!.width, 1);
      } finally {
        pool.dispose();
      }
    });
  });
}
