import 'render_l10n.dart';
import 'dart:math' as math;
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

typedef NativeModalBackdropPointerCallback =
    void Function(PointerDownEvent event, Rect dialogBounds);

/// The document root can reach visible positioned paint outside flow ancestors.
abstract interface class NativeDocumentPositionedHitTarget {
  bool hitTestPositioned(BoxHitTestResult result, {required Offset position});
}

/// Child paint order for hit-test policy traversal through positioned layers.
abstract interface class NativeDocumentPositionedChildOrder {
  Iterable<RenderObject> get positionedPaintChildren;
}

/// Flow-only traversal avoids testing viewport-routed descendants twice.
abstract interface class NativeDocumentRoutedPositionedRoot {
  bool get viewportRouted;
  RenderObject? get ordinaryFlow;
}

/// A native scrollport supplies its constrained padding-box basis while its
/// content is laid out with unbounded scroll axes.
abstract interface class NativeDocumentPositioningScrollport {
  Size positioningPaddingSize(Size flowSize);
}

/// A live containing-block basis, published only during actual native layout.
abstract interface class NativeDocumentPositioningBasis {
  double? get positioningWidth;
  double? get positioningHeight;
  bool get positioningActive;
}

class NativeAbsoluteLength {
  const NativeAbsoluteLength(this.value, [this.percent = false]);
  final double value;
  final bool percent;
  double resolve(double basis) => percent ? value * basis / 100 : value;
  static NativeAbsoluteLength? parse(String? text, double font, Size viewport) {
    final match = RegExp(
      r'^([+-]?(?:\d+(?:\.\d*)?|\.\d+))(px|%|em|pt|vw|vh|vmin|vmax)?$',
    ).firstMatch(text?.trim().toLowerCase() ?? '');
    if (match == null) return null;
    final n = double.parse(match[1]!);
    if (!n.isFinite || (match[2] == null && n != 0)) return null;
    return switch (match[2]) {
      '%' => NativeAbsoluteLength(n, true),
      'em' => NativeAbsoluteLength(n * font),
      'pt' => NativeAbsoluteLength(n * 96 / 72),
      'vw' => NativeAbsoluteLength(n * viewport.width / 100),
      'vh' => NativeAbsoluteLength(n * viewport.height / 100),
      'vmin' => NativeAbsoluteLength(
        n * math.min(viewport.width, viewport.height) / 100,
      ),
      'vmax' => NativeAbsoluteLength(
        n * math.max(viewport.width, viewport.height) / 100,
      ),
      _ => NativeAbsoluteLength(n),
    };
  }
}

/// Physical positioned axes. Static-position axes require a real flow marker.
class NativeAbsolutePositionSpec {
  NativeAbsolutePositionSpec._(
    this.styles,
    this.lengths,
    this.direction,
    this.fixedUsesViewport,
    this.topLayer,
  );
  final Map<String, String> styles;
  final Map<String, NativeAbsoluteLength?> lengths;
  final TextDirection direction;
  final bool fixedUsesViewport;
  final bool topLayer;
  static NativeAbsolutePositionSpec? parse(
    Map<String, String> styles, {
    required double fontSize,
    required Size viewport,
    TextDirection direction = TextDirection.ltr,
    bool fixedUsesViewport = true,
    bool allowStaticPosition = false,
    bool topLayer = false,
  }) {
    if (!const {
      'absolute',
      'fixed',
    }.contains(styles['position']?.trim().toLowerCase())) {
      return null;
    }
    final values = <String, String>{...styles};
    final shorthand = values['inset']?.trim().split(RegExp(r'\s+'));
    if (shorthand != null) {
      if (shorthand.isEmpty || shorthand.length > 4) return null;
      final t = shorthand[0],
          r = shorthand.length > 1 ? shorthand[1] : t,
          b = shorthand.length > 2 ? shorthand[2] : t,
          l = shorthand.length > 3 ? shorthand[3] : r;
      for (final pair in [
        ('top', t),
        ('right', r),
        ('bottom', b),
        ('left', l),
      ]) {
        values.putIfAbsent(pair.$1, () => pair.$2);
      }
    }
    final lengths = <String, NativeAbsoluteLength?>{};
    for (final name in [
      'left',
      'right',
      'top',
      'bottom',
      'width',
      'height',
      'min-width',
      'max-width',
      'min-height',
      'max-height',
      for (final side in ['left', 'right', 'top', 'bottom']) ...[
        'margin-$side',
        'padding-$side',
        'border-$side-width',
      ],
    ]) {
      final raw = values[name]?.trim().toLowerCase();
      if (raw == null && name.startsWith('margin-')) {
        lengths[name] = const NativeAbsoluteLength(0);
        continue;
      }
      if ((name == 'width' || name == 'height') && raw == 'fit-content') {
        lengths[name] = null;
        continue;
      }
      if (raw == null ||
          raw == 'auto' ||
          (raw == 'none' && name.startsWith('max-'))) {
        lengths[name] = null;
        continue;
      }
      final length = NativeAbsoluteLength.parse(raw, fontSize, viewport);
      if (length == null) return null;
      if (!name.startsWith('margin-') &&
          !['left', 'right', 'top', 'bottom'].contains(name) &&
          length.value < 0) {
        return null;
      }
      lengths[name] = length;
    }
    if (!topLayer &&
        !allowStaticPosition &&
        ((lengths['left'] == null && lengths['right'] == null) ||
            (lengths['top'] == null && lengths['bottom'] == null))) {
      return null;
    }
    for (final name in [
      'inset-inline',
      'inset-block',
      'inset-inline-start',
      'inset-inline-end',
      'inset-block-start',
      'inset-block-end',
    ]) {
      if (values.containsKey(name) &&
          values[name] != 'auto' &&
          NativeAbsoluteLength.parse(values[name], fontSize, viewport)?.value !=
              0) {
        return null;
      }
    }
    final zIndex = int.tryParse(values['z-index'] ?? '0');
    if (!topLayer && zIndex != null && zIndex < 0) return null;
    return NativeAbsolutePositionSpec._(
      values,
      lengths,
      direction,
      fixedUsesViewport,
      topLayer,
    );
  }

  bool get fixedToViewport =>
      fixedUsesViewport && styles['position']?.trim().toLowerCase() == 'fixed';

  double? value(String name, double basis) => lengths[name]?.resolve(basis);
  double edge(String side, double width) {
    final padding = value('padding-$side', width) ?? 0;
    final border =
        const {
          'none',
          'hidden',
        }.contains(styles['border-$side-style'] ?? 'none')
        ? 0
        : value('border-$side-width', width) ?? 3;
    return padding + border;
  }

  double outer(String axis, double value, double basis) =>
      styles['box-sizing'] == 'border-box'
      ? value
      : value +
            (axis == 'width'
                ? edge('left', basis) + edge('right', basis)
                : edge('top', basis) + edge('bottom', basis));
  double clamp(String axis, double target, Size basis) {
    final size = axis == 'width' ? basis.width : basis.height;
    final edges = axis == 'width'
        ? edge('left', basis.width) + edge('right', basis.width)
        : edge('top', basis.width) + edge('bottom', basis.width);
    final low = math.max(
      edges,
      outer(axis, value('min-$axis', size) ?? 0, basis.width),
    );
    final rawMax = value('max-$axis', size);
    final high = rawMax == null
        ? double.infinity
        : math.max(low, outer(axis, rawMax, basis.width));
    return target.clamp(low, high).toDouble();
  }

  double? authored(String axis, Size basis) {
    final raw = value(axis, axis == 'width' ? basis.width : basis.height);
    return raw == null
        ? null
        : clamp(axis, outer(axis, raw, basis.width), basis);
  }

  double available(String axis, Size basis) {
    final horizontal = axis == 'width',
        size = horizontal ? basis.width : basis.height;
    final start = horizontal ? 'left' : 'top',
        end = horizontal ? 'right' : 'bottom';
    return math.max(
      0,
      size -
          (value(start, size) ?? 0) -
          (value(end, size) ?? 0) -
          (value('margin-$start', basis.width) ?? 0) -
          (value('margin-$end', basis.width) ?? 0),
    );
  }

  bool stretch(String axis) =>
      styles[axis]?.trim() != 'fit-content' &&
      lengths[axis] == null &&
      lengths[axis == 'width' ? 'left' : 'top'] != null &&
      lengths[axis == 'width' ? 'right' : 'bottom'] != null;
  bool staticAxis(String axis) =>
      lengths[axis == 'width' ? 'left' : 'top'] == null &&
      lengths[axis == 'width' ? 'right' : 'bottom'] == null;
  // Top-layer boxes use the containing block origin as their static position,
  // independent of where their DOM parent participates in ordinary flow.
  bool get needsStaticPosition =>
      !topLayer && (staticAxis('width') || staticAxis('height'));

  double offset(
    String axis,
    double extent,
    Size basis, {
    double staticPosition = 0,
  }) {
    final horizontal = axis == 'width',
        size = horizontal ? basis.width : basis.height;
    final a = horizontal ? 'left' : 'top', b = horizontal ? 'right' : 'bottom';
    final start = value(a, size), end = value(b, size);
    if (start == null && end == null) {
      return staticPosition +
          (value('margin-$a', basis.width) ?? 0) -
          (horizontal && direction == TextDirection.rtl ? extent : 0);
    }
    var first = value('margin-$a', basis.width),
        last = value('margin-$b', basis.width);
    if (start != null && end != null) {
      final free = size - start - end - extent - (first ?? 0) - (last ?? 0);
      if (first == null && last == null) {
        first = horizontal && free < 0
            ? (direction == TextDirection.ltr ? 0 : free)
            : free / 2;
        last = free - first;
      } else if (first == null) {
        first = free;
      } else {
        last ??= free;
      }
    }
    if (start != null &&
        !(horizontal && end != null && direction == TextDirection.rtl)) {
      return start + (first ?? 0);
    }
    return size - (end ?? 0) - (last ?? 0) - extent;
  }

  int get zIndex => int.tryParse(styles['z-index'] ?? '0') ?? 0;
}

class NativeAbsoluteEntry {
  const NativeAbsoluteEntry({
    required this.spec,
    required this.child,
    this.isModal = false,
    this.modalOrder = 0,
    this.overflowHitTest,
    this.staticMarker,
  });
  final bool isModal;
  final int modalOrder;
  final GlobalKey? staticMarker;
  final NativeAbsolutePositionSpec spec;
  final Widget child;
  final bool Function(RenderBox, BoxHitTestResult, Offset)? overflowHitTest;
}

class NativeDocumentAbsoluteLayer extends MultiChildRenderObjectWidget {
  NativeDocumentAbsoluteLayer({
    super.key,
    required Widget flow,
    required List<NativeAbsoluteEntry> positioned,
    this.border = EdgeInsets.zero,
    this.initialContainingBlock,
    this.boxSurface,
    this.useScrollportBasis = false,
  }) : hasFixedEntries = positioned.any((item) => item.spec.fixedToViewport),
       super(children: _children(flow, positioned));

  static List<Widget> _children(
    Widget flow,
    List<NativeAbsoluteEntry> positioned,
  ) {
    final topModalOrder = _topModalOrder(positioned);
    return [
      topModalOrder > 0 ? ExcludeSemantics(child: flow) : flow,
      for (final item in positioned)
        _AbsoluteItem(
          spec: item.spec,
          isModal: item.isModal,
          modalOrder: item.modalOrder,
          staticMarker: item.staticMarker,
          overflowHitTest: item.overflowHitTest,
          child: topModalOrder > 0 && item.modalOrder != topModalOrder
              ? ExcludeSemantics(child: item.child)
              : item.child,
        ),
    ];
  }

  static int _topModalOrder(List<NativeAbsoluteEntry> entries) => entries.fold(
    0,
    (highest, item) =>
        item.isModal && item.modalOrder > highest ? item.modalOrder : highest,
  );
  final bool hasFixedEntries;
  final bool useScrollportBasis;
  final EdgeInsets border;
  final Size? initialContainingBlock;
  final ({RenderBox surface, Size size})? Function(RenderBox)? boxSurface;
  @override
  RenderObject createRenderObject(BuildContext context) => _RenderAbsoluteLayer(
    border,
    initialContainingBlock,
    boxSurface,
    hasFixedEntries,
    useScrollportBasis,
  );
  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderObject renderObject,
  ) {
    (renderObject as _RenderAbsoluteLayer)
      ..border = border
      ..initialContainingBlock = initialContainingBlock
      ..boxSurface = boxSurface
      ..useScrollportBasis = useScrollportBasis
      ..hasFixedEntries = hasFixedEntries
      ..markNeedsLayout();
  }
}

class _AbsoluteItem extends SingleChildRenderObjectWidget {
  const _AbsoluteItem({
    required this.spec,
    required this.isModal,
    required this.modalOrder,
    required this.staticMarker,
    required this.overflowHitTest,
    required super.child,
  });
  final NativeAbsolutePositionSpec spec;
  final bool isModal;
  final int modalOrder;
  final GlobalKey? staticMarker;
  final bool Function(RenderBox, BoxHitTestResult, Offset)? overflowHitTest;
  @override
  RenderObject createRenderObject(BuildContext context) => _RenderAbsoluteItem(
    spec,
    overflowHitTest,
    staticMarker,
    isModal,
    modalOrder,
  );
  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderAbsoluteItem renderObject,
  ) {
    renderObject
      ..spec = spec
      ..isModal = isModal
      ..modalOrder = modalOrder
      ..staticMarker = staticMarker
      ..overflowHitTest = overflowHitTest
      ..markNeedsLayout();
  }
}

class _RenderAbsoluteItem extends RenderProxyBox
    implements NativeDocumentPositioningBasis, NativeDocumentFixedSurface {
  _RenderAbsoluteItem(
    this.spec,
    this.overflowHitTest,
    this.staticMarker,
    this.isModal,
    this.modalOrder,
  );
  bool isModal;
  int modalOrder;
  GlobalKey? staticMarker;
  Offset usedOffset = Offset.zero;
  NativeAbsolutePositionSpec spec;
  @override
  bool get fixedToViewport => spec.fixedToViewport;
  @override
  bool get scrollTranslationIndependent {
    final layer = parent;
    if (!fixedToViewport || layer is! _RenderAbsoluteLayer) return false;
    final viewport = layer._fixedViewport;
    return viewport != null &&
        viewport.attached &&
        MatrixUtils.getAsTranslation(layer.getTransformTo(viewport)) != null;
  }

  bool Function(RenderBox, BoxHitTestResult, Offset)? overflowHitTest;
  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (super.hitTest(result, position: position)) return true;
    if (overflowHitTest?.call(this, result, position) == true) {
      result.add(BoxHitTestEntry(this, position));
      return true;
    }
    return false;
  }

  Size basis = Size.zero;
  void updateBasis(Size next) {
    if (basis == next) return;
    basis = next;
    void invalidate(RenderObject node) {
      node.markNeedsLayout();
      node.visitChildren(invalidate);
    }

    invalidate(this);
  }

  bool _active = false;
  @override
  double? get positioningWidth => basis.width;
  @override
  double? get positioningHeight => basis.height;
  @override
  bool get positioningActive => _active;
  @override
  void performLayout() {
    _active = true;
    try {
      super.performLayout();
    } finally {
      _active = false;
    }
  }
}

/// Actual un-routed position assigned by the native containing-block layout.
({
  Offset offset,
  bool fixedToViewport,
  bool initialContainingBlock,
  Map<String, double> autoInsets,
})?
nativeDocumentPositionedLayout(RenderObject object) {
  if (object is! _RenderAbsoluteItem || !object.attached || !object.hasSize) {
    return null;
  }
  final data = object.parentData, parent = object.parent;
  if (data is! _AbsoluteParentData || parent is! _RenderAbsoluteLayer) {
    return null;
  }
  return (
    offset: data.offset,
    autoInsets: object.spec.needsStaticPosition
        ? {
            'left':
                object.usedOffset.dx -
                (object.spec.value('margin-left', object.basis.width) ?? 0),
            'right':
                object.basis.width -
                object.usedOffset.dx -
                object.size.width -
                (object.spec.value('margin-right', object.basis.width) ?? 0),
            'top':
                object.usedOffset.dy -
                (object.spec.value('margin-top', object.basis.width) ?? 0),
            'bottom':
                object.basis.height -
                object.usedOffset.dy -
                object.size.height -
                (object.spec.value('margin-bottom', object.basis.width) ?? 0),
          }
        : const <String, double>{},
    fixedToViewport: object.fixedToViewport,
    initialContainingBlock: parent.initialContainingBlock != null,
  );
}

class _AbsoluteParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderAbsoluteLayer extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _AbsoluteParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _AbsoluteParentData>
    implements
        NativeDocumentPositionedHitTarget,
        NativeDocumentPositionedChildOrder,
        NativeDocumentRoutedPositionedRoot {
  _RenderAbsoluteLayer(
    this.border,
    this.initialContainingBlock,
    this.boxSurface,
    this.hasFixedEntries,
    this.useScrollportBasis,
  );
  bool hasFixedEntries;
  bool useScrollportBasis;
  RenderNativeDocumentPositioningViewport? _fixedViewport;
  @override
  bool get viewportRouted => _fixedViewport != null;
  @override
  RenderObject? get ordinaryFlow => firstChild;
  EdgeInsets border;
  Size? initialContainingBlock;
  ({RenderBox surface, Size size})? Function(RenderBox)? boxSurface;
  void _syncFixedViewport() {
    RenderNativeDocumentPositioningViewport? found;
    if (hasFixedEntries) {
      RenderObject? node = parent;
      while (node != null) {
        if (node is RenderNativeDocumentPositioningViewport) {
          found = node;
          break;
        }
        node = node.parent;
      }
    }
    if (identical(found, _fixedViewport)) return;
    _fixedViewport?._unregister(this);
    _fixedViewport = found;
    found?._register(this);
  }

  @override
  void detach() {
    _fixedViewport?._unregister(this);
    _fixedViewport = null;
    super.detach();
  }

  @override
  void markNeedsPaint() {
    super.markNeedsPaint();
    final viewport = _fixedViewport;
    if (viewport != null && viewport.attached) viewport.markNeedsPaint();
  }

  Offset _itemOffset(RenderBox child) {
    final offset = (child.parentData! as _AbsoluteParentData).offset;
    final viewport = _fixedViewport;
    if (child is _RenderAbsoluteItem &&
        child.spec.fixedToViewport &&
        viewport != null) {
      final shift = MatrixUtils.getAsTranslation(getTransformTo(viewport));
      if (shift != null) return offset - shift;
    }
    return offset;
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _AbsoluteParentData) {
      child.parentData = _AbsoluteParentData();
    }
  }

  @override
  void performLayout() {
    _syncFixedViewport();
    final flow = firstChild!;
    flow.layout(constraints, parentUsesSize: true);
    size = constraints.constrain(flow.size);
    (flow.parentData! as _AbsoluteParentData).offset = Offset.zero;
    final published = boxSurface?.call(flow);
    final surface = published?.surface ?? flow;
    final surfaceSize = published?.size ?? flow.size;
    final origin = MatrixUtils.transformPoint(
      surface.getTransformTo(this),
      Offset.zero,
    );
    final scrollport = parent;
    final scrollportSize =
        useScrollportBasis && scrollport is NativeDocumentPositioningScrollport
        ? (scrollport as NativeDocumentPositioningScrollport)
              .positioningPaddingSize(flow.size)
        : null;
    final basis =
        initialContainingBlock ??
        scrollportSize ??
        Size(
          math.max(0, surfaceSize.width - border.horizontal),
          math.max(0, surfaceSize.height - border.vertical),
        );
    RenderBox? item = childAfter(flow);
    while (item != null) {
      final current = item as _RenderAbsoluteItem, spec = current.spec;
      if (current.basis != basis) {
        invokeLayoutCallback<BoxConstraints>((_) => current.updateBasis(basis));
      }
      final width =
          spec.authored('width', basis) ??
          (spec.stretch('width')
              ? spec.clamp('width', spec.available('width', basis), basis)
              : null);
      final height =
          spec.authored('height', basis) ??
          (spec.stretch('height')
              ? spec.clamp('height', spec.available('height', basis), basis)
              : null);
      double usedWidth;
      if (width != null) {
        usedWidth = width;
      } else {
        current._active = true;
        try {
          final preferred = current.getMaxIntrinsicWidth(double.infinity),
              minimum = current.getMinIntrinsicWidth(double.infinity);
          usedWidth = spec.clamp(
            'width',
            math.min(
              math.max(minimum, spec.available('width', basis)),
              preferred,
            ),
            basis,
          );
        } finally {
          current._active = false;
        }
      }
      current.layout(
        BoxConstraints(
          minWidth: usedWidth,
          maxWidth: usedWidth,
          minHeight: height ?? 0,
          maxHeight: height ?? double.infinity,
        ),
        parentUsesSize: true,
      );
      if (height == null) {
        final clamped = spec.clamp('height', current.size.height, basis);
        if (clamped != current.size.height) {
          current.layout(
            BoxConstraints.tight(Size(usedWidth, clamped)),
            parentUsesSize: true,
          );
        }
      }
      final marker = current.staticMarker?.currentContext?.findRenderObject();
      assert(
        !spec.needsStaticPosition ||
            (marker is RenderBox && marker.attached && marker.hasSize),
        tr("Static position requires a laid-out flow marker"),
      );
      final anchor = marker is RenderBox && marker.attached && marker.hasSize
          ? MatrixUtils.transformPoint(marker.getTransformTo(this), Offset.zero)
          : origin + Offset(border.left, border.top);
      current.usedOffset = Offset(
        spec.offset(
          'width',
          current.size.width,
          basis,
          staticPosition: anchor.dx - origin.dx - border.left,
        ),
        spec.offset(
          'height',
          current.size.height,
          basis,
          staticPosition: anchor.dy - origin.dy - border.top,
        ),
      );
      (current.parentData! as _AbsoluteParentData).offset =
          origin + Offset(border.left, border.top) + current.usedOffset;
      item = childAfter(item);
    }
  }

  List<RenderBox> get _paintOrder {
    final items = <RenderBox>[];
    RenderBox? child = childAfter(firstChild!);
    while (child != null) {
      items.add(child);
      child = childAfter(child);
    }
    final order = {for (var i = 0; i < items.length; i++) items[i]: i};
    items.sort((a, b) {
      final z = (a as _RenderAbsoluteItem).spec.zIndex.compareTo(
        (b as _RenderAbsoluteItem).spec.zIndex,
      );
      return z == 0 ? order[a]!.compareTo(order[b]!) : z;
    });
    return [firstChild!, ...items];
  }

  @override
  Iterable<RenderObject> get positionedPaintChildren => _paintOrder;

  @override
  void paint(PaintingContext context, Offset offset) {
    for (final child in _paintOrder) {
      if (_fixedViewport != null && child != firstChild) continue;
      context.paintChild(child, offset + _itemOffset(child));
    }
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) =>
      hitTestChildren(result, position: position);
  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    for (final child in _paintOrder.reversed) {
      if (_fixedViewport != null && child != firstChild) continue;
      final offset = _itemOffset(child);
      if (result.addWithPaintOffset(
        offset: offset,
        position: position,
        hitTest: (result, p) => child.hitTest(result, position: p),
      )) {
        return true;
      }
    }
    return false;
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    final offset = _itemOffset(child);
    transform.translateByDouble(offset.dx, offset.dy, 0, 1);
  }

  @override
  bool hitTestPositioned(BoxHitTestResult result, {required Offset position}) {
    if (_fixedViewport != null) return false;
    for (final child in _paintOrder.skip(1).toList().reversed) {
      if (result.addWithPaintOffset(
        offset: (child.parentData! as _AbsoluteParentData).offset,
        position: position,
        hitTest: (result, p) => child.hitTest(result, position: p),
      )) {
        return true;
      }
    }
    return false;
  }

  @override
  Rect get paintBounds {
    if (!hasSize) return Rect.zero;
    var bounds = Offset.zero & size;
    for (final child in _paintOrder) {
      if (_fixedViewport != null && child != firstChild) continue;
      if (child.hasSize) {
        bounds = bounds.expandToInclude(
          child.paintBounds.shift(
            (child.parentData! as _AbsoluteParentData).offset,
          ),
        );
      }
    }
    return bounds;
  }

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) =>
      firstChild?.getDistanceToActualBaseline(baseline);
  @override
  double? computeDryBaseline(
    BoxConstraints constraints,
    TextBaseline baseline,
  ) => firstChild?.getDryBaseline(constraints, baseline);

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      constraints.constrain(firstChild!.getDryLayout(constraints));
  @override
  double computeMinIntrinsicWidth(double height) =>
      firstChild?.getMinIntrinsicWidth(height) ?? 0;
  @override
  double computeMaxIntrinsicWidth(double height) =>
      firstChild?.getMaxIntrinsicWidth(height) ?? 0;
  @override
  double computeMinIntrinsicHeight(double width) =>
      firstChild?.getMinIntrinsicHeight(width) ?? 0;
  @override
  double computeMaxIntrinsicHeight(double width) =>
      firstChild?.getMaxIntrinsicHeight(width) ?? 0;
}

/// A viewport-fixed subtree never contributes to a scroll container's extent.
abstract interface class NativeDocumentFixedSurface {
  bool get fixedToViewport;
  bool get scrollTranslationIndependent;
}

/// Owns the document viewport outside its root Scrollable. Positioned render
/// objects keep their layout/DOM ancestry; this viewport paints and hit-tests
/// their root stacking order after the scrolling flow.
class NativeDocumentPositioningViewport extends SingleChildRenderObjectWidget {
  const NativeDocumentPositioningViewport({
    super.key,
    this.scrollChanges,
    this.onModalBackdropPointer,
    required super.child,
  });
  final Listenable? scrollChanges;
  final NativeModalBackdropPointerCallback? onModalBackdropPointer;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderNativeDocumentPositioningViewport(
        scrollChanges,
        onModalBackdropPointer,
      );
  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderNativeDocumentPositioningViewport renderObject,
  ) {
    renderObject
      ..scrollChanges = scrollChanges
      ..onModalBackdropPointer = onModalBackdropPointer;
  }
}

class RenderNativeDocumentPositioningViewport extends RenderProxyBox {
  RenderNativeDocumentPositioningViewport(
    this._scrollChanges,
    this._onModalBackdropPointer,
  );
  Listenable? _scrollChanges;
  NativeModalBackdropPointerCallback? _onModalBackdropPointer;
  final _roots = <_RenderAbsoluteLayer>{};
  final _clip = LayerHandle<ClipRectLayer>();
  set scrollChanges(Listenable? value) {
    if (identical(value, _scrollChanges)) return;
    if (attached) _scrollChanges?.removeListener(_scrollChanged);
    _scrollChanges = value;
    if (attached) _scrollChanges?.addListener(_scrollChanged);
    markNeedsPaint();
  }

  set onModalBackdropPointer(NativeModalBackdropPointerCallback? value) {
    _onModalBackdropPointer = value;
  }

  @override
  void handleEvent(PointerEvent event, covariant BoxHitTestEntry entry) {
    final callback = _onModalBackdropPointer;
    if (callback == null || event is! PointerDownEvent) return;
    final topModal = _positioned
        .where((child) => (child as _RenderAbsoluteItem).isModal)
        .lastOrNull;
    if (topModal == null) return;
    final origin = topModal.localToGlobal(Offset.zero, ancestor: this);
    final bounds = origin & topModal.size;
    if (bounds.contains(event.localPosition)) return;
    callback(event, bounds);
  }

  void _scrollChanged() {
    if (_roots.isEmpty) return;
    markNeedsPaint();
    markNeedsSemanticsUpdate();
  }

  void _register(_RenderAbsoluteLayer root) {
    _roots.add(root);
    markNeedsPaint();
  }

  void _unregister(_RenderAbsoluteLayer root) {
    _roots.remove(root);
    if (attached) markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _scrollChanges?.addListener(_scrollChanged);
  }

  @override
  void detach() {
    _scrollChanges?.removeListener(_scrollChanged);
    _clip.layer = null;
    super.detach();
  }

  @override
  void dispose() {
    _clip.layer = null;
    super.dispose();
  }

  List<RenderBox> get _positioned {
    final result = <RenderBox>[];
    for (final root in _roots) {
      if (root.attached && root.hasSize) {
        result.addAll(root._paintOrder.skip(1));
      }
    }
    final order = {for (var i = 0; i < result.length; i++) result[i]: i};
    result.sort((a, b) {
      final left = a as _RenderAbsoluteItem;
      final right = b as _RenderAbsoluteItem;
      final modal = left.modalOrder.compareTo(right.modalOrder);
      if (modal != 0) return modal;
      final z = left.modalOrder > 0
          ? 0
          : left.spec.zIndex.compareTo(right.spec.zIndex);
      return z == 0 ? order[a]!.compareTo(order[b]!) : z;
    });
    return result;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    final items = _positioned;
    if (items.isEmpty) {
      _clip.layer = null;
      return;
    }
    _clip.layer = context.pushClipRect(
      needsCompositing,
      offset,
      Offset.zero & size,
      (context, offset) {
        for (final child in items) {
          if ((child as _RenderAbsoluteItem).isModal) {
            context.canvas.drawRect(
              offset & size,
              Paint()..color = const Color(0x1a000000),
            );
          }
          final translation = MatrixUtils.getAsTranslation(
            child.getTransformTo(this),
          );
          if (translation != null) {
            context.paintChild(child, offset + translation);
          }
        }
      },
      oldLayer: _clip.layer,
    );
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final positioned = _positioned;
    final topModal = positioned
        .where((child) => (child as _RenderAbsoluteItem).isModal)
        .lastOrNull;
    for (final child
        in topModal == null ? positioned.reversed : <RenderBox>[topModal]) {
      final hit = result.addWithPaintTransform(
        transform: child.getTransformTo(this),
        position: position,
        hitTest: (result, p) => child.hitTest(result, position: p),
      );
      if (!hit) continue;
      // Preserve the real native gesture, layout and focus owners even though
      // their ordinary bounds no longer contain the fixed paint.
      RenderObject? node = child.parent;
      while (node != null && node != this) {
        if (node is RenderBox) {
          final ancestor = node;
          result.addWithPaintTransform(
            transform: ancestor.getTransformTo(this),
            position: position,
            hitTest: (result, p) {
              result.add(BoxHitTestEntry(ancestor, p));
              return true;
            },
          );
        }
        node = node.parent;
      }
      return true;
    }
    if (topModal != null) {
      // RenderBox.hitTest adds this viewport once when children report a hit.
      // Adding it here too would dispatch two pointerdowns and close requests.
      return true;
    }
    return super.hitTestChildren(result, position: position);
  }
}
