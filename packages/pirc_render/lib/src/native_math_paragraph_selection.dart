import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Wraps a RichText selection registrar so synthetic layout-only text can be
/// omitted from copied content without changing selection offsets or geometry.
///
/// [syntheticTextOffsets] are UTF-16 offsets into the paragraph's full text.
/// Only these known offsets are filtered. Other zero-width characters that
/// came from the document are preserved.
SelectionRegistrar? nativeMathParagraphSelectionRegistrar(
  SelectionRegistrar? registrar,
  Iterable<int> syntheticTextOffsets,
) {
  if (registrar == null) return null;
  final offsets = syntheticTextOffsets.toSet();
  if (offsets.isEmpty) return registrar;
  return _NativeMathMarkerSelectionRegistrar(registrar, offsets);
}

class _NativeMathMarkerSelectionRegistrar extends SelectionRegistrar {
  _NativeMathMarkerSelectionRegistrar(this._delegate, this._offsets);

  final SelectionRegistrar _delegate;
  final Set<int> _offsets;
  final Map<Selectable, _NativeMathMarkerSelectable> _wrappers = {};

  @override
  void add(Selectable selectable) {
    if (_wrappers.containsKey(selectable)) return;
    final wrapper = _NativeMathMarkerSelectable(selectable, _offsets);
    _wrappers[selectable] = wrapper;
    _delegate.add(wrapper);
  }

  @override
  void remove(Selectable selectable) {
    final wrapper = _wrappers.remove(selectable);
    if (wrapper == null) return;
    _delegate.remove(wrapper);
    wrapper.dispose();
  }
}

class _NativeMathMarkerSelectable extends ChangeNotifier implements Selectable {
  _NativeMathMarkerSelectable(this._delegate, this._syntheticOffsets) {
    _delegate.addListener(_onDelegateChanged);
  }

  final Selectable _delegate;
  final Set<int> _syntheticOffsets;

  void _onDelegateChanged() => notifyListeners();

  @override
  SelectionGeometry get value => _delegate.value;

  @override
  Size get size => _delegate.size;

  @override
  List<Rect> get boundingBoxes => _delegate.boundingBoxes;

  @override
  int get contentLength => _delegate.contentLength;

  @override
  SelectedContentRange? getSelection() => _delegate.getSelection();

  @override
  SelectionResult dispatchSelectionEvent(SelectionEvent event) =>
      _delegate.dispatchSelectionEvent(event);

  @override
  void pushHandleLayers(LayerLink? startHandle, LayerLink? endHandle) =>
      _delegate.pushHandleLayers(startHandle, endHandle);

  @override
  SelectedContent? getSelectedContent() {
    final selected = _delegate.getSelectedContent();
    final range = _delegate.getSelection();
    if (selected == null || range == null) return selected;

    final start = math.min(range.startOffset, range.endOffset);
    final end = math.max(range.startOffset, range.endOffset);
    final offsets =
        _syntheticOffsets
            .where((offset) => offset >= start && offset < end)
            .map((offset) => offset - start)
            .where((offset) => offset < selected.plainText.length)
            .toList()
          ..sort();
    if (offsets.isEmpty) return selected;

    final text = selected.plainText;
    final result = StringBuffer();
    var cursor = 0;
    for (final offset in offsets) {
      if (offset < cursor) continue;
      result.write(text.substring(cursor, offset));
      cursor = offset + 1;
    }
    result.write(text.substring(cursor));
    return SelectedContent(plainText: result.toString());
  }

  @override
  Matrix4 getTransformTo(RenderObject? ancestor) =>
      _delegate.getTransformTo(ancestor);

  @override
  void dispose() {
    _delegate.removeListener(_onDelegateChanged);
    super.dispose();
  }
}
