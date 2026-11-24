import 'package:flutter/widgets.dart';

/// The pinned KaTeX whole-expression error uses ordinary paragraph text and
/// its fixed error color, without a KaTeX display line box or display margins.
class NativeMathErrorText extends StatelessWidget {
  const NativeMathErrorText({
    super.key,
    required this.source,
    required this.bodyFontSize,
    required this.lineHeight,
    required this.block,
    required this.fontFamily,
  });
  final String source;
  final double bodyFontSize, lineHeight;
  final bool block;
  final String? fontFamily;

  @override
  Widget build(BuildContext context) {
    final text = Text(
      source.replaceAll(RegExp(r'[\t\n\r\f ]+'), ' '),
      style: TextStyle(
        fontFamily: fontFamily,
        fontSize: bodyFontSize,
        height: lineHeight,
        letterSpacing: 0,
        color: const Color(0xffcc0000),
      ),
    );
    if (!block) return text;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: text,
    );
  }
}
