import 'package:flutter/painting.dart';

/// Explicit CSS background-size axes. Auto preserves the intrinsic ratio.
class NativeBackgroundImageSize {
  const NativeBackgroundImageSize(this.width, this.height);
  final ({double value, bool percent})? width, height;
  static NativeBackgroundImageSize? tryParse(String? source) {
    final terms = source?.trim().toLowerCase().split(RegExp(r'\s+'));
    if (terms == null || terms.isEmpty || terms.length > 2) return null;
    ({double value, bool percent})? length(String text) {
      final match = RegExp(
        r'^([0-9]+(?:\.[0-9]+)?|\.[0-9]+)(px|%)?$',
      ).firstMatch(text);
      if (match == null) return null;
      final value = double.tryParse(match[1]!);
      if (value == null ||
          !value.isFinite ||
          (match[2] == null && value != 0)) {
        return null;
      }
      return (value: value, percent: match[2] == '%');
    }

    final second = terms.length == 2 ? terms[1] : 'auto';
    final w = length(terms[0]), h = length(second);
    if ((w == null && terms[0] != 'auto') ||
        (h == null && second != 'auto') ||
        (w == null && h == null)) {
      return null;
    }
    return NativeBackgroundImageSize(w, h);
  }

  Size resolve(Size box, {required Size automatic, double? aspectRatio}) {
    final w = width == null
        ? null
        : width!.value * (width!.percent ? box.width / 100 : 1);
    final h = height == null
        ? null
        : height!.value * (height!.percent ? box.height / 100 : 1);
    return Size(
      w ?? (aspectRatio != null ? h! * aspectRatio : automatic.width),
      h ?? (aspectRatio != null ? w! / aspectRatio : automatic.height),
    );
  }
}
