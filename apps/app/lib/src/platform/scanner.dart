import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The QR scanner of Google Play services (ML Kit), through the
/// `org.mozufu.pirc/scanner` channel (plans/roadmap.md M8 step 2). It needs
/// no camera permission. The scanned text may hold a device token, so it is
/// never logged.
abstract interface class Scanner {
  /// The text of one QR code, or null when the user closed the scanner.
  /// Throws [ScanFailure].
  Future<String?> scan();
}

/// Why the scanner could not run: `SCAN_BUSY`, `SCAN_TIMEOUT`,
/// `SCAN_DOWNLOADING`, `SCAN_UNSUPPORTED` or `SCAN`.
class ScanFailure implements Exception {
  const ScanFailure(this.code);
  final String code;

  @override
  String toString() => 'ScanFailure($code)';
}

class ChannelScanner implements Scanner {
  const ChannelScanner();

  static const channel = MethodChannel('org.mozufu.pirc/scanner');

  @override
  Future<String?> scan() async {
    try {
      return await channel.invokeMethod<String>('scan');
    } on PlatformException catch (error) {
      throw ScanFailure(error.code);
    }
  }
}

/// For tests: answers each scan with the next of [results] (a [String], null
/// or a [ScanFailure]).
class FakeScanner implements Scanner {
  FakeScanner([List<Object?>? results]) : results = results ?? [];

  final List<Object?> results;
  int scans = 0;

  @override
  Future<String?> scan() async {
    scans++;
    final next = results.isEmpty ? null : results.removeAt(0);
    if (next is ScanFailure) throw next;
    return next as String?;
  }
}

/// The scanner of this platform: Android only.
final scannerProvider = Provider<Scanner?>(
  (ref) => !kIsWeb && defaultTargetPlatform == TargetPlatform.android
      ? const ChannelScanner()
      : null,
);
