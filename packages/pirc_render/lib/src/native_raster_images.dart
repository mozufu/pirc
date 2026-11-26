import 'render_l10n.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'platform_android.dart';

/// Static AVIF uses Android decoding and an 8-bit sRGB PNG for Flutter painting.
/// The representation never leaves memory; source download/save bytes are intact.
class NativeRasterImages {
  static const _channel = MethodChannel('org.mozufu.pirc/images');
  static bool avifSupported = false;

  /// Tests set this to take the Android path on the test host.
  @visibleForTesting
  static bool? debugRunsOnAndroid;

  static bool get _onAndroid => debugRunsOnAndroid ?? runsOnAndroid;

  static bool isAvif(String mime) =>
      mime.split(';').first.trim().toLowerCase() == 'image/avif';

  static Future<void> loadCapabilities() async {
    if (!_onAndroid) return;
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
    if (!isAvif(mime) || !_onAndroid) return bytes;
    final result = await _channel.invokeMethod<Uint8List>('normalizeAvif', {
      'bytes': bytes,
    });
    if (result == null) throw FormatException(tr("AVIF decode failed"));
    return result;
  }
}

/// In-memory image bytes (a `data:` URL). Static AVIF is converted by
/// [NativeRasterImages.prepare] first; other types show directly.
class NativeMemoryImage extends StatefulWidget {
  const NativeMemoryImage(
    this.bytes,
    this.mimeType, {
    super.key,
    this.scale = 1,
    this.semanticLabel,
    required this.errorBuilder,
  });

  final Uint8List bytes;
  final String mimeType;
  final double scale;
  final String? semanticLabel;
  final ImageErrorWidgetBuilder errorBuilder;

  @override
  State<NativeMemoryImage> createState() => _NativeMemoryImageState();
}

class _NativeMemoryImageState extends State<NativeMemoryImage> {
  Future<Uint8List>? _prepared;

  /// The last converted bytes, shown while a new conversion runs.
  Uint8List? _shown;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  @override
  void didUpdateWidget(NativeMemoryImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Each parse of the HTML decodes the `data:` URL again: convert an AVIF
    // only when its bytes really changed. Other types need no work here.
    final avif = NativeRasterImages.isAvif(widget.mimeType);
    final same =
        oldWidget.mimeType == widget.mimeType &&
        (!avif ||
            identical(oldWidget.bytes, widget.bytes) ||
            (oldWidget.bytes.length == widget.bytes.length &&
                listEquals(oldWidget.bytes, widget.bytes)));
    if (!same) {
      _shown = null;
      _prepare();
    }
  }

  void _prepare() {
    _prepared = NativeRasterImages.isAvif(widget.mimeType)
        ? NativeRasterImages.prepare(widget.bytes, widget.mimeType)
        : null;
  }

  Widget _image(Uint8List bytes) => Image.memory(
    bytes,
    scale: widget.scale,
    semanticLabel: widget.semanticLabel,
    errorBuilder: widget.errorBuilder,
  );

  @override
  Widget build(BuildContext context) {
    final prepared = _prepared;
    if (prepared == null) return _image(widget.bytes);
    return FutureBuilder<Uint8List>(
      future: prepared,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return widget.errorBuilder(
            context,
            snapshot.error!,
            snapshot.stackTrace,
          );
        }
        final bytes = snapshot.data ?? _shown;
        if (bytes == null) return const SizedBox.shrink();
        _shown = bytes;
        return _image(bytes);
      },
    );
  }
}
