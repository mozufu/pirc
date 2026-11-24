import 'render_l10n.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/foundation.dart';
import 'document_background_image.dart';
import 'html_background_gradient.dart';
import 'background_image_position.dart';
import 'html_image_background_decoration.dart';

/// CSS separators inside quoted strings and functions belong to the layer.
List<String> splitNativeBackgroundList(String value, [String separator = ',']) {
  final out = <String>[];
  var start = 0, depth = 0;
  String? quote;
  for (var i = 0; i < value.length; i++) {
    final c = value[i];
    if (c == r'\') {
      i++;
      continue;
    }
    if (quote != null) {
      if (c == quote) quote = null;
      continue;
    }
    if (c == '"' || c == "'") {
      quote = c;
      continue;
    }
    if (c == '(') depth++;
    if (c == ')') depth--;
    if (depth == 0 && c == separator) {
      out.add(value.substring(start, i).trim());
      start = i + 1;
    }
  }
  out.add(value.substring(start).trim());
  return out;
}

List<String> _tokens(String value) =>
    splitNativeBackgroundList(value, ' ').where((v) => v.isNotEmpty).toList();

class NativeHtmlBackgroundLayer {
  const NativeHtmlBackgroundLayer({
    this.url,
    this.gradient,
    this.imageValue,
    this.size = 'auto',
    this.position = 'left top',
    this.repeat = 'repeat',
  });
  final String? url;
  final String? imageValue;
  final Gradient? gradient;
  final String size, position, repeat;
  @override
  bool operator ==(Object other) =>
      other is NativeHtmlBackgroundLayer &&
      url == other.url &&
      size == other.size &&
      position == other.position &&
      repeat == other.repeat &&
      (imageValue == null || other.imageValue == null
          ? imageValue == other.imageValue && gradient == other.gradient
          : imageValue == other.imageValue);
  @override
  int get hashCode =>
      Object.hash(url, size, position, repeat, imageValue ?? gradient);

  Alignment get alignment {
    final p = _tokens(position);
    double n(String v) => switch (v) {
      'left' || 'top' => -1,
      'right' || 'bottom' => 1,
      'center' => 0,
      _ =>
        v.endsWith('%')
            ? (double.tryParse(v.substring(0, v.length - 1)) ?? 0) / 50 - 1
            : -1,
    };
    if (p.isEmpty) return Alignment.topLeft;
    if (p.length == 1) {
      return p.first == 'top' || p.first == 'bottom'
          ? Alignment(0, n(p.first))
          : Alignment(n(p.first), 0);
    }
    if (p.first == 'top' || p.first == 'bottom') {
      return Alignment(n(p[1]), n(p.first));
    }
    return Alignment(n(p.first), n(p[1]));
  }

  ImageRepeat get imageRepeat => switch (repeat) {
    'no-repeat' => ImageRepeat.noRepeat,
    'repeat-x' || 'repeat no-repeat' => ImageRepeat.repeatX,
    'repeat-y' || 'no-repeat repeat' => ImageRepeat.repeatY,
    _ => ImageRepeat.repeat,
  };
}

List<NativeHtmlBackgroundLayer> nativeHtmlBackgroundLayers(
  Iterable<MapEntry<String, String>> declarations,
) {
  var images = <String>[],
      positions = [tr("left top")],
      sizes = ['auto'],
      repeats = ['repeat'];
  for (final e in declarations) {
    final values = splitNativeBackgroundList(e.value);
    switch (e.key) {
      case 'background':
        images = [];
        positions = [];
        sizes = [];
        repeats = [];
        for (final v in values) {
          final slash = splitNativeBackgroundList(v, '/');
          final before = _tokens(slash.first),
              after = slash.length > 1 ? _tokens(slash[1]) : <String>[];
          images.add(
            before
                    .where(
                      (s) =>
                          s.startsWith('url(') ||
                          isNativeHtmlBackgroundGradient(s),
                    )
                    .firstOrNull ??
                'none',
          );
          final pos = before
              .where(
                (s) =>
                    const {
                      'left',
                      'right',
                      'top',
                      'bottom',
                      'center',
                    }.contains(s) ||
                    RegExp(r'^[-\d.]+(?:%|px)$').hasMatch(s) ||
                    s == '0',
              )
              .toList();
          positions.add(pos.isEmpty ? 'left top' : pos.join(' '));
          final size = after
              .takeWhile(
                (s) =>
                    const {'auto', 'cover', 'contain', '0'}.contains(s) ||
                    RegExp(r'^[\d.]+(?:%|px)$').hasMatch(s),
              )
              .toList();
          sizes.add(size.isEmpty ? 'auto' : size.join(' '));
          final repeat = [...before, ...after]
              .where(
                (s) => const {
                  'repeat',
                  'no-repeat',
                  'repeat-x',
                  'repeat-y',
                  'space',
                  'round',
                }.contains(s),
              )
              .toList();
          repeats.add(repeat.isEmpty ? 'repeat' : repeat.join(' '));
        }
      case 'background-image':
        images = values;
      case 'background-position':
        positions = values;
      case 'background-size':
        sizes = values;
      case 'background-repeat':
        repeats = values;
    }
  }
  return List.generate(images.length, (i) {
    final image = images[i].trim();
    String? url;
    Gradient? gradient;
    if (image.startsWith('url(') && image.endsWith(')')) {
      url = image.substring(4, image.length - 1).trim();
      if (url.length >= 2 && (url.startsWith('"') || url.startsWith("'"))) {
        url = url.substring(1, url.length - 1);
      }
    } else if (isNativeHtmlBackgroundGradient(image)) {
      try {
        gradient = parseNativeHtmlBackgroundGradient(image);
      } on FormatException {
        /* Other layers remain visible. */
      }
    }
    return NativeHtmlBackgroundLayer(
      url: url,
      gradient: gradient,
      imageValue: image,
      size: sizes[i % sizes.length],
      position: positions[i % positions.length],
      repeat: repeats[i % repeats.length],
    );
  });
}

class NativeHtmlLayeredBackgroundDecoration extends BoxDecoration {
  NativeHtmlLayeredBackgroundDecoration(
    BoxDecoration base,
    List<NativeHtmlBackgroundLayer> layers,
    List<ImageProvider?> images,
  ) : layers = List.unmodifiable(layers),
      images = List.unmodifiable(images),
      super(
        color: base.color,
        border: base.border,
        borderRadius: base.borderRadius,
        boxShadow: base.boxShadow,
        shape: base.shape,
      );
  final List<NativeHtmlBackgroundLayer> layers;
  final List<ImageProvider?> images;
  @override
  bool operator ==(Object other) =>
      other is NativeHtmlLayeredBackgroundDecoration &&
      super == other &&
      listEquals(layers, other.layers) &&
      listEquals(images, other.images);
  @override
  int get hashCode => Object.hash(
    super.hashCode,
    Object.hashAll(layers),
    Object.hashAll(images),
  );
  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) =>
      _LayerPainter(this, onChanged);
}

class _LayerPainter extends BoxPainter {
  _LayerPainter(this.decoration, super.onChanged) {
    painters.add(
      BoxDecoration(
        color: decoration.color,
        boxShadow: decoration.boxShadow,
        borderRadius: decoration.borderRadius,
        shape: decoration.shape,
      ).createBoxPainter(onChanged),
    );
    for (var i = decoration.layers.length - 1; i >= 0; i--) {
      final layer = decoration.layers[i], image = decoration.images[i];
      if (layer.gradient != null) {
        painters.add(_GradientLayerPainter(layer, decoration, onChanged));
      } else if (image != null) {
        final box = BoxDecoration(
          image: DecorationImage(
            image: image,
            fit: layer.size == 'cover'
                ? BoxFit.cover
                : layer.size == 'contain'
                ? BoxFit.contain
                : BoxFit.none,
            alignment: layer.alignment,
            repeat: layer.imageRepeat,
            onError: (_, _) {},
          ),
          borderRadius: decoration.borderRadius,
          shape: decoration.shape,
        );
        painters.add(
          (image is NativeDocumentBackgroundImage
                  ? NativeHtmlImageBackgroundDecoration(
                      box,
                      cssSize: layer.size,
                      cssPosition: layer.position,
                    )
                  : box)
              .createBoxPainter(onChanged),
        );
      }
    }
    painters.add(
      BoxDecoration(
        border: decoration.border,
        borderRadius: decoration.borderRadius,
        shape: decoration.shape,
      ).createBoxPainter(onChanged),
    );
  }
  final NativeHtmlLayeredBackgroundDecoration decoration;
  final painters = <BoxPainter>[];
  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    for (final p in painters) {
      p.paint(canvas, offset, configuration);
    }
  }

  @override
  void dispose() {
    for (final p in painters) {
      p.dispose();
    }
    super.dispose();
  }
}

class _GradientLayerPainter extends BoxPainter {
  _GradientLayerPainter(this.layer, this.decoration, super.onChanged);
  final NativeHtmlBackgroundLayer layer;
  final BoxDecoration decoration;
  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    final box = configuration.size ?? Size.zero,
        rect = offset & (configuration.size ?? Size.zero);
    final terms = _tokens(layer.size);
    double length(String v, double extent) => v.endsWith('%')
        ? extent * (double.tryParse(v.substring(0, v.length - 1)) ?? 100) / 100
        : double.tryParse(v.replaceAll('px', '')) ?? extent;
    final tile = Size(
      terms.isEmpty ? box.width : length(terms[0], box.width),
      terms.length < 2 ? box.height : length(terms[1], box.height),
    );
    if (rect.isEmpty || tile.isEmpty) return;
    final a = layer.alignment;
    final position = NativeBackgroundImagePosition.tryParse(layer.position);
    final origin =
        offset +
        (position?.resolve(box, tile) ??
            Offset(
              (box.width - tile.width) * (a.x + 1) / 2,
              (box.height - tile.height) * (a.y + 1) / 2,
            ));
    final rx =
            layer.imageRepeat == ImageRepeat.repeat ||
            layer.imageRepeat == ImageRepeat.repeatX,
        ry =
            layer.imageRepeat == ImageRepeat.repeat ||
            layer.imageRepeat == ImageRepeat.repeatY;
    final xf = rx ? ((rect.left - origin.dx) / tile.width).floor() : 0,
        xl = rx ? ((rect.right - origin.dx) / tile.width).ceil() - 1 : 0;
    final yf = ry ? ((rect.top - origin.dy) / tile.height).floor() : 0,
        yl = ry ? ((rect.bottom - origin.dy) / tile.height).ceil() - 1 : 0;
    if ((xl - xf + 1) * (yl - yf + 1) > 16384) return;
    canvas.save();
    if (decoration.shape == BoxShape.circle) {
      canvas.clipPath(Path()..addOval(rect));
    } else if (decoration.borderRadius != null) {
      canvas.clipRRect(
        decoration.borderRadius!
            .resolve(configuration.textDirection)
            .toRRect(rect),
      );
    } else {
      canvas.clipRect(rect);
    }
    for (var y = yf; y <= yl; y++) {
      for (var x = xf; x <= xl; x++) {
        final target =
            (origin + Offset(x * tile.width, y * tile.height)) & tile;
        canvas.drawRect(
          target,
          Paint()
            ..shader = layer.gradient!.createShader(
              target,
              textDirection: configuration.textDirection,
            ),
        );
      }
    }
    canvas.restore();
  }
}
