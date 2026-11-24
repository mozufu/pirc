import 'render_l10n.dart';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/painting.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:xml/xml.dart';
import 'document_background_image.dart';
import 'svg_background_dimensions.dart';
import 'background_image_size.dart';
import 'background_image_position.dart';
import 'raster_background_size_painter.dart';

/// Raster backgrounds keep Flutter's animated image stream. An SVG response
/// switches the same painter to a native Picture without a second HTTP fetch.
class NativeHtmlImageBackgroundDecoration extends BoxDecoration {
  NativeHtmlImageBackgroundDecoration(
    BoxDecoration base, {
    this.cssSize,
    this.cssPosition,
  }) : super(
         color: base.color,
         image: base.image,
         border: base.border,
         borderRadius: base.borderRadius,
         boxShadow: base.boxShadow,
         gradient: base.gradient,
         backgroundBlendMode: base.backgroundBlendMode,
         shape: base.shape,
       );

  final String? cssSize, cssPosition;
  @override
  bool operator ==(Object other) =>
      other is NativeHtmlImageBackgroundDecoration &&
      cssSize == other.cssSize &&
      cssPosition == other.cssPosition &&
      super == other;
  @override
  int get hashCode => Object.hash(super.hashCode, cssSize, cssPosition);

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) =>
      _NativeImageBackgroundPainter(this, onChanged);
}

class _NativeImageBackgroundPainter extends BoxPainter {
  _NativeImageBackgroundPainter(this.decoration, super.onChanged) {
    final image = decoration.image!;
    source = image.image as NativeDocumentBackgroundImage;
    fallback = BoxDecoration(
      color: decoration.color,
      boxShadow: decoration.boxShadow,
      borderRadius: decoration.borderRadius,
      shape: decoration.shape,
    ).createBoxPainter(onChanged);
    border = BoxDecoration(
      border: decoration.border,
      borderRadius: decoration.borderRadius,
      shape: decoration.shape,
    ).createBoxPainter(onChanged);
    final details = DecorationImage(
      image: image.image,
      fit: image.fit,
      alignment: image.alignment,
      centerSlice: image.centerSlice,
      repeat: image.repeat,
      matchTextDirection: image.matchTextDirection,
      scale: image.scale,
      opacity: image.opacity,
      filterQuality: image.filterQuality,
      colorFilter: image.colorFilter,
      invertColors: image.invertColors,
      isAntiAlias: image.isAntiAlias,
      onError: (error, stack) {
        if (error is NativeDocumentSvgBackground) {
          if (!_loading && !_closed && source.isCurrent()) {
            _loading = true;
            unawaited(_loadSvg(error));
          }
        } else {
          image.onError?.call(error, stack);
        }
      },
    );
    final explicitSize = NativeBackgroundImageSize.tryParse(decoration.cssSize);
    final position = NativeBackgroundImagePosition.tryParse(
      decoration.cssPosition ?? '',
    );
    final customPosition =
        position != null &&
        RegExp(r'[0-9]').hasMatch(decoration.cssPosition ?? '');
    raster = explicitSize == null && !customPosition
        ? BoxDecoration(
            image: details,
            borderRadius: decoration.borderRadius,
            shape: decoration.shape,
          ).createBoxPainter(onChanged)
        : NativeRasterBackgroundSizePainter(
            image: details,
            size: explicitSize,
            position: position,
            borderRadius: decoration.borderRadius,
            shape: decoration.shape,
            onChanged: onChanged,
          );
  }
  final NativeHtmlImageBackgroundDecoration decoration;
  late final NativeDocumentBackgroundImage source;
  late final BoxPainter fallback, raster, border;
  PictureInfo? _svg;
  NativeSvgBackgroundDimensions? _dimensions;
  bool _closed = false, _loading = false, _failed = false;
  String? _markup;
  Size _boxSize = Size.zero;
  Size? _decodedViewport, _pendingViewport;
  int _decodeTicket = 0;

  Future<void> _loadSvg(NativeDocumentSvgBackground representation) async {
    try {
      if (source.source.hasFragment && source.source.fragment.isNotEmpty) {
        throw UnsupportedError(tr("SVG fragment backgrounds are unsupported."));
      }
      _markup = utf8.decode(representation.bytes);
      _dimensions = NativeSvgBackgroundDimensions.fromSource(_markup!);
      if (_closed || !source.isCurrent()) return;
      await _decodeSvg(_tileFor(_boxSize));
    } catch (error, stack) {
      _failed = true;
      if (!_closed) decoration.image!.onError?.call(error, stack);
    }
  }

  Future<void> _decodeSvg(Size viewport) async {
    final ticket = ++_decodeTicket;
    _loading = true;
    _pendingViewport = viewport;
    try {
      var markup = _markup!;
      // Without a viewBox, SVG user units are viewport pixels. Give the
      // decoder the actual CSS image viewport; scaling an old picture would
      // incorrectly enlarge absolute-coordinate graphics after resize.
      if (_dimensions!.viewBoxSize == null) {
        final dimensions = _dimensions!;
        var rawViewport = viewport;
        if (dimensions.hasIntrinsicWidth && dimensions.hasIntrinsicHeight) {
          rawViewport = dimensions.intrinsicSize;
        } else if (dimensions.hasIntrinsicWidth &&
            dimensions.intrinsicSize.width > 0 &&
            viewport.width > 0) {
          rawViewport = Size(dimensions.intrinsicSize.width, viewport.height);
        } else if (dimensions.hasIntrinsicHeight &&
            dimensions.intrinsicSize.height > 0 &&
            viewport.height > 0) {
          rawViewport = Size(viewport.width, dimensions.intrinsicSize.height);
        }
        final document = XmlDocument.parse(markup);
        document.rootElement.setAttribute(
          'width',
          rawViewport.width.toString(),
        );
        document.rootElement.setAttribute(
          'height',
          rawViewport.height.toString(),
        );
        markup = document.toXmlString();
      }
      final svg = await vg.loadPicture(
        SvgBytesLoader(utf8.encode(markup)),
        null,
      );
      if (_closed || !source.isCurrent() || ticket != _decodeTicket) {
        svg.picture.dispose();
        return;
      }
      _svg?.picture.dispose();
      _svg = svg;
      _decodedViewport = viewport;
      onChanged?.call();
    } catch (error, stack) {
      if (ticket == _decodeTicket) {
        _failed = true;
        if (!_closed) decoration.image!.onError?.call(error, stack);
      }
    } finally {
      if (ticket == _decodeTicket) _loading = false;
    }
  }

  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    _boxSize = configuration.size ?? Size.zero;
    fallback.paint(canvas, offset, configuration);
    if (!_closed && source.isCurrent()) {
      if (_dimensions?.viewBoxSize == null && _markup != null && !_failed) {
        final viewport = _tileFor(_boxSize);
        if (_decodedViewport != viewport &&
            (!_loading || _pendingViewport != viewport)) {
          unawaited(_decodeSvg(viewport));
        }
      }
      if (_svg == null) {
        raster.paint(canvas, offset, configuration);
      } else {
        _paintSvg(
          canvas,
          offset & configuration.size!,
          configuration.textDirection,
        );
      }
    }
    border.paint(canvas, offset, configuration);
  }

  Size _tileFor(Size box) {
    final dimensions = _dimensions!;
    final automatic = dimensions.sizeFor(
      box,
      fit: decoration.image!.fit ?? BoxFit.none,
    );
    final raw = decoration.cssSize?.trim().toLowerCase();
    if (raw == null || raw.isEmpty || raw == 'auto' || raw == 'auto auto') {
      return automatic;
    }
    if (raw == 'cover' || raw == 'contain') {
      return dimensions.sizeFor(
        box,
        fit: raw == 'cover' ? BoxFit.cover : BoxFit.contain,
      );
    }
    return NativeBackgroundImageSize.tryParse(
          raw,
        )?.resolve(box, automatic: box, aspectRatio: dimensions.aspectRatio) ??
        automatic;
  }

  void _paintSvg(Canvas canvas, Rect rect, TextDirection? direction) {
    final svg = _svg!, image = decoration.image!;
    final tile = _tileFor(rect.size);
    if (rect.isEmpty || tile.isEmpty || svg.size.isEmpty) return;
    if (_dimensions!.viewBoxSize == null && _decodedViewport != tile) return;
    final alignment = image.alignment.resolve(direction);
    final position = NativeBackgroundImagePosition.tryParse(
      decoration.cssPosition ?? '',
    );
    final origin =
        rect.topLeft +
        (position?.resolve(rect.size, tile) ??
            Offset(
              (rect.width - tile.width) * (alignment.x + 1) / 2,
              (rect.height - tile.height) * (alignment.y + 1) / 2,
            ));
    final repeatX =
        image.repeat == ImageRepeat.repeat ||
        image.repeat == ImageRepeat.repeatX;
    final repeatY =
        image.repeat == ImageRepeat.repeat ||
        image.repeat == ImageRepeat.repeatY;
    final visible = rect.intersect(canvas.getLocalClipBounds());
    if (visible.isEmpty) return;
    final xFirst = repeatX
        ? ((visible.left - origin.dx) / tile.width).floor()
        : 0;
    final xLast = repeatX
        ? ((visible.right - origin.dx) / tile.width).ceil() - 1
        : 0;
    final yFirst = repeatY
        ? ((visible.top - origin.dy) / tile.height).floor()
        : 0;
    final yLast = repeatY
        ? ((visible.bottom - origin.dy) / tile.height).ceil() - 1
        : 0;
    // A vector tile cannot use a raster ImageShader. Bound pathological tiny
    // authored tiles rather than locking the UI thread in millions of draws.
    if ((xLast - xFirst + 1) * (yLast - yFirst + 1) > 16384) return;
    canvas.save();
    if (decoration.shape == BoxShape.circle) {
      canvas.clipPath(
        Path()..addOval(
          Rect.fromCircle(center: rect.center, radius: rect.shortestSide / 2),
        ),
      );
    } else if (decoration.borderRadius != null) {
      canvas.clipRRect(
        decoration.borderRadius!.resolve(direction).toRRect(rect),
      );
    } else {
      canvas.clipRect(rect);
    }
    for (var y = yFirst; y <= yLast; y++) {
      for (var x = xFirst; x <= xLast; x++) {
        final target = Rect.fromLTWH(
          origin.dx + x * tile.width,
          origin.dy + y * tile.height,
          tile.width,
          tile.height,
        );
        canvas.save();
        canvas.clipRect(target);
        final fitted = applyBoxFit(
          _dimensions!.viewBoxSize == null
              ? BoxFit.fill
              : _dimensions!.pictureFit,
          svg.size,
          target.size,
        );
        final src = _dimensions!.pictureAlignment.inscribe(
          fitted.source,
          Offset.zero & svg.size,
        );
        final dst = _dimensions!.pictureAlignment.inscribe(
          fitted.destination,
          target,
        );
        canvas.translate(dst.left, dst.top);
        canvas.scale(dst.width / src.width, dst.height / src.height);
        canvas.translate(-src.left, -src.top);
        canvas.drawPicture(svg.picture);
        canvas.restore();
      }
    }
    canvas.restore();
  }

  @override
  void dispose() {
    _closed = true;
    _svg?.picture.dispose();
    _svg = null;
    fallback.dispose();
    raster.dispose();
    border.dispose();
    super.dispose();
  }
}
