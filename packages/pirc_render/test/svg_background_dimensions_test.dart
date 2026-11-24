import 'dart:convert';
import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/svg_background_dimensions.dart';

final _reference =
    jsonDecode(
          File(
            '../../fixtures/mobile-parity/svg-backgrounds.json',
          ).readAsStringSync(),
        )
        as Map<String, dynamic>;
final _assets = (_reference['reference']['svgAssets'] as Map<String, dynamic>);
final _cases = (_reference['cases'] as List).cast<Map<String, dynamic>>();

void main() {
  const box = Size(120, 80);

  test('CSS auto sizing matches measured local Chrome tile dimensions', () {
    for (final item in _cases) {
      final expected =
          item['autoTileSizeFromRenderedColorBoundaries']
              as Map<String, dynamic>?;
      if (expected == null) continue;

      final source = _assets[item['svgAsset']]! as String;
      final dimensions = NativeSvgBackgroundDimensions.fromSource(source);
      expect(
        dimensions.sizeFor(box),
        Size(
          (expected['width'] as num).toDouble(),
          (expected['height'] as num).toDouble(),
        ),
        reason: item['id'] as String,
      );
    }
  });

  test('viewBox-only auto uses the positioning-area ratio constraint', () {
    final source = _assets['viewboxOnly']! as String;
    final dimensions = NativeSvgBackgroundDimensions.fromSource(source);

    // The SVG image's natural fallback size is 300x150, but Chrome paints the
    // CSS auto background tile as 120x60 in this 120x80 positioning area.
    expect(dimensions.intrinsicSize, const Size(300, 150));
    expect(dimensions.viewBoxSize, const Size(40, 20));
    expect(dimensions.aspectRatio, 2);
    expect(dimensions.sizeFor(box), const Size(120, 60));
  });

  test('background cover and contain resolve intrinsic dimensions', () {
    final dimensions = NativeSvgBackgroundDimensions.fromSource(
      _assets['fixed']! as String,
    );
    expect(dimensions.sizeFor(box, fit: BoxFit.cover), const Size(160, 80));
    expect(dimensions.sizeFor(box, fit: BoxFit.contain), const Size(120, 60));
    expect(dimensions.sizeFor(box, fit: BoxFit.fill), box);
  });

  test(
    'no-ratio SVGs use the box for a missing auto axis and contain/cover',
    () {
      final widthOnly = NativeSvgBackgroundDimensions.fromSource(
        _assets['widthOnlyNoViewBox']! as String,
      );
      expect(widthOnly.intrinsicSize, const Size(40, 150));
      expect(widthOnly.sizeFor(box), const Size(40, 80));

      final heightOnly = NativeSvgBackgroundDimensions.fromSource(
        _assets['heightOnlyNoViewBox']! as String,
      );
      expect(heightOnly.intrinsicSize, const Size(300, 40));
      expect(heightOnly.sizeFor(box), const Size(120, 40));

      final noDimensions = NativeSvgBackgroundDimensions.fromSource(
        _assets['noDimensions']! as String,
      );
      for (final dimensions in [widthOnly, heightOnly, noDimensions]) {
        expect(dimensions.sizeFor(box, fit: BoxFit.contain), box);
        expect(dimensions.sizeFor(box, fit: BoxFit.cover), box);
      }
    },
  );

  test('preserveAspectRatio controls vector picture fit and alignment', () {
    NativeSvgBackgroundDimensions parse(String preserveAspectRatio) =>
        NativeSvgBackgroundDimensions.fromSource(
          '<svg xmlns="http://www.w3.org/2000/svg" width="40" '
          'height="20" viewBox="0 0 40 20" '
          'preserveAspectRatio="$preserveAspectRatio"/>',
        );

    final defaults = parse('');
    expect(defaults.pictureFit, BoxFit.contain);
    expect(defaults.pictureAlignment, Alignment.center);

    final none = parse('none');
    expect(none.pictureFit, BoxFit.fill);

    final slice = parse('defer xMaxYMin slice');
    expect(slice.pictureFit, BoxFit.cover);
    expect(slice.pictureAlignment, Alignment.topRight);

    final meet = parse('xMinYMax meet');
    expect(meet.pictureFit, BoxFit.contain);
    expect(meet.pictureAlignment, Alignment.bottomLeft);
  });

  test(
    'physical SVG units and one-dimensional viewBox sizing are preserved',
    () {
      final physical = NativeSvgBackgroundDimensions.fromSource(
        '<svg xmlns="http://www.w3.org/2000/svg" width="2.54cm" '
        'height="20px" viewBox="0 0 40 20"/>',
      );
      expect(physical.intrinsicSize.width, closeTo(96, 1e-8));
      expect(physical.intrinsicSize.height, 20);
      expect(physical.sizeFor(box), const Size(96, 20));

      final widthOnly = NativeSvgBackgroundDimensions.fromSource(
        '<svg xmlns="http://www.w3.org/2000/svg" width="40" '
        'viewBox="0 0 40 20"/>',
      );
      expect(widthOnly.intrinsicSize, const Size(40, 20));
      expect(widthOnly.sizeFor(box), const Size(40, 20));
    },
  );

  test('zero bounds are safe and malformed or non-SVG roots are rejected', () {
    final dimensions = NativeSvgBackgroundDimensions.fromSource(
      _assets['fixed']! as String,
    );
    // CSS background-size:auto keeps the intrinsic tile size even when the
    // positioning box is empty; fitted sizes safely collapse to zero.
    expect(dimensions.sizeFor(Size.zero), const Size(40, 20));
    expect(dimensions.sizeFor(Size.zero, fit: BoxFit.contain), Size.zero);
    expect(
      () => NativeSvgBackgroundDimensions.fromSource('<svg>'),
      throwsFormatException,
    );
    expect(
      () => NativeSvgBackgroundDimensions.fromSource('<html/>'),
      throwsFormatException,
    );
  });

  test('invalid preserveAspectRatio syntax is rejected', () {
    expect(
      () => NativeSvgBackgroundDimensions.fromSource(
        '<svg xmlns="http://www.w3.org/2000/svg" '
        'preserveAspectRatio="xMidYMid slice extra"/>',
      ),
      throwsFormatException,
    );
  });
}
