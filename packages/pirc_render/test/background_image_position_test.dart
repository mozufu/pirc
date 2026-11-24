import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/background_image_position.dart';

void main() {
  const box = Size(100, 80);
  const tile = Size(20, 10);

  NativeBackgroundImagePosition parse(String value) =>
      NativeBackgroundImagePosition.tryParse(value)!;

  test('one- and two-value positions use CSS axis semantics', () {
    expect(parse('right 10px').resolve(box, tile), const Offset(80, 10));
    expect(parse('10px top').resolve(box, tile), const Offset(10, 0));
    expect(parse('center').resolve(box, tile), const Offset(40, 35));
    expect(parse('10px').resolve(box, tile), const Offset(10, 35));
  });

  test('three- and four-value edge offsets resolve from the named edge', () {
    expect(
      parse('right 10px bottom 20px').resolve(box, tile),
      const Offset(70, 50),
    );
    expect(parse('left 20% top').resolve(box, tile), const Offset(16, 0));
    expect(parse('top 10px center').resolve(box, tile), const Offset(40, 10));
    expect(
      parse('left 10px top 20px').resolve(box, tile),
      const Offset(10, 20),
    );
    expect(
      parse('right 25% bottom -5px').resolve(box, tile),
      const Offset(60, 75),
    );
  });

  test('percentages use leftover space, including negative leftover space', () {
    expect(parse('-25% 150%').resolve(box, tile), const Offset(-20, 105));
    expect(
      parse('right 10% bottom -25%').resolve(box, const Size(120, 100)),
      const Offset(-18, -25),
    );
  });

  test('rejects unsupported values and duplicate axes', () {
    for (final value in [
      '',
      'left right',
      'top 10px',
      '10px left',
      'top bottom',
      'left 10px right',
      'calc(10px + 5%) center',
      '10px 2',
      'left 10px top bottom',
      'left top center',
      'left top right bottom center',
    ]) {
      expect(
        NativeBackgroundImagePosition.tryParse(value),
        isNull,
        reason: value,
      );
    }
  });

  test('equivalent parsed positions compare equal', () {
    final center = parse('center');
    final explicitCenter = parse('50% 50%');
    expect(center, explicitCenter);
    expect(center.hashCode, explicitCenter.hashCode);
    expect(parse('left top'), isNot(parse('right bottom')));
  });
}
