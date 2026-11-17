import '../l10n/app_i18n.dart';
import 'dart:convert';
import '../rendering/svg_dimensions.dart';
import '../rendering/native_image_density.dart';
import '../rendering/native_image_frame.dart';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../rendering/native_raster_images.dart';
import 'gateway.dart';
import 'document_object_urls.dart';
import 'document_navigation_state.dart';
import 'remote_content_gate.dart';

/// Markdown images follow the gateway page URL, not the workspace file base.
///
/// A remote source in held content (chat, previews, tool output, Gateway
/// documents) is a placeholder until the user taps it: this wrapper does not
/// build the loader, so nothing is requested before then. Inline `data:` and
/// local `blob:` sources display as before.
class NativeMarkdownImage extends StatelessWidget {
  const NativeMarkdownImage({
    super.key,
    required this.gateway,
    required this.source,
    this.alt,
    this.title,
    this.baseUrl,
    this.borderRadius = 12,
  });
  final Gateway gateway;
  final Uri source;
  final String? alt, title;
  final String? baseUrl;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    final loaded = _NativeLoadedMarkdownImage(
      gateway: gateway,
      source: source,
      alt: alt,
      title: title,
      baseUrl: baseUrl,
      borderRadius: borderRadius,
    );
    if (!nativeRemoteContentSource(source)) return loaded;
    return NativeRemoteContentGate(
      source: source.toString(),
      alt: alt,
      builder: (_) => loaded,
    );
  }
}

class _NativeLoadedMarkdownImage extends StatefulWidget {
  const _NativeLoadedMarkdownImage({
    required this.gateway,
    required this.source,
    this.alt,
    this.title,
    this.baseUrl,
    this.borderRadius = 12,
  });
  final Gateway gateway;
  final Uri source;
  final String? alt, title;
  final String? baseUrl;
  final double borderRadius;
  @override
  State<_NativeLoadedMarkdownImage> createState() =>
      _NativeMarkdownImageState();
}

class _NativeMarkdownImageState extends State<_NativeLoadedMarkdownImage> {
  Uint8List? bytes;
  Size? size;
  bool svg = false, failed = false;
  static const double _preloadMargin = 300;
  final GlobalKey _visibilityKey = GlobalKey();
  NativeDocumentObjectUrlBinding? _objectUrls;
  String? _documentUrl, _crossOrigin;
  int revision = 0;
  int? _requestedRevision;
  ScrollableState? _scrollable;
  bool _loadingLazy = false;
  bool _visibilityCheckScheduled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final binding = NativeDocumentObjectUrlScope.maybeOf(context)?.binding;
    final documentUrl = NativeDocumentScope.maybeOf(context)?.documentUrl;
    final crossOrigin = NativeImageDensity.crossOriginOf(context);
    if (!identical(binding, _objectUrls) ||
        _documentUrl != documentUrl ||
        _crossOrigin != crossOrigin) {
      _documentUrl = documentUrl;
      _crossOrigin = crossOrigin;
      _objectUrls = binding;
      revision++;
      _requestedRevision = null;
      bytes = null;
      size = null;
      svg = false;
      failed = false;
    }
    _loadingLazy = NativeImageDensity.loadingLazyOf(context);
    _updateScrollable();
    _maybeLoad();
    _scheduleVisibilityCheck();
  }

  @override
  void didUpdateWidget(covariant _NativeLoadedMarkdownImage old) {
    super.didUpdateWidget(old);
    if (old.source != widget.source ||
        old.gateway != widget.gateway ||
        old.baseUrl != widget.baseUrl) {
      revision++;
      _requestedRevision = null;
      bytes = null;
      size = null;
      svg = false;
      failed = false;
      _maybeLoad();
      _scheduleVisibilityCheck();
    }
  }

  void _updateScrollable() {
    final next = _loadingLazy ? Scrollable.maybeOf(context) : null;
    if (next == _scrollable) return;
    _scrollable?.position.removeListener(_handleScroll);
    _scrollable = next;
    _scrollable?.position.addListener(_handleScroll);
  }

  void _handleScroll() => _scheduleVisibilityCheck();

  void _scheduleVisibilityCheck() {
    if (!_loadingLazy || _scrollable == null || _visibilityCheckScheduled) {
      return;
    }
    _visibilityCheckScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _visibilityCheckScheduled = false;
      if (!mounted) return;
      _maybeLoad();
    });
  }

  bool? _isNearViewport() {
    final imageRender = _visibilityKey.currentContext?.findRenderObject();
    final viewportRender = _scrollable?.context.findRenderObject();
    if (imageRender is! RenderBox ||
        viewportRender is! RenderBox ||
        !imageRender.hasSize ||
        !viewportRender.hasSize ||
        !imageRender.attached ||
        !viewportRender.attached) {
      // No completed layout means visibility is unknown, not visible. The
      // ScrollPosition listener will check again after scrolling lays it out.
      return null;
    }

    final imageOrigin = imageRender.localToGlobal(Offset.zero);
    final imageEnd = imageRender.localToGlobal(
      Offset(imageRender.size.width, imageRender.size.height),
    );
    final viewportOrigin = viewportRender.localToGlobal(Offset.zero);
    final viewportEnd = viewportRender.localToGlobal(
      Offset(viewportRender.size.width, viewportRender.size.height),
    );
    final imageRect = Rect.fromPoints(imageOrigin, imageEnd);
    final viewportRect = Rect.fromPoints(viewportOrigin, viewportEnd);
    final axis = axisDirectionToAxis(_scrollable!.position.axisDirection);
    final imageStart = axis == Axis.vertical ? imageRect.top : imageRect.left;
    final imageFinish = axis == Axis.vertical
        ? imageRect.bottom
        : imageRect.right;
    final viewportStart = axis == Axis.vertical
        ? viewportRect.top
        : viewportRect.left;
    final viewportFinish = axis == Axis.vertical
        ? viewportRect.bottom
        : viewportRect.right;

    // Flutter host heuristic: start loading within a finite 300 logical-pixel
    // band around the nearest Scrollable's viewport. This approximates native
    // lazy loading; it does not reproduce Chrome's network heuristics.
    return imageFinish >= viewportStart - _preloadMargin &&
        imageStart <= viewportFinish + _preloadMargin;
  }

  void _maybeLoad() {
    if (!mounted || _requestedRevision == revision) return;
    // HTML lazy loading has no meaning outside a scrolling viewport. In that
    // case, load eagerly so images in dialogs and standalone renderers work.
    if (_loadingLazy && _scrollable != null) {
      if (_visibilityKey.currentContext == null) {
        _scheduleVisibilityCheck();
        return;
      }
      if (_isNearViewport() != true) return;
    }
    _requestedRevision = revision;
    _load(revision);
  }

  Future<void> _load(int ticket) async {
    final objectUrls = _objectUrls;
    try {
      Uint8List data;
      String mime;
      if (widget.source.scheme == 'blob') {
        if (objectUrls == null) {
          throw StateError(tr("Object URL document is unavailable."));
        }
        final blob = await objectUrls.read(widget.source.toString());
        data = blob.bytes;
        mime = blob.mimeType;
      } else if (widget.source.scheme == 'data') {
        final uri = widget.source.data!;
        data = uri.contentAsBytes();
        mime = uri.mimeType;
      } else {
        if (!['', 'http', 'https'].contains(widget.source.scheme)) {
          throw FormatException(tr("Unsupported image URL"));
        }
        final result = obj(
          await widget.gateway.call('image', {
            'source': widget.source.toString(),
            if (widget.baseUrl != null) 'baseUrl': widget.baseUrl,
            if (_documentUrl != null) 'documentUrl': _documentUrl,
            if (_crossOrigin != null) 'crossOrigin': _crossOrigin,
          }),
        );
        data = result['bytes'] as Uint8List;
        mime = '${result['mimeType']}';
      }
      if (data.length > 32 * 1024 * 1024) {
        throw FormatException(tr("Image exceeds 32 MiB"));
      }
      data = await NativeRasterImages.prepare(data, mime);
      final isSvg = mime.toLowerCase() == 'image/svg+xml';
      Size dimensions;
      if (isSvg) {
        final picture = await vg.loadPicture(SvgBytesLoader(data), null);
        try {
          dimensions = svgImageSize(utf8.decode(data));
        } finally {
          picture.picture.dispose();
        }
      } else {
        final codec = await ui.instantiateImageCodec(data);
        try {
          final frame = await codec.getNextFrame();
          dimensions = Size(
            frame.image.width.toDouble(),
            frame.image.height.toDouble(),
          );
          frame.image.dispose();
        } finally {
          codec.dispose();
        }
      }
      if (dimensions.width < 0 || dimensions.height < 0) {
        throw FormatException(tr("Empty image"));
      }
      if (!mounted ||
          ticket != revision ||
          (widget.source.scheme == 'blob' && objectUrls?.current != true)) {
        return;
      }
      setState(() {
        bytes = data;
        size = dimensions;
        svg = isSvg;
      });
    } catch (_) {
      if (mounted && ticket == revision) setState(() => failed = true);
    }
  }

  Widget fallback() => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (failed) const Icon(LucideIcons.imageOff, size: 16),
      if ((widget.alt ?? '').isNotEmpty) Flexible(child: Text(widget.alt!)),
    ],
  );
  @override
  void dispose() {
    _scrollable?.position.removeListener(_handleScroll);
    _scrollable = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    AppI18n.watch(context);
    final density = NativeImageDensity.of(context);
    final dimensions = size == null
        ? null
        : Size(size!.width / density, size!.height / density);
    Widget image;
    if (dimensions == null) {
      image = fallback();
    } else {
      final width = dimensions.width;
      final height = dimensions.height;
      Widget content;
      if (width == 0 || height == 0) {
        content = SizedBox(width: width, height: height);
      } else {
        final picture = svg
            ? SvgPicture.memory(
                bytes!,
                semanticsLabel: widget.alt,
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) => fallback(),
              )
            : Image.memory(
                bytes!,
                scale: density,
                semanticLabel: widget.alt,
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) => fallback(),
              );
        content = NativeImageFrame(
          naturalSize: dimensions,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(widget.borderRadius),
            child: picture,
          ),
        );
      }
      image =
          context.dependOnInheritedWidgetOfExactType<NativeImageDensity>() !=
              null
          ? content
          : Align(
              alignment: Alignment.centerLeft,
              widthFactor: 1,
              heightFactor: 1,
              child: content,
            );
    }
    if ((widget.title ?? '').isNotEmpty) {
      image = Tooltip(message: widget.title!, child: image);
    }
    return KeyedSubtree(key: _visibilityKey, child: image);
  }
}
