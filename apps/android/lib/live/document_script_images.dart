import '../l10n/app_i18n.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'package:pirc_render/src/native_raster_images.dart';
import 'package:pirc_render/src/svg_dimensions.dart';
import 'gateway.dart';

typedef NativeDocumentImageDecoder =
    Future<ui.Image> Function(
      Uint8List bytes,
      String mimeType,
      Future<void> Function(int, int) reserve,
    );

/// Immutable decoded image versions belong to one document, including versions
/// retained by earlier Canvas commands after an HTML image changes its source.
class NativeDocumentImagePool {
  NativeDocumentImagePool({
    this._decoder,
    Future<void> Function(ui.Image)? release,
  }) : _release = release ?? _releaseAfterFrame;

  static const maxEncodedBytes = 2 * 1024 * 1024;
  static const maxEntries = 64;
  static const maxVectorSourceBytes = 32 * 1024 * 1024;
  static const maxPixels = 16 * 1024 * 1024;
  static const maxDimension = 8192;
  final NativeDocumentImageDecoder? _decoder;
  final Future<void> Function(ui.Image) _release;
  final _entries = <String, _ImageVersion>{};
  final _undelivered = <String>{};
  final _retained = <String>{};
  final _releasing = <Future<void>>{};
  Map<String, ui.Image> _images = const {};
  Map<String, ui.Image> get images => _images;
  Map<String, Uint8List> _vectorSources = const {};
  Map<String, Uint8List> get vectorSources => _vectorSources;
  int _allocatedVectorSourceBytes = 0;
  int get allocatedVectorSourceBytes => _allocatedVectorSourceBytes;
  Set<String> get animatedImageIds => {
    for (final entry in _entries.entries)
      if (entry.value.animated) entry.key,
  };
  Set<String> get vectorImageIds => {
    for (final entry in _entries.entries)
      if (entry.value.vector) entry.key,
  };
  bool _disposed = false;
  int _serial = 0, _decoding = 0, _allocatedPixels = 0, _retiring = 0;
  bool get disposed => _disposed;
  int get allocatedPixels => _allocatedPixels;

  Future<Json> decode(
    String requestId,
    Uint8List bytes,
    String mimeType, {
    required bool originClean,
  }) async {
    if (_disposed) throw StateError(tr("Image document is closed."));
    if (!RegExp(r'^image-[1-9][0-9]{0,9}$').hasMatch(requestId)) {
      throw FormatException(tr("Invalid image request identity."));
    }
    if (bytes.isEmpty || bytes.length > maxEncodedBytes) {
      throw FormatException(tr("Script images require 1 byte to 2 MiB."));
    }
    if (_entries.length + _decoding + _retiring >= maxEntries) {
      throw FormatException(tr("Document image limit is 64 decoded versions."));
    }
    _decoding++;
    final vector =
        mimeType.split(';').first.trim().toLowerCase() == 'image/svg+xml';
    // Copy before the first await: caller mutations must not change the version
    // used by either Canvas or the vector widget. Sources are document scoped.
    final decodeBytes = vector
        ? Uint8List.fromList(bytes).asUnmodifiableView()
        : bytes;
    Uint8List? vectorSource;
    if (vector &&
        _allocatedVectorSourceBytes + decodeBytes.length <=
            maxVectorSourceBytes) {
      vectorSource = decodeBytes;
      _allocatedVectorSourceBytes += vectorSource.length;
    }
    var reserved = 0;
    ui.Image? image;
    var animated = false;
    final NativeDocumentImageDecoder decodeImage =
        _decoder ??
        (bytes, mime, reserve) => _decode(
          bytes,
          mime,
          reserve,
          onFrameCount: (frames) => animated = frames > 1,
        );
    try {
      image = await decodeImage(decodeBytes, mimeType, (width, height) async {
        if (_disposed) throw StateError(tr("Image document is closed."));
        if (width <= 0 ||
            height <= 0 ||
            width > maxDimension ||
            height > maxDimension ||
            width * height > maxPixels) {
          throw FormatException(
            tr("Image dimensions exceed the native limit."),
          );
        }
        final pixels = width * height;
        while (_allocatedPixels - reserved + pixels > maxPixels &&
            _releasing.isNotEmpty) {
          await Future.any(_releasing.toList());
          if (_disposed) throw StateError(tr("Image document is closed."));
        }
        if (_allocatedPixels - reserved + pixels > maxPixels) {
          throw FormatException(tr("Decoded document images exceed 16 MP."));
        }
        _allocatedPixels += pixels - reserved;
        reserved = pixels;
      });
      if (reserved != image.width * image.height) {
        throw FormatException(
          tr("Decoded image dimensions changed unexpectedly."),
        );
      }
      if (_disposed) {
        throw StateError(tr("Image document changed during decode."));
      }
      final id = 'canvas-image-${++_serial}';
      _entries[id] = _ImageVersion(
        image,
        reserved,
        animated: animated,
        vector: vector,
        vectorSource: vectorSource,
      );
      vectorSource = null; // Ownership and accounting transfer to the version.
      _undelivered.add(id);
      _refresh();
      final result = <String, dynamic>{
        'id': requestId,
        'ok': true,
        'imageId': id,
        'width': image.width,
        'height': image.height,
        'originClean': originClean,
      };
      image = null;
      reserved = 0;
      return result;
    } finally {
      _decoding--;
      _allocatedVectorSourceBytes -= vectorSource?.length ?? 0;
      if (image != null) {
        _retire(_ImageVersion(image, reserved));
      } else {
        _allocatedPixels -= reserved;
      }
    }
  }

  /// A newly decoded version remains protected until its completion is delivered.
  /// Concurrent completion of another image cannot evict it in the meantime.
  void acknowledge(String? id) {
    if (id == null) return;
    _undelivered.remove(id);
    _collect();
  }

  void retain(Iterable<String> ids) {
    if (_disposed) return;
    final next = ids.toSet();
    if (next.length > maxEntries ||
        next.any((id) => !_entries.containsKey(id))) {
      throw FormatException(tr("Canvas references an unknown document image."));
    }
    _retained
      ..clear()
      ..addAll(next);
    _collect();
  }

  void _collect() {
    var changed = false;
    for (final id in _entries.keys.toList()) {
      if (_retained.contains(id) || _undelivered.contains(id)) continue;
      _retire(_entries.remove(id)!);
      changed = true;
    }
    if (changed) _refresh();
  }

  void _refresh() {
    _images = Map.unmodifiable({
      for (final entry in _entries.entries) entry.key: entry.value.image,
    });
    _vectorSources = Map.unmodifiable({
      for (final entry in _entries.entries)
        entry.key: ?entry.value.vectorSource,
    });
  }

  void _retire(_ImageVersion version) {
    _retiring++;
    late Future<void> future;
    future = Future.sync(() => _release(version.image)).whenComplete(() {
      _allocatedPixels -= version.pixels;
      _allocatedVectorSourceBytes -= version.vectorSource?.length ?? 0;
      _retiring--;
      _releasing.remove(future);
    });
    _releasing.add(future);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final version in _entries.values) {
      _retire(version);
    }
    _entries.clear();
    _undelivered.clear();
    _retained.clear();
    _refresh();
  }

  static Future<void> _releaseAfterFrame(ui.Image image) {
    final done = Completer<void>();
    final binding = SchedulerBinding.instance;
    binding.addPostFrameCallback((_) {
      image.dispose();
      done.complete();
    });
    binding.scheduleFrame();
    return done.future;
  }

  static Future<ui.Image> _decode(
    Uint8List bytes,
    String mime,
    Future<void> Function(int, int) reserve, {
    void Function(int)? onFrameCount,
  }) async {
    final normalized = await NativeRasterImages.prepare(bytes, mime);
    if (mime.split(';').first.trim().toLowerCase() == 'image/svg+xml') {
      final size = svgImageSize(utf8.decode(normalized));
      final width = size.width.ceil(), height = size.height.ceil();
      await reserve(width, height);
      final picture = await vg.loadPicture(SvgBytesLoader(normalized), null);
      try {
        // Canvas is a bitmap surface; decoding an SVG source here is distinct
        // from the existing vector image/background widgets.
        final recorder = ui.PictureRecorder();
        final canvas = ui.Canvas(recorder);
        canvas.scale(width / picture.size.width, height / picture.size.height);
        canvas.drawPicture(picture.picture);
        final raster = recorder.endRecording();
        try {
          return await raster.toImage(width, height);
        } finally {
          raster.dispose();
        }
      } finally {
        picture.picture.dispose();
      }
    }
    final buffer = await ui.ImmutableBuffer.fromUint8List(normalized);
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      await reserve(descriptor.width, descriptor.height);
      codec = await descriptor.instantiateCodec();
      onFrameCount?.call(codec.frameCount);
      final frame = await codec.getNextFrame();
      return frame.image;
    } finally {
      codec?.dispose();
      descriptor?.dispose();
      buffer.dispose();
    }
  }
}

class _ImageVersion {
  const _ImageVersion(
    this.image,
    this.pixels, {
    this.vector = false,
    this.animated = false,
    this.vectorSource,
  });
  final bool vector, animated;
  final Uint8List? vectorSource;
  final ui.Image image;
  final int pixels;
}
