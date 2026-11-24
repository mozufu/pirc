import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'html_forms.dart';

/// Constraint feedback anchored to the invalid native control. The native
/// popup's exact Chromium/Android paint and localized wording remain subject
/// to visual acceptance; it never changes the document's control geometry.
class NativeHtmlFormFeedback extends StatefulWidget {
  const NativeHtmlFormFeedback({
    super.key,
    required this.forms,
    required this.child,
  });
  final NativeHtmlForms forms;
  final Widget child;
  @override
  State<NativeHtmlFormFeedback> createState() => _NativeHtmlFormFeedbackState();
}

class _NativeHtmlFormFeedbackState extends State<NativeHtmlFormFeedback> {
  OverlayEntry? _popup;
  int _revision = 0;
  @override
  void initState() {
    super.initState();
    widget.forms.addListener(_changed);
  }

  @override
  void didUpdateWidget(NativeHtmlFormFeedback oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.forms != widget.forms) {
      oldWidget.forms.removeListener(_changed);
      widget.forms.addListener(_changed);
      _remove();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (widget.forms.message != null) _changed();
  }

  void _remove() {
    _revision++;
    _popup?.remove();
    _popup?.dispose();
    _popup = null;
  }

  void _changed() {
    _remove();
    final revision = _revision;
    final message = widget.forms.message;
    if (message == null) return;
    final forms = widget.forms;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || revision != _revision || forms != widget.forms) return;
      final anchor = forms.activeAnchor.currentContext;
      if (anchor == null) return;
      await Scrollable.ensureVisible(anchor, alignment: .25);
      // Measure after reveal/caret scrolling has reached a laid-out frame.
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted ||
          !anchor.mounted ||
          revision != _revision ||
          forms != widget.forms ||
          forms.message != message) {
        return;
      }
      final box = anchor.findRenderObject();
      final overlay = Overlay.maybeOf(context);
      final overlayBox = overlay?.context.findRenderObject();
      if (box is! RenderBox || overlayBox is! RenderBox || !box.attached) {
        return;
      }
      final point = box.localToGlobal(Offset.zero, ancestor: overlayBox);
      final size = overlayBox.size;
      final width = math.min(300.0, math.max(0.0, size.width - 24));
      final x = point.dx
          .clamp(12.0, math.max(12.0, size.width - width - 12))
          .toDouble();
      final textStyle = TextStyle(
        inherit: false,
        fontFamily: Theme.of(context).textTheme.bodyMedium?.fontFamily,
        color: const Color(0xff111111),
        fontSize: 13,
        height: 1.35,
        letterSpacing: 0,
        fontWeight: FontWeight.w400,
        fontStyle: FontStyle.normal,
        decoration: TextDecoration.none,
      );
      final text = TextPainter(
        text: TextSpan(text: message, style: textStyle),
        textScaler: MediaQuery.textScalerOf(context),
        textDirection: Directionality.of(context),
      )..layout(maxWidth: math.max(1, width - 52));
      final height = math.max(42.0, text.height + 24);
      text.dispose();
      final bottom = point.dy + box.size.height;
      final y =
          bottom + 6 + height <=
              size.height - MediaQuery.viewInsetsOf(context).bottom - 12
          ? bottom + 6
          : math.max(12.0, point.dy - height - 6);
      _popup = OverlayEntry(
        builder: (context) => Positioned(
          left: x,
          top: y,
          width: width,
          child: IgnorePointer(
            child: Semantics(
              liveRegion: true,
              label: message,
              child: ExcludeSemantics(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: const Color(0xfff7f7f7),
                    border: Border.all(color: const Color(0xff777777)),
                    borderRadius: BorderRadius.circular(3),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x40000000),
                        blurRadius: 4,
                        offset: Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const CustomPaint(
                          size: Size(18, 18),
                          painter: _WarningPainter(),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            message,
                            key: const ValueKey(
                              'native-html-validation-message',
                            ),
                            style: textStyle,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      overlay!.insert(_popup!);
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  @override
  void dispose() {
    widget.forms.removeListener(_changed);
    _remove();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
    canRequestFocus: false,
    onKeyEvent: (_, event) {
      if (event is KeyDownEvent &&
          event.logicalKey == LogicalKeyboardKey.escape &&
          widget.forms.message != null) {
        widget.forms.dismiss();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    },
    child: NotificationListener<ScrollUpdateNotification>(
      onNotification: (notification) {
        if (notification.dragDetails != null) widget.forms.dismiss();
        return false;
      },
      child: Listener(
        onPointerDown: (_) => widget.forms.dismiss(),
        child: KeyedSubtree(
          key: widget.forms.documentAnchor,
          child: widget.child,
        ),
      ),
    ),
  );
}

class _WarningPainter extends CustomPainter {
  const _WarningPainter();
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawCircle(
      size.center(Offset.zero),
      8,
      Paint()..color = const Color(0xffffb52e),
    );
    final paint = Paint()
      ..color = const Color(0xff111111)
      ..strokeWidth = 2;
    canvas.drawLine(const Offset(9, 4), const Offset(9, 10), paint);
    canvas.drawCircle(const Offset(9, 13), 1.1, paint);
  }

  @override
  bool shouldRepaint(_WarningPainter oldDelegate) => false;
}
