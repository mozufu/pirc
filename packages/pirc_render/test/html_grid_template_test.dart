import 'package:csslib/parser.dart' as css_parser;
import 'package:csslib/visitor.dart' as css;
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/html_grid_template.dart';

css.Expression? _gridColumns(String value) {
  final stylesheet = css_parser.parse('* { grid-template-columns: $value; }');
  final rules = stylesheet.topLevels.whereType<css.RuleSet>();
  if (rules.length != 1) return null;
  final declarations = rules.single.declarationGroup.declarations
      .whereType<css.Declaration>()
      .where((declaration) => declaration.property == 'grid-template-columns');
  if (declarations.length != 1) return null;
  return declarations.single.expression;
}

void main() {
  test('parses common fixed, percentage, fraction, and minmax tracks', () {
    final template = NativeGridTemplate.parse(
      _gridColumns('120px 25% 1fr minmax(40px, 2fr) minmax(0, 3fr)'),
    );

    expect(template, isNotNull);
    expect(template!.expand(500, 12), [
      const NativeGridTrack.pixels(120),
      const NativeGridTrack.percent(25),
      const NativeGridTrack.fraction(1),
      const NativeGridTrack.fraction(2, minimumPx: 40),
      const NativeGridTrack.fraction(3),
    ]);
  });

  test(
    'expands integer repeat lists and bounds nested repeats to 64 tracks',
    () {
      final template = NativeGridTemplate.parse(
        _gridColumns('repeat(2, 80px minmax(0, 1fr)) 20%'),
      );
      expect(template!.expand(400, 0), [
        const NativeGridTrack.pixels(80),
        const NativeGridTrack.fraction(1),
        const NativeGridTrack.pixels(80),
        const NativeGridTrack.fraction(1),
        const NativeGridTrack.percent(20),
      ]);

      final nested = NativeGridTemplate.parse(
        _gridColumns('repeat(2, repeat(2, 1fr))'),
      );
      expect(
        nested!.expand(400, 0),
        List.filled(4, const NativeGridTrack.fraction(1)),
      );

      final maximum = NativeGridTemplate.parse(
        _gridColumns('repeat(8, repeat(8, 1fr))'),
      );
      expect(maximum!.expand(400, 0), hasLength(64));
      expect(NativeGridTemplate.parse(_gridColumns('repeat(65, 1fr)')), isNull);
    },
  );

  test('sizes auto-fill and auto-fit repeats from available width', () {
    final autoFill = NativeGridTemplate.parse(
      _gridColumns('repeat(auto-fill, minmax(120px, 1fr))'),
    );
    expect(autoFill, isNotNull);
    expect(autoFill!.collapseEmpty, isFalse);
    expect(autoFill.expand(390, 10), hasLength(3));

    final autoFit = NativeGridTemplate.parse(
      _gridColumns('repeat(auto-fit, minmax(120px, 1fr))'),
    );
    expect(autoFit, isNotNull);
    expect(autoFit!.collapseEmpty, isTrue);
    expect(autoFit.expand(250, 10), hasLength(2));
  });

  test('returns null for grid track syntax outside the supported subset', () {
    for (final value in [
      'auto 1fr',
      '80px repeat(auto-fit, minmax(120px, 1fr))',
      'minmax(20%, 1fr)',
      'minmax(10px, max-content)',
      'repeat(2.5, 1fr)',
      'repeat(auto-fit, minmax(0, 1fr))',
      'repeat(auto-fill, 100px)',
      'repeat(65, 1fr)',
      '1fr, 2fr',
      'subgrid',
    ]) {
      expect(
        NativeGridTemplate.parse(_gridColumns(value)),
        isNull,
        reason: value,
      );
    }
  });
}
