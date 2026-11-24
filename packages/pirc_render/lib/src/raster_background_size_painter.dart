import 'package:flutter/painting.dart';
import 'dart:ui' as ui;
import 'dart:typed_data';
import 'background_image_size.dart';
import 'background_image_position.dart';
import 'dart:math' as math;

/// Resizes animated raster frames to CSS tiles before positioning/repeating.
class NativeRasterBackgroundSizePainter extends BoxPainter {
  NativeRasterBackgroundSizePainter({
    required this.image,
    this.size,
    this.position,
    required this.shape,
    this.borderRadius,
    VoidCallback? onChanged,
  }) : super(onChanged) {
    _listener = ImageStreamListener(_handleImage, onError: image.onError);
  }
  final DecorationImage image;
  final NativeBackgroundImageSize? size;
  final NativeBackgroundImagePosition? position;
  final BoxShape shape;
  final BorderRadiusGeometry? borderRadius;
  late final ImageStreamListener _listener;
  ImageStream? _stream;
  ImageInfo? _frame;
  bool _closed = false;
  void _handleImage(ImageInfo value, bool synchronous) {
    if (_closed) {
      value.dispose();
      return;
    }
    if (_frame == value) return;
    if (_frame?.isCloneOf(value) == true) {
      value.dispose();
      return;
    }
    _frame?.dispose();
    _frame = value;
    if (!synchronous) onChanged?.call();
  }

  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    if (_closed) return;
    final stream = image.image.resolve(configuration);
    if (_stream?.key != stream.key) {
      _stream?.removeListener(_listener);
      _stream = stream;
      stream.addListener(_listener);
    }
    final frame = _frame;
    final box = configuration.size ?? Size.zero;
    if (frame == null || box.isEmpty) return;
    final intrinsic =
        Size(frame.image.width.toDouble(), frame.image.height.toDouble()) /
        (frame.scale * image.scale);
    final fitScale = switch (image.fit) {
      BoxFit.cover => math.max(
        box.width / intrinsic.width,
        box.height / intrinsic.height,
      ),
      BoxFit.contain => math.min(
        box.width / intrinsic.width,
        box.height / intrinsic.height,
      ),
      _ => 1.0,
    };
    final automatic = intrinsic * fitScale;
    final tile =
        size?.resolve(
          box,
          automatic: automatic,
          aspectRatio: intrinsic.width / intrinsic.height,
        ) ??
        automatic;
    if (tile.isEmpty || !tile.width.isFinite || !tile.height.isFinite) return;
    final rect = offset & box;
    final visible = rect.intersect(canvas.getLocalClipBounds());
    if (visible.isEmpty) return;
    final alignment = image.alignment.resolve(configuration.textDirection);
    final origin =
        offset +
        (position?.resolve(box, tile) ??
            Offset(
              (box.width - tile.width) * (alignment.x + 1) / 2,
              (box.height - tile.height) * (alignment.y + 1) / 2,
            ));
    final rx =
        image.repeat == ImageRepeat.repeat ||
        image.repeat == ImageRepeat.repeatX;
    final ry =
        image.repeat == ImageRepeat.repeat ||
        image.repeat == ImageRepeat.repeatY;
    final xf = rx ? ((visible.left - origin.dx) / tile.width).floor() : 0;
    final xl = rx ? ((visible.right - origin.dx) / tile.width).ceil() - 1 : 0;
    final yf = ry ? ((visible.top - origin.dy) / tile.height).floor() : 0;
    final yl = ry ? ((visible.bottom - origin.dy) / tile.height).ceil() - 1 : 0;
    final manyTiles = (xl - xf + 1) * (yl - yf + 1) > 16384;
    canvas.save();
    if (shape == BoxShape.circle) {
      canvas.clipPath(
        Path()..addOval(
          Rect.fromCircle(center: rect.center, radius: rect.shortestSide / 2),
        ),
      );
    } else if (borderRadius != null) {
      canvas.clipRRect(
        borderRadius!.resolve(configuration.textDirection).toRRect(rect),
      );
    } else {
      canvas.clipRect(rect);
    }
    if (manyTiles && image.centerSlice == null) {
      // Dense raster tiling is one shader draw, rather than omitting the image
      // or recording hundreds of thousands of image commands.
      final area = Rect.fromLTRB(
        rx ? visible.left : origin.dx,
        ry ? visible.top : origin.dy,
        rx ? visible.right : origin.dx + tile.width,
        ry ? visible.bottom : origin.dy + tile.height,
      ).intersect(visible);
      if (!area.isEmpty) {
        final flip =
            image.matchTextDirection &&
            configuration.textDirection == TextDirection.rtl;
        final shader = ui.ImageShader(
          frame.image,
          rx ? TileMode.repeated : TileMode.clamp,
          ry ? TileMode.repeated : TileMode.clamp,
          Float64List.fromList([
            tile.width / frame.image.width * (flip ? -1 : 1),
            0,
            0,
            0,
            0,
            tile.height / frame.image.height,
            0,
            0,
            0,
            0,
            1,
            0,
            origin.dx + (flip ? tile.width : 0),
            origin.dy,
            0,
            1,
          ]),
          filterQuality: image.filterQuality,
        );
        if (image.invertColors) {
          canvas.saveLayer(
            area,
            Paint()
              ..colorFilter = const ColorFilter.matrix([
                -1,
                0,
                0,
                0,
                255,
                0,
                -1,
                0,
                0,
                255,
                0,
                0,
                -1,
                0,
                255,
                0,
                0,
                0,
                1,
                0,
              ]),
          );
        }
        canvas.drawRect(
          area,
          Paint()
            ..shader = shader
            ..color = Color.fromRGBO(0, 0, 0, image.opacity)
            ..colorFilter = image.colorFilter
            ..isAntiAlias = image.isAntiAlias,
        );
        if (image.invertColors) canvas.restore();
        shader.dispose();
      }
      canvas.restore();
      return;
    }
    for (var y = yf; y <= yl; y++) {
      for (var x = xf; x <= xl; x++) {
        paintImage(
          canvas: canvas,
          rect: (origin + Offset(x * tile.width, y * tile.height)) & tile,
          image: frame.image,
          fit: BoxFit.fill,
          opacity: image.opacity,
          colorFilter: image.colorFilter,
          filterQuality: image.filterQuality,
          invertColors: image.invertColors,
          isAntiAlias: image.isAntiAlias,
          flipHorizontally:
              image.matchTextDirection &&
              configuration.textDirection == TextDirection.rtl,
          centerSlice: image.centerSlice,
        );
      }
    }
    canvas.restore();
  }

  @override
  void dispose() {
    _closed = true;
    _stream?.removeListener(_listener);
    _stream = null;
    _frame?.dispose();
    _frame = null;
    super.dispose();
  }
}
