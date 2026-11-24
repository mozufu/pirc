import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/pirc_render.dart';

void main() {
  test('three support tiers', () {
    expect(RenderTier.values, hasLength(3));
  });
}
