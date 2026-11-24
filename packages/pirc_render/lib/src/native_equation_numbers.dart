import 'package:flutter/widgets.dart';

/// KaTeX's counter belongs to the document, with rows in visible tree order.
class NativeEquationNumberDocument extends StatefulWidget {
  const NativeEquationNumberDocument({super.key, required this.child});
  final Widget child;
  static Widget ensure(BuildContext context, Widget child) =>
      context.dependOnInheritedWidgetOfExactType<_NumberScope>() == null
      ? NativeEquationNumberDocument(child: child)
      : child;
  @override
  State<NativeEquationNumberDocument> createState() => _NumberDocumentState();
}

class _NumberDocumentState extends State<NativeEquationNumberDocument> {
  static final _documents = <_NumberDocumentState>{};
  static bool _observerInstalled = false;
  final slots = <_NumberSlotState>{};
  bool queued = false;

  @override
  void initState() {
    super.initState();
    _documents.add(this);
    if (!_observerInstalled) {
      _observerInstalled = true;
      // Descendant Offstage changes and keyed reorders can retain identical
      // slot widgets. Reconcile after real frames, without requesting frames
      // merely to poll. One observer keeps no disposed document references.
      WidgetsBinding.instance.addPersistentFrameCallback((_) {
        for (final document in _documents.toList()) {
          if (document.slots.isNotEmpty) document.schedule();
        }
      });
    }
  }

  @override
  void dispose() {
    _documents.remove(this);
    slots.clear();
    super.dispose();
  }

  void register(_NumberSlotState slot) {
    slots.add(slot);
    schedule();
  }

  void unregister(_NumberSlotState slot) {
    slots.remove(slot);
    schedule();
  }

  void schedule() {
    if (queued || !mounted) return;
    queued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      queued = false;
      if (!mounted) return;
      var next = 1;
      void visit(Element element) {
        if (element.widget is NativeEquationNumberDocument) return;
        if (element.widget case Offstage(offstage: true)) return;
        if (element case StatefulElement(state: _NumberSlotState slot)) {
          if (identical(slot.document, this)) {
            slot.assign(next);
            next += slot.widget.count;
          }
        }
        element.visitChildElements(visit);
      }

      context.visitChildElements(visit);
    });
  }

  @override
  void didUpdateWidget(covariant NativeEquationNumberDocument oldWidget) {
    super.didUpdateWidget(oldWidget);
    schedule();
  }

  @override
  Widget build(BuildContext context) =>
      _NumberScope(document: this, child: widget.child);
}

class _NumberScope extends InheritedWidget {
  const _NumberScope({required this.document, required super.child});
  final _NumberDocumentState document;
  @override
  bool updateShouldNotify(_NumberScope oldWidget) =>
      !identical(document, oldWidget.document);
}

class NativeEquationNumberSlot extends StatefulWidget {
  const NativeEquationNumberSlot({
    super.key,
    required this.count,
    required this.builder,
  }) : assert(count >= 0);
  final int count;
  final Widget Function(int firstNumber) builder;
  @override
  State<NativeEquationNumberSlot> createState() => _NumberSlotState();
}

class _NumberSlotState extends State<NativeEquationNumberSlot> {
  _NumberDocumentState? document;
  int firstNumber = 1;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = context
        .dependOnInheritedWidgetOfExactType<_NumberScope>()
        ?.document;
    if (!identical(next, document)) {
      document?.unregister(this);
      document = next;
      firstNumber = 1;
    }
    document?.register(this);
  }

  @override
  void didUpdateWidget(covariant NativeEquationNumberSlot oldWidget) {
    super.didUpdateWidget(oldWidget);
    document?.schedule();
  }

  void assign(int value) {
    if (mounted && firstNumber != value) setState(() => firstNumber = value);
  }

  @override
  void deactivate() {
    document?.unregister(this);
    super.deactivate();
  }

  @override
  Widget build(BuildContext context) => widget.builder(firstNumber);
}
