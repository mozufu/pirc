import 'render_l10n.dart';
import 'package:flutter/widgets.dart';
import 'package:html/dom.dart' as dom;
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';

/// The first direct summary owns a details control's activation and focus.
dom.Element? nativeHtmlDetailsSummaryFor(dom.Element element) {
  for (
    dom.Element? current = element;
    current != null;
    current = current.parent
  ) {
    if (current.localName != 'summary') continue;
    final parent = current.parent;
    if (parent?.localName != 'details') return null;
    return parent!.children
                .where((e) => e.localName == 'summary')
                .firstOrNull ==
            current
        ? current
        : null;
  }
  return null;
}

/// Tracks the open member of each named HTML `<details>` group in one document.
///
/// Create one instance for each rendered HTML document and dispose it when the
/// document is replaced. Unnamed details are tracked independently.
class NativeHtmlDetailsGroups {
  final Map<String, Set<_NativeHtmlDetailsState>> _members = {};
  final Map<String, _NativeHtmlDetailsState> _openMembers = {};
  bool _disposed = false;

  /// Releases references to the details controls in this document.
  void dispose() {
    _disposed = true;
    _members.clear();
    _openMembers.clear();
  }

  bool _attach(
    _NativeHtmlDetailsState state,
    String? name,
    bool initiallyOpen,
  ) {
    if (_disposed || name == null || name.isEmpty) return initiallyOpen;

    final members = _members.putIfAbsent(
      name,
      () => <_NativeHtmlDetailsState>{},
    );
    members.add(state);

    // When the document initially contains multiple open members, keep the
    // first one in tree order, matching the browser's exclusive-group behavior.
    final currentOpen = _openMembers[name];
    if (currentOpen != null && currentOpen != state) {
      final nativeId = state.widget.nativeId;
      if (nativeId == null || nativeId != currentOpen.widget.nativeId) {
        return false;
      }
      // A reparse can mount the replacement before retiring the previous
      // renderer of this same DOM node. It is not a competing group member.
      members.remove(currentOpen);
      if (!initiallyOpen) _openMembers.remove(name);
    }
    if (initiallyOpen) _openMembers[name] = state;
    return initiallyOpen;
  }

  void _detach(_NativeHtmlDetailsState state, String? name) {
    if (_disposed || name == null || name.isEmpty) return;
    final members = _members[name];
    members?.remove(state);
    if (members?.isEmpty ?? false) _members.remove(name);
    if (_openMembers[name] == state) _openMembers.remove(name);
  }

  void _setOpen(_NativeHtmlDetailsState state, String? name, bool open) {
    if (_disposed || name == null || name.isEmpty) {
      state._setOpen(open);
      return;
    }

    if (open) {
      final members = _members[name];
      if (members != null) {
        for (final member in members.toList()) {
          if (member != state) member._setOpen(false);
        }
      }
      _openMembers[name] = state;
    } else if (_openMembers[name] == state) {
      _openMembers.remove(name);
    }

    state._setOpen(open);
  }
}

/// Registers the native replacement for an HTML `<details>` element.
///
/// Call this before `super.parse(tree)` in a `WidgetFactory.parse` override:
///
/// ```dart
/// @override
/// void parse(BuildTree tree) {
///   if (registerNativeHtmlDetails(tree, this, detailsGroups)) return;
///   super.parse(tree);
/// }
/// ```
///
/// Returning `true` means the built-in `TagDetails` operation must not be
/// registered for this element. The replacement processes the same child
/// placeholders, keeping their CSS inheritance, links, controls, and selection
/// behavior intact while retaining closed descendants in the widget tree.
bool registerNativeHtmlDetails(
  BuildTree tree,
  WidgetFactory factory,
  NativeHtmlDetailsGroups groups, {
  ValueChanged<dom.Element>? onActivate,
  ValueChanged<dom.Element>? onStaticActivate,
  FocusNode Function(dom.Element)? summaryFocusNode,
}) {
  final element = tree.element;
  if (element.localName != 'details') return false;

  final name = element.attributes['name'];

  tree.register(
    BuildOp(
      alwaysRenderBlock: true,
      debugLabel: 'nativeDetails',
      onRenderedChildren: (detailsTree, children) => _buildNamedDetails(
        detailsTree,
        children,
        factory,
        groups,
        name,
        onActivate,
        onStaticActivate,
        summaryFocusNode,
      ),
      onVisitChild: (detailsTree, subTree) {
        if (nativeHtmlDetailsSummaryFor(subTree.element) != subTree.element ||
            subTree.element.parent != detailsTree.element) {
          return;
        }

        subTree.register(
          BuildOp(
            alwaysRenderBlock: true,
            debugLabel: 'nativeDetailsSummary',
            onParsed: _prependDisclosureMarker,
            onRenderedBlock: (summaryTree, block) {
              _summaryTrees[block] = summaryTree;
            },
          ),
        );
      },
      // No TagDetails operation is registered for this element, so this op is
      // its only details renderer. Keep it early if a caller adds later ops.
      priority: 1,
    ),
  );
  return true;
}

WidgetPlaceholder? _buildNamedDetails(
  BuildTree tree,
  Iterable<WidgetPlaceholder> children,
  WidgetFactory factory,
  NativeHtmlDetailsGroups groups,
  String? name,
  ValueChanged<dom.Element>? onActivate,
  ValueChanged<dom.Element>? onStaticActivate,
  FocusNode Function(dom.Element)? summaryFocusNode,
) {
  WidgetPlaceholder? summary;
  BuildTree? summaryTree;
  final rest = <WidgetPlaceholder>[];

  for (final child in children) {
    final candidateTree = _summaryTrees[child];
    if (summary == null && candidateTree != null) {
      summary = child;
      summaryTree = candidateTree;
    } else {
      rest.add(child);
    }
  }

  final content =
      factory.buildColumnPlaceholder(tree, rest) ??
      WidgetPlaceholder(child: const SizedBox.shrink());
  final summaryPlaceholder = summary ?? _buildDefaultSummary(tree, factory);

  // The disclosure owns its layout. A synthetic column of both branches would
  // lift the hidden body's margins into the outer document even when closed.
  return WidgetPlaceholder(debugLabel: 'nativeDetails--layout').wrapWith((
    context,
    child,
  ) {
    final resolved = tree.inheritanceResolvers.resolve(context);
    final summaryStyle =
        summaryTree?.inheritanceResolvers.resolve(context).prepareTextStyle() ??
        resolved.prepareTextStyle();

    final summaryElement = summaryTree?.element;
    final scripted =
        summaryElement != null &&
        summaryElement.attributes.containsKey('data-pirc-script-id');
    return _NativeHtmlDetails(
      nativeId: tree.element.attributes['data-pirc-script-id'],
      onActivate: scripted && onActivate != null
          ? () => onActivate(summaryElement)
          : onStaticActivate != null &&
                tree.element.attributes['data-pirc-script-id']?.isNotEmpty ==
                    true
          ? () => onStaticActivate(tree.element)
          : null,
      focusNode: scripted ? summaryFocusNode?.call(summaryElement) : null,
      groups: groups,
      name: name,
      initiallyOpen: tree.element.attributes.containsKey('open'),
      summary: summaryPlaceholder,
      summaryStyle: summaryStyle,
      content: content,
      textDirection:
          resolved.get<TextDirection>() ?? Directionality.of(context),
    );
  });
}

WidgetPlaceholder _buildDefaultSummary(BuildTree tree, WidgetFactory factory) {
  // The fallback is uncommon, but the HTML standard supplies a default label
  // when no direct <summary> is present. Build the marker lazily so its open
  // state follows the native control.
  return WidgetPlaceholder(
    debugLabel: 'details--defaultSummary',
    builder: (context, _) {
      final resolved = tree.inheritanceResolvers.resolve(context);
      return factory.buildText(
            tree,
            resolved,
            TextSpan(
              style: resolved.prepareTextStyle(),
              children: [
                WidgetSpan(
                  alignment: PlaceholderAlignment.middle,
                  child: _NativeDetailsMarker(tree: tree),
                ),
                TextSpan(
                  text: tr("Details"),
                  style: resolved.prepareTextStyle(),
                ),
              ],
            ),
          ) ??
          const SizedBox.shrink();
    },
  );
}

BuildTree _prependDisclosureMarker(BuildTree summaryTree) {
  final marker = WidgetBit.inline(
    summaryTree,
    _NativeDetailsMarker(tree: summaryTree),
    alignment: PlaceholderAlignment.middle,
  );
  return summaryTree..prepend(marker);
}

final Expando<BuildTree> _summaryTrees = Expando<BuildTree>();

class _NativeHtmlDetails extends StatefulWidget {
  const _NativeHtmlDetails({
    required this.groups,
    required this.name,
    required this.initiallyOpen,
    required this.summary,
    required this.summaryStyle,
    required this.content,
    required this.textDirection,
    this.onActivate,
    this.nativeId,
    this.focusNode,
  });

  final String? nativeId;
  final VoidCallback? onActivate;
  final FocusNode? focusNode;
  final NativeHtmlDetailsGroups groups;
  final String? name;
  final bool initiallyOpen;
  final Widget summary;
  final TextStyle summaryStyle;
  final Widget content;
  final TextDirection textDirection;

  @override
  State<_NativeHtmlDetails> createState() => _NativeHtmlDetailsState();
}

class _NativeHtmlDetailsState extends State<_NativeHtmlDetails> {
  late bool _isOpen;
  var _showFocus = false;
  final _ownedFocusNode = FocusNode();
  FocusNode get _focusNode => widget.focusNode ?? _ownedFocusNode;

  @override
  void initState() {
    super.initState();
    _isOpen = widget.groups._attach(this, widget.name, widget.initiallyOpen);
  }

  @override
  void didUpdateWidget(covariant _NativeHtmlDetails oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.groups != widget.groups || oldWidget.name != widget.name) {
      oldWidget.groups._detach(this, oldWidget.name);
      _isOpen = widget.groups._attach(this, widget.name, widget.initiallyOpen);
    } else if (oldWidget.initiallyOpen != widget.initiallyOpen) {
      widget.groups._setOpen(this, widget.name, widget.initiallyOpen);
    }
  }

  @override
  void dispose() {
    widget.groups._detach(this, widget.name);
    _ownedFocusNode.dispose();
    super.dispose();
  }

  void _setOpen(bool value) {
    if (!mounted || _isOpen == value) return;
    setState(() => _isOpen = value);
  }

  void _toggle() {
    _focusNode.requestFocus();
    final activate = widget.onActivate;
    if (activate != null) {
      // The script runtime owns cancellation, exclusive groups and publication.
      activate();
    } else {
      widget.groups._setOpen(this, widget.name, !_isOpen);
    }
  }

  @override
  Widget build(BuildContext context) {
    RenderL10n.watch(context);
    final activateAction = _NativeDetailsActivateAction(
      focusNode: _focusNode,
      onActivate: _toggle,
    );

    return _NativeDetailsScope(
      isOpen: _isOpen,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        textDirection: widget.textDirection,
        children: [
          FocusableActionDetector(
            focusNode: _focusNode,
            actions: {
              ActivateIntent: activateAction,
              ButtonActivateIntent: activateAction,
            },
            onShowFocusHighlight: (value) => setState(() => _showFocus = value),
            child: Semantics(
              button: true,
              expanded: _isOpen,
              onTap: _toggle,
              child: GestureDetector(
                excludeFromSemantics: true,
                onTap: _toggle,
                child: DecoratedBox(
                  position: DecorationPosition.foreground,
                  decoration: BoxDecoration(
                    border: _showFocus
                        ? Border.all(
                            color:
                                widget.summaryStyle.color ??
                                const Color(0xFF000000),
                            width: 2,
                          )
                        : null,
                  ),
                  child: widget.summary,
                ),
              ),
            ),
          ),
          ExcludeFocus(
            excluding: !_isOpen,
            child: TickerMode(
              enabled: _isOpen,
              child: Offstage(offstage: !_isOpen, child: widget.content),
            ),
          ),
        ],
      ),
    );
  }
}

class _NativeDetailsScope extends InheritedWidget {
  const _NativeDetailsScope({required this.isOpen, required super.child});

  final bool isOpen;

  @override
  bool updateShouldNotify(_NativeDetailsScope oldWidget) =>
      oldWidget.isOpen != isOpen;
}

class _NativeDetailsMarker extends StatelessWidget {
  const _NativeDetailsMarker({required this.tree});

  final BuildTree tree;

  @override
  Widget build(BuildContext context) {
    RenderL10n.watch(context);
    final scope = context
        .dependOnInheritedWidgetOfExactType<_NativeDetailsScope>();
    final style = tree.inheritanceResolvers.resolve(context).prepareTextStyle();
    return HtmlListMarker(
      markerType: scope?.isOpen == true
          ? HtmlListMarkerType.disclosureOpen
          : HtmlListMarkerType.disclosureClosed,
      textStyle: style,
    );
  }
}

class _NativeDetailsActivateAction extends Action<Intent> {
  _NativeDetailsActivateAction({
    required this.focusNode,
    required this.onActivate,
  });

  final FocusNode focusNode;
  final VoidCallback onActivate;

  @override
  Object? invoke(Intent intent) {
    if (focusNode.hasPrimaryFocus) onActivate();
    return null;
  }
}
