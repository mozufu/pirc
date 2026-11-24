import 'render_l10n.dart';
import 'package:flutter/services.dart';

import 'platform_android.dart';

/// Static AVIF uses Android decoding and an 8-bit sRGB PNG for Flutter painting.
/// The representation never leaves memory; source download/save bytes are intact.
class NativeRasterImages {
  static const _channel = MethodChannel('dev.pirc.mobile/gateway');
  static bool avifSupported = false;
  static Future<void> loadCapabilities() async {
    if (!runsOnAndroid) return;
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'imageCapabilities',
      );
      avifSupported = result?['avif'] == true;
    } on PlatformException {
      avifSupported = false;
    } on MissingPluginException {
      avifSupported = false;
    }
  }

  static Future<Uint8List> prepare(Uint8List bytes, String mime) async {
    if (mime.split(';').first.trim().toLowerCase() != 'image/avif' ||
        !runsOnAndroid) {
      return bytes;
    }
    final result = await _channel.invokeMethod<Uint8List>('normalizeAvif', {
      'bytes': bytes,
    });
    if (result == null) throw FormatException(tr("AVIF decode failed"));
    return result;
  }
}
