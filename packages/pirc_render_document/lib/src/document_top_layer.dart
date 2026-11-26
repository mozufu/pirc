import 'package:flutter/widgets.dart';
import 'package:html/dom.dart' as dom;
import 'package:pirc_render/pirc_render.dart';

/// The top layer of a script-driven document.
///
/// The script runtime marks a dialog that a script opened with `showModal()`
/// with `data-pirc-dialog-modal="<order>"` in its snapshot. Markup cannot
/// claim the top layer on its own: the chat sanitizer drops the marker, the
/// renderer asks this class only inside a document scope or a script-driven
/// document, and a document view must drop the marker from markup that its
/// script did not produce (the old app's `document_navigation.dart` does).
class NativeDocumentTopLayer implements DocumentTopLayer {
  const NativeDocumentTopLayer();

  static const marker = 'data-pirc-dialog-modal';

  @override
  int? orderOf(dom.Element element) {
    final value = element.attributes[marker];
    if (value == null) return null;
    return int.tryParse(value) ?? 0;
  }

  /// A modal dialog keeps keyboard focus inside its own subtree.
  @override
  Widget scope(Widget child) => FocusScope(child: child);
}
