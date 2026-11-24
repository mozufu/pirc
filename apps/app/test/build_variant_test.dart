import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_app/src/build_variant.dart';

void main() {
  test('flavor and define must agree', () {
    expect(
      resolveBuildVariant(flavor: null, tailscaleDefine: false),
      BuildVariant.standard,
    );
    expect(
      resolveBuildVariant(flavor: 'standard', tailscaleDefine: false),
      BuildVariant.standard,
    );
    expect(
      resolveBuildVariant(flavor: 'tailscale', tailscaleDefine: true),
      BuildVariant.tailscale,
    );
    expect(
      () => resolveBuildVariant(flavor: 'tailscale', tailscaleDefine: false),
      throwsStateError,
    );
    expect(
      () => resolveBuildVariant(flavor: 'standard', tailscaleDefine: true),
      throwsStateError,
    );
    expect(
      () => resolveBuildVariant(flavor: 'other', tailscaleDefine: false),
      throwsStateError,
    );
  });
}
