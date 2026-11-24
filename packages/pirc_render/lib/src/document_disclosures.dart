import 'package:html/dom.dart' as dom;

/// Live disclosure attributes for one static fetched document. IDs come from
/// that document's stable native DOM index, not a renderer rebuild or URL.
class NativeDocumentDisclosures {
  final _entries = <String, _Disclosure>{};

  void apply(dom.Document document) {
    final groups = <String>{};
    for (final element in document.querySelectorAll('details')) {
      final id = element.attributes['data-pirc-script-id'];
      if (id == null) continue;
      final name = element.attributes['name'] ?? '';
      final entry = _entries.putIfAbsent(
        id,
        () => _Disclosure(name, element.attributes.containsKey('open')),
      );
      // Normalize invalid authored groups in tree order, just as native
      // browsers do when parsing multiple initially open members.
      if (entry.open && name.isNotEmpty && !groups.add(name)) {
        entry.open = false;
      }
      if (entry.open) {
        element.attributes['open'] = '';
      } else {
        element.attributes.remove('open');
      }
    }
  }

  bool toggle(String id) {
    final entry = _entries[id];
    if (entry == null) return false;
    _open(id, !entry.open);
    return true;
  }

  void _open(String id, bool open) {
    final entry = _entries[id];
    if (entry == null) return;
    if (open && entry.name.isNotEmpty) {
      for (final peer in _entries.values) {
        if (peer != entry && peer.name == entry.name) peer.open = false;
      }
    }
    entry.open = open;
  }

  /// Reveal only containing details body slots, from inner to outer. A details
  /// element or its first summary is not itself a request to open that details.
  bool reveal(dom.Element target) {
    var changed = false;
    for (
      dom.Element? child = target, parent = target.parent;
      parent != null;
      child = parent, parent = parent.parent
    ) {
      if (parent.localName != 'details') continue;
      final summary = parent.children
          .where((e) => e.localName == 'summary')
          .firstOrNull;
      if (child == summary) continue;
      final id = parent.attributes['data-pirc-script-id'];
      if (id != null && _entries[id]?.open == false) {
        changed = true;
        _open(id, true);
      }
    }
    dom.Node root = target;
    while (root.parentNode != null) {
      root = root.parentNode!;
    }
    if (root is dom.Document) apply(root);
    return changed;
  }
}

class _Disclosure {
  _Disclosure(this.name, this.open);
  final String name;
  bool open;
}
