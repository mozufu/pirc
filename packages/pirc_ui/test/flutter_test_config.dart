import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// The share of pixels a golden image may differ by and still pass. Text
/// anti-aliasing changes a little between macOS and Flutter versions; a
/// real layout or colour change differs by far more (one moved row is
/// already over 1 %).
const goldenTolerance = 0.005;

/// Runs every test file in this package with [TolerantGoldenComparator].
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  final current = goldenFileComparator;
  if (current is LocalFileComparator) {
    goldenFileComparator = TolerantGoldenComparator(
      // Any file in the test's folder gives the same base folder.
      current.basedir.resolve('flutter_test_config.dart'),
      tolerance: goldenTolerance,
    );
  }
  await testMain();
}

/// A [LocalFileComparator] that accepts a difference up to [tolerance] (a
/// share of pixels, 0–1). Larger differences fail with the usual diff
/// images in `failures/`.
class TolerantGoldenComparator extends LocalFileComparator {
  TolerantGoldenComparator(super.testFile, {required this.tolerance});

  final double tolerance;

  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async {
    final result = await GoldenFileComparator.compareLists(
      imageBytes,
      await getGoldenBytes(golden),
    );
    try {
      if (result.passed || result.diffPercent <= tolerance) return true;
      throw FlutterError(await generateFailureOutput(result, golden, basedir));
    } finally {
      result.dispose();
    }
  }
}
