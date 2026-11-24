import 'render_l10n.dart';
import 'dart:convert';
import 'package:html/parser.dart' as html;
import 'package:html/dom.dart' as dom;

const nativeFragmentAttribute = 'data-pirc-native-fragment';

class NativeDocumentFragmentTarget {
  const NativeDocumentFragmentTarget.anchor(this.anchor)
    : top = false,
      nativeId = null;
  const NativeDocumentFragmentTarget.top()
    : anchor = null,
      top = true,
      nativeId = null;

  /// The VM's selected node, including null when the indicated part was missing.
  /// It is independent of later ID changes or another duplicate in the DOM.
  const NativeDocumentFragmentTarget.native(this.nativeId)
    : anchor = null,
      top = false;
  final String? anchor;
  final String? nativeId;
  final bool top;
}

/// Private rendering aliases keep duplicate IDs/names in DOM order without
/// changing the original attributes used by CSS, forms or the scripting DOM.
class NativeDocumentFragmentIndex {
  NativeDocumentFragmentIndex(String source, String nonce) {
    final fragment = html.parseFragment(source);
    _annotate(fragment.querySelectorAll('*'), nonce);
    _annotatedHtml = fragment.outerHtml;
  }

  /// Annotates the renderer's existing DOM clone without serializing another
  /// copy of inline script sources. The caller serializes its body afterwards.
  NativeDocumentFragmentIndex.fromDocument(
    dom.Document document,
    String nonce,
  ) {
    _annotate(document.querySelectorAll('*'), nonce);
  }

  void _annotate(Iterable<dom.Element> elements, String nonce) {
    var sequence = 0;
    for (final element in elements) {
      element.attributes.remove(nativeFragmentAttribute);
      final id = element.attributes['id'];
      final name = element.localName == 'a' ? element.attributes['name'] : null;
      if ((id == null || id.isEmpty) && (name == null || name.isEmpty)) {
        continue;
      }
      final alias = 'pirc-$nonce-fragment-${++sequence}';
      element.attributes[nativeFragmentAttribute] = alias;
      final nativeId = element.attributes['data-pirc-script-id'];
      if (nativeId != null) _nativeIds[alias] = nativeId;
      if (id != null && id.isNotEmpty) _ids.putIfAbsent(id, () => alias);
      if (name != null && name.isNotEmpty) {
        _names.putIfAbsent(name, () => alias);
      }
    }
  }

  String? _annotatedHtml;
  String get annotatedHtml =>
      _annotatedHtml ??
      (throw StateError(tr("Serialize the annotated document clone directly")));
  final _ids = <String, String>{},
      _names = <String, String>{},
      _nativeIds = <String, String>{};
  String? nativeIdFor(String alias) => _nativeIds[alias];
  String? anchorFor(String value) => _ids[value] ?? _names[value];

  NativeDocumentFragmentTarget? select(String raw) {
    if (raw.isEmpty) return const NativeDocumentFragmentTarget.top();
    final literal = anchorFor(raw);
    if (literal != null) return NativeDocumentFragmentTarget.anchor(literal);
    final decoded = decodeNativeDocumentFragment(raw);
    final anchor = anchorFor(decoded);
    if (anchor != null) return NativeDocumentFragmentTarget.anchor(anchor);
    if (decoded.toLowerCase() == 'top') {
      return const NativeDocumentFragmentTarget.top();
    }
    return null;
  }
}

/// Resolves the same indicated element as fragment navigation, before layout.
/// Hidden elements and legacy named anchors participate; top/missing is null.
dom.Element? nativeDocumentFragmentElement(dom.Document document, String raw) {
  if (raw.isEmpty) return null;
  dom.Element? find(String name) {
    final elements = document.querySelectorAll('*');
    return elements.where((e) => e.id == name).firstOrNull ??
        elements
            .where((e) => e.localName == 'a' && e.attributes['name'] == name)
            .firstOrNull;
  }

  return find(raw) ?? find(decodeNativeDocumentFragment(raw));
}

/// Retains the selected renderer identity until actual navigation. A History
/// API URL rewrite does not itself change the target. Static documents retain
/// their renderer IDs across view remounts; scripted documents use VM identity.
class NativeDocumentTargetState {
  NativeDocumentTargetState(this.url);
  String url;
  int revision = 0;
  bool _pending = true;
  bool ancestorsRevealed = false;
  int _handledRevealRevision = -1;
  bool get revealHandled => _handledRevealRevision == revision;
  void markRevealHandled(int value) {
    if (value == revision) _handledRevealRevision = value;
  }

  String? _nativeId;
  void navigate(String value) {
    url = value;
    revision++;
    ancestorsRevealed = false;
    _pending = true;
  }

  dom.Element? resolve(
    dom.Document document, {
    bool Function(dom.Element)? reveal,
  }) {
    final elements = document.querySelectorAll('*');
    if (_pending) {
      final hash = url.indexOf('#');
      final target = hash < 0
          ? null
          : nativeDocumentFragmentElement(document, url.substring(hash + 1));
      ancestorsRevealed = target != null && (reveal?.call(target) ?? false);
      _nativeId = target?.attributes['data-pirc-script-id'];
      _pending = false;
    }
    final id = _nativeId;
    return id == null
        ? null
        : elements
              .where((e) => e.attributes['data-pirc-script-id'] == id)
              .firstOrNull;
  }
}

String decodeNativeDocumentFragment(String value) {
  final bytes = <int>[0];
  var position = 0;
  while (position < value.length) {
    if (value.codeUnitAt(position) == 0x25 && position + 2 < value.length) {
      final pair = value.substring(position + 1, position + 3);
      if (RegExp(r'^[0-9a-fA-F]{2}$').hasMatch(pair)) {
        bytes.add(int.parse(pair, radix: 16));
        position += 3;
        continue;
      }
    }
    final next = value.indexOf('%', position + 1);
    final end = next < 0 ? value.length : next;
    bytes.addAll(utf8.encode(value.substring(position, end)));
    position = end;
  }
  // A prefix avoids Dart's BOM stripping; URL fragments preserve U+FEFF.
  return utf8.decode(bytes, allowMalformed: true).substring(1);
}
