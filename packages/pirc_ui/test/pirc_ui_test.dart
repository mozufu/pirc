import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_ui/pirc_ui.dart';

void main() {
  test('breakpoints are ordered', () {
    expect(PircBreakpoints.compact, lessThan(PircBreakpoints.medium));
    expect(PircBreakpoints.medium, lessThan(PircBreakpoints.wide));
  });
}
