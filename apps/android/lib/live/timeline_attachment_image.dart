import '../l10n/app_i18n.dart';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../rendering/svg_dimensions.dart';
import 'common.dart';
import 'timeline_models.dart';
import 'web_controls.dart';
import 'timeline_image_wrap.dart';
import 'gateway.dart';
import 'remote_content_gate.dart';

/// An image attached to a timeline entry. Inline bytes (`base64`, `data:`)
/// display directly; an entry that names a URL is a remote reference, shown as
/// a placeholder until the user taps it.
class TimelineAttachmentImage extends StatelessWidget {
  const TimelineAttachmentImage({
    super.key,
    required this.entry,
    required this.label,
    this.gateway,
  });
  final Json entry;
  final String label;
  final Gateway? gateway;

  @override
  Widget build(BuildContext context) {
    final loaded = _LoadedTimelineAttachmentImage(
      entry: entry,
      label: label,
      gateway: gateway,
    );
    final source = value(entry, 'url');
    final uri = Uri.tryParse(source);
    if (entry['base64'] != null ||
        source.isEmpty ||
        (uri != null && !nativeRemoteContentSource(uri))) {
      return loaded;
    }
    return NativeRemoteContentGate(
      source: source,
      alt: label,
      builder: (_) => loaded,
    );
  }
}

class _LoadedTimelineAttachmentImage extends StatefulWidget {
  const _LoadedTimelineAttachmentImage({
    required this.entry,
    required this.label,
    this.gateway,
  });
  final Json entry;
  final String label;
  final Gateway? gateway;
  @override
  State<_LoadedTimelineAttachmentImage> createState() =>
      _TimelineAttachmentImageState();
}

class _TimelineAttachmentImageState
    extends State<_LoadedTimelineAttachmentImage> {
  Uint8List? _bytes;
  Size? _natural;
  bool _svg = false, _failed = false;
  int _revision = 0;
  ImageStream? _stream;
  ImageStreamListener? _listener;
  ImageInfo? _networkImage;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _LoadedTimelineAttachmentImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entry['url'] != widget.entry['url'] ||
        oldWidget.entry['base64'] != widget.entry['base64'] ||
        oldWidget.gateway != widget.gateway) {
      _load();
    }
  }

  void _detachStream() {
    if (_listener != null) _stream?.removeListener(_listener!);
    _stream = null;
    _listener = null;
  }

  Future<void> _load() async {
    final ticket = ++_revision;
    _detachStream();
    _failed = false;
    try {
      final source = value(widget.entry, 'url');
      final uri = Uri.tryParse(source);
      Uint8List bytes;
      String mime;
      if (widget.entry['base64'] != null) {
        bytes = base64Decode(value(widget.entry, 'base64'));
        mime = value(widget.entry, 'mimeType');
      } else if (uri?.scheme == 'data') {
        bytes = uri!.data!.contentAsBytes();
        mime = uri.data!.mimeType;
      } else if (widget.gateway != null &&
          uri != null &&
          ['', 'http', 'https'].contains(uri.scheme)) {
        // Timeline entries are page content: this is the credential-free request.
        final result = obj(
          await widget.gateway!.call('image', {'source': source}),
        );
        bytes = result['bytes'] as Uint8List;
        mime = '${result['mimeType']}';
      } else if (uri?.scheme == 'https' || uri?.scheme == 'http') {
        // Standalone preview callers may omit Gateway; App routes always supply it.
        _resolveNetwork(source, ticket);
        return;
      } else {
        throw FormatException(tr("Unsupported image URL"));
      }
      final svg = mime.toLowerCase().split(';').first == 'image/svg+xml';
      Size natural;
      if (svg) {
        final picture = await vg.loadPicture(SvgBytesLoader(bytes), null);
        try {
          natural = svgImageSize(utf8.decode(bytes));
        } finally {
          picture.picture.dispose();
        }
      } else {
        final codec = await ui.instantiateImageCodec(bytes);
        try {
          final frame = await codec.getNextFrame();
          natural = Size(
            frame.image.width.toDouble(),
            frame.image.height.toDouble(),
          );
          frame.image.dispose();
        } finally {
          codec.dispose();
        }
      }
      if (!mounted || ticket != _revision) return;
      setState(() {
        _networkImage?.dispose();
        _networkImage = null;
        _bytes = bytes;
        _natural = natural;
        _svg = svg;
      });
    } catch (_) {
      if (mounted && ticket == _revision) {
        setState(() {
          _networkImage?.dispose();
          _networkImage = null;
          _bytes = null;
          _natural = null;
          _failed = true;
        });
      }
    }
  }

  void _resolveNetwork(String source, int ticket) {
    _stream = NetworkImage(source).resolve(const ImageConfiguration());
    _listener = ImageStreamListener(
      (info, _) {
        if (!mounted || ticket != _revision) {
          info.dispose();
          return;
        }
        setState(() {
          _networkImage?.dispose();
          _networkImage = info;
          _natural = Size(
            info.image.width.toDouble(),
            info.image.height.toDouble(),
          );
          _bytes = null;
        });
      },
      onError: (Object error, StackTrace? stack) {
        if (mounted && ticket == _revision) {
          setState(() {
            _natural = null;
            _failed = true;
          });
        }
      },
    );
    _stream!.addListener(_listener!);
  }

  @override
  void dispose() {
    _revision++;
    _detachStream();
    _networkImage?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    AppI18n.watch(context);
    final natural = _natural;
    if (natural == null && !_failed) return const SizedBox.shrink();
    Widget content;
    double width, height;
    if (_failed) {
      final style = webText(
        context,
        size: 16,
      ).copyWith(height: kTextHeightNone);
      final text = TextPainter(
        text: TextSpan(text: widget.label, style: style),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      )..layout();
      width = text.width + 16;
      height = math.max(16, text.height);
      text.dispose();
      content = Align(
        alignment: Alignment.topLeft,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox.square(
              dimension: 16,
              child: CustomPaint(painter: _BrokenImageGlyph()),
            ),
            Flexible(
              child: Text(
                widget.label,
                style: style,
                maxLines: 1,
                overflow: TextOverflow.clip,
              ),
            ),
          ],
        ),
      );
    } else {
      final ratio = natural!.height == 0
          ? 1.0
          : math.min(1.0, 280 / natural.height);
      width = natural.width * ratio;
      height = natural.height * ratio;
      content = _networkImage != null
          ? RawImage(image: _networkImage!.image, fit: BoxFit.contain)
          : _svg
          ? SvgPicture.memory(_bytes!, fit: BoxFit.contain)
          : Image.memory(_bytes!, fit: BoxFit.contain);
    }
    return Semantics(
      image: true,
      label: widget.label,
      child: _TimelineImageFrame(
        natural: Size(width, height),
        proportional: !_failed,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: ColoredBox(
            color: palette(context)['web.bg-subtle'],
            child: content,
          ),
        ),
      ),
    );
  }
}

class _TimelineImageFrame extends SingleChildRenderObjectWidget {
  const _TimelineImageFrame({
    required this.natural,
    required this.proportional,
    required super.child,
  });
  final Size natural;
  final bool proportional;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderTimelineImageFrame(natural, proportional);
  @override
  void updateRenderObject(
    BuildContext context,
    _RenderTimelineImageFrame renderObject,
  ) {
    renderObject.update(natural, proportional);
  }
}

class _RenderTimelineImageFrame extends RenderProxyBox {
  _RenderTimelineImageFrame(this.natural, this.proportional);
  Size natural;
  bool proportional;
  void update(Size value, bool scale) {
    if (natural == value && proportional == scale) return;
    natural = value;
    proportional = scale;
    markNeedsLayout();
    _invalidateRow();
  }

  void _invalidateRow() {
    RenderObject? ancestor = parent;
    while (ancestor != null) {
      if (ancestor is RenderTimelineImageWrap) {
        ancestor.markNeedsLayout();
        return;
      }
      ancestor = ancestor.parent;
    }
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _invalidateRow();
  }

  Size _sizeFor(BoxConstraints constraints) {
    final width = math.min(
      360.0,
      math.min(constraints.maxWidth, natural.width),
    );
    final height = proportional && natural.width > 0
        ? natural.height * width / natural.width
        : natural.height;
    return constraints.constrain(Size(width, height));
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) => _sizeFor(constraints);
  @override
  double computeMinIntrinsicWidth(double height) =>
      math.min(360, natural.width);
  @override
  double computeMaxIntrinsicWidth(double height) =>
      computeMinIntrinsicWidth(height);
  @override
  double computeMinIntrinsicHeight(double width) =>
      _sizeFor(BoxConstraints(maxWidth: width)).height;
  @override
  double computeMaxIntrinsicHeight(double width) =>
      computeMinIntrinsicHeight(width);
  @override
  void performLayout() {
    size = _sizeFor(constraints);
    child?.layout(BoxConstraints.tight(size));
  }
}

class _BrokenImageGlyph extends CustomPainter {
  const _BrokenImageGlyph();
  @override
  void paint(Canvas canvas, Size size) {
    final outline = Paint()
      ..color = const Color(0xff9aa1a8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawRect(const Rect.fromLTWH(.5, 1.5, 13, 12), outline);
    canvas.drawCircle(
      const Offset(10, 5),
      1.5,
      Paint()..color = const Color(0xff76a7d2),
    );
    canvas.drawPath(
      Path()
        ..moveTo(1, 12)
        ..lineTo(5, 7)
        ..lineTo(8, 10)
        ..lineTo(10, 8)
        ..lineTo(13, 12)
        ..close(),
      Paint()..color = const Color(0xff5d936b),
    );
  }

  @override
  bool shouldRepaint(_BrokenImageGlyph oldDelegate) => false;
}
