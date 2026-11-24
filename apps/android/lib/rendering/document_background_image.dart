import 'render_l10n.dart';
import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'document_object_urls.dart';
import 'render_host.dart';

/// CSS backgrounds use the same authenticated transport as Markdown images
/// (the host's [RenderImageFetcher]).
/// The cache key includes account and document ownership so an account change
/// cannot reuse a decoded image belonging to the previous connection.
class NativeDocumentBackgroundImage
    extends ImageProvider<NativeDocumentBackgroundImage> {
  NativeDocumentBackgroundImage({
    required this.source,
    required this.accountIdentity,
    required this.owner,
    required this.isCurrent,
    this.fetcher,
    this.objectUrls,
    this.baseUrl,
    this.documentUrl,
    this.svgCache,
  }) : _svgCacheGeneration = svgCache?._generation;
  final Uri source;
  final Object accountIdentity, owner;
  final bool Function() isCurrent;
  final RenderImageFetcher? fetcher;
  final NativeDocumentObjectUrlBinding? objectUrls;
  final String? baseUrl, documentUrl;
  final NativeSvgBackgroundCache? svgCache;
  final int? _svgCacheGeneration;
  static const maxBytes = 32 * 1024 * 1024;
  NativeDocumentSvgBackground? _svgRepresentation;
  @override
  Future<NativeDocumentBackgroundImage> obtainKey(
    ImageConfiguration configuration,
  ) => SynchronousFuture(this);
  @override
  ImageStreamCompleter loadImage(
    NativeDocumentBackgroundImage key,
    ImageDecoderCallback decode,
  ) => MultiFrameImageStreamCompleter(
    codec: key._load(decode),
    scale: 1,
    debugLabel: 'Native document background',
  );
  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
    try {
      if (!isCurrent()) throw StateError(tr("Background connection changed."));
      // SVG is a successful vector response transported through ImageProvider's
      // error channel. Keep it on this source instance while its scope is live;
      // raster repaint/configuration changes must not fetch it again.
      final svg = _svgRepresentation ?? svgCache?._get(this);
      if (svg != null) throw svg;
      final Uint8List bytes;
      final String mime;
      if (source.scheme == 'blob') {
        if (objectUrls == null) {
          throw StateError(tr("Object URL document is unavailable."));
        }
        final blob = await objectUrls!.read(source.toString());
        bytes = blob.bytes;
        mime = blob.mimeType;
      } else if (source.scheme == 'data') {
        // Percent-encoded data may use three characters per byte.
        if (source.toString().length > maxBytes * 3 + 4096) {
          throw StateError(tr("Background exceeds 32 MiB."));
        }
        final data = source.data!;
        bytes = data.contentAsBytes();
        mime = data.mimeType;
      } else {
        if (!['', 'http', 'https'].contains(source.scheme) || fetcher == null) {
          throw UnsupportedError(tr("Unsupported background URL."));
        }
        final result = await fetcher!.fetchImage(
          source,
          baseUrl: baseUrl,
          documentUrl: documentUrl,
        );
        bytes = result.bytes;
        mime = result.mimeType;
      }
      if (!isCurrent()) throw StateError(tr("Background connection changed."));
      if (bytes.length > maxBytes) {
        throw StateError(tr("Background exceeds 32 MiB."));
      }
      final type = mime.split(';').first.trim().toLowerCase();
      if (type == 'image/svg+xml') {
        final svg = _svgRepresentation = NativeDocumentSvgBackground(bytes);
        svgCache?._put(this, svg);
        throw svg;
      }
      if (!type.startsWith('image/')) {
        throw UnsupportedError(
          tr("This background image format is unsupported."),
        );
      }
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      if (!isCurrent()) {
        buffer.dispose();
        throw StateError(tr("Background connection changed."));
      }
      final codec = await decode(buffer);
      if (!isCurrent()) {
        codec.dispose();
        throw StateError(tr("Background connection changed."));
      }
      return codec;
    } catch (_) {
      // A transient failure must not poison a later retry of the same image.
      scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(this));
      rethrow;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is NativeDocumentBackgroundImage &&
      source == other.source &&
      identical(fetcher, other.fetcher) &&
      baseUrl == other.baseUrl &&
      documentUrl == other.documentUrl &&
      accountIdentity == other.accountIdentity &&
      identical(owner, other.owner) &&
      identical(objectUrls, other.objectUrls) &&
      identical(svgCache, other.svgCache) &&
      _svgCacheGeneration == other._svgCacheGeneration;
  @override
  int get hashCode => Object.hash(
    source,
    fetcher,
    baseUrl,
    documentUrl,
    accountIdentity,
    owner,
    objectUrls,
    svgCache,
    _svgCacheGeneration,
  );
}

/// Passes a bounded SVG representation to a native vector BoxPainter. It is
/// intentionally not converted into a raster ImageProvider or an ImageShader.
class NativeDocumentSvgBackground implements Exception {
  NativeDocumentSvgBackground(Uint8List bytes)
    : bytes = Uint8List.fromList(bytes);
  final Uint8List bytes;
  @override
  String toString() => tr("SVG background requires the native vector painter.");
}

/// Bounded SVG bytes shared by providers belonging to one mounted HTML source.
/// Rebuilding its widget tree keeps bytes; replacing/disposal clears the scope.
class NativeSvgBackgroundCache {
  final _entries =
      <NativeDocumentBackgroundImage, NativeDocumentSvgBackground>{};
  var _bytes = 0, _generation = 0;
  void clear() {
    _entries.clear();
    _bytes = 0;
    _generation++;
  }

  NativeDocumentSvgBackground? _get(NativeDocumentBackgroundImage key) {
    if (key._svgCacheGeneration != _generation) return null;
    final value = _entries.remove(key);
    if (value != null) _entries[key] = value;
    return value;
  }

  void _put(
    NativeDocumentBackgroundImage key,
    NativeDocumentSvgBackground value,
  ) {
    if (key._svgCacheGeneration != _generation || !key.isCurrent()) return;
    for (final stale in _entries.keys.where((k) => !k.isCurrent()).toList()) {
      _bytes -= _entries.remove(stale)!.bytes.length;
    }
    final previous = _entries.remove(key);
    if (previous != null) _bytes -= previous.bytes.length;
    while (_entries.isNotEmpty &&
        (_entries.length >= 64 ||
            _bytes + value.bytes.length >
                NativeDocumentBackgroundImage.maxBytes)) {
      _bytes -= _entries.remove(_entries.keys.first)!.bytes.length;
    }
    if (value.bytes.length > NativeDocumentBackgroundImage.maxBytes) return;
    _entries[key] = value;
    _bytes += value.bytes.length;
  }
}
