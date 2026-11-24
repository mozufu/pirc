import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'document_layout.dart';
import 'document_element_scroll.dart';
import 'document_scroll_anchor_state.dart';
export 'document_scroll_anchor_state.dart';

class NativeDocumentScrollAnchorViewport extends SingleChildRenderObjectWidget {
  const NativeDocumentScrollAnchorViewport({
    super.key,
    required this.controller,
    required this.layout,
    required this.data,
    this.elements,
    required super.child,
  });
  final NativeDocumentScrollController controller;
  final NativeDocumentLayoutController layout;
  final NativeDocumentScrollAnchorData data;
  final NativeDocumentElementScrollController? elements;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderNativeDocumentScrollAnchorViewport(
        controller,
        layout,
        data,
        elements,
      );
  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderNativeDocumentScrollAnchorViewport renderObject,
  ) => renderObject.update(controller, layout, data, elements);
}

class RenderNativeDocumentScrollAnchorViewport extends RenderProxyBox {
  RenderNativeDocumentScrollAnchorViewport(
    this.controller,
    this.measurements,
    this.data,
    this.elements,
  );
  NativeDocumentScrollController controller;
  NativeDocumentLayoutController measurements;
  NativeDocumentScrollAnchorData data;
  NativeDocumentElementScrollController? elements;
  final _state = NativeDocumentScrollAnchorState();
  bool _correcting = false, _checkScheduled = false;
  void _scrolled() {
    if (_correcting) return;
    if (controller.positions.length == 1 && controller.position.hasPixels) {
      _state.didScroll(top: controller.position.pixels);
    }
    _requestCheck();
  }

  void _elementScrolled(Set<String> ids, Offset shift, bool reselect) {
    _state.shiftDescendants(ids, shift, reselect: reselect);
    _requestCheck();
  }

  void _bind() {
    controller.addListener(_scrolled);
    // A child can finish a deferred layout without relaying out this viewport.
    // Recheck after its measured frame arrives, including static documents.
    measurements.addListener(_requestCheck);
    elements?.bindAnchoring(
      this,
      nodes: () => data.nodes,
      capture: (ids, basis, offset) => measurements.scrollAnchorFrame(
        ids,
        relativeTo: basis,
        contentOffset: offset,
        scrollports: elements?.anchorScrollports ?? const {},
      ),
      requestCheck: _requestCheck,
      onScroll: _elementScrolled,
    );
  }

  void _unbind() {
    controller.removeListener(_scrolled);
    measurements.removeListener(_requestCheck);
    elements?.unbindAnchoring(this);
    _state.reset();
  }

  void update(
    NativeDocumentScrollController c,
    NativeDocumentLayoutController l,
    NativeDocumentScrollAnchorData d,
    NativeDocumentElementScrollController? e,
  ) {
    if (!identical(c, controller) ||
        !identical(l, measurements) ||
        !identical(d, data) ||
        !identical(e, elements)) {
      if (attached) _unbind();
      controller = c;
      measurements = l;
      data = d;
      elements = e;
      if (attached) _bind();
    }
    markNeedsLayout();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _bind();
  }

  @override
  void detach() {
    _unbind();
    super.detach();
  }

  @override
  void performLayout() {
    super.performLayout();
    _requestCheck();
  }

  void _requestCheck() {
    if (!attached) return;
    data.settled = false;
    if (_checkScheduled) return;
    _checkScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _checkScheduled = false;
      if (!attached || controller.positions.length != 1) return;
      if (data.nodes.isEmpty) {
        _state.reset();
        elements?.prepareAnchoring();
        data.settled = true;
        return;
      }
      final position = controller.position;
      final width = constraints.maxWidth;
      if (!position.hasContentDimensions ||
          !position.hasViewportDimension ||
          !width.isFinite ||
          width <= 0 ||
          position.viewportDimension <= 0 ||
          position.axisDirection != AxisDirection.down) {
        return;
      }
      final frame = measurements.scrollAnchorFrame({
        for (final n in data.nodes.values)
          if (!n.excluded) n.id,
      }, scrollports: elements?.anchorScrollports ?? const {});
      if (frame == null || elements?.prepareAnchoring() == false) return;
      final target = _state.adjust(
        nodes: data.nodes,
        boxes: frame.boxes,
        clips: frame.clips,
        layoutBoxes: frame.layoutBoxes,
        viewport: Size(width, position.viewportDimension),
        pixels: position.pixels,
        min: position.minScrollExtent,
        max: position.maxScrollExtent,
      );
      final rootChanged = target != position.pixels;
      if (rootChanged) {
        _correcting = true;
        try {
          controller.correctAnchorOffset(target);
        } finally {
          _correcting = false;
        }
      }
      final innerChanged = elements?.applyAnchoring() ?? false;
      if (rootChanged || innerChanged) {
        markNeedsLayout();
        _requestCheck();
      } else {
        data.settled = elements?.anchoringSettled ?? true;
      }
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }
}
