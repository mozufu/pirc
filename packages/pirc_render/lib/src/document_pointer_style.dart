/// Canonical pointer-events keywords accepted by the pinned Chromium CSS parser.
const nativeDocumentPointerKeywords = <String>{
  'auto',
  'none',
  'visiblepainted',
  'visiblefill',
  'visiblestroke',
  'visible',
  'painted',
  'fill',
  'stroke',
  'all',
  'bounding-box',
};
String nativeDocumentPointerValue(String? raw, String inherited) {
  final value = raw?.trim().toLowerCase();
  if (value == 'initial') return 'auto';
  if (value == null ||
      const {'inherit', 'unset', 'revert', 'revert-layer'}.contains(value)) {
    return inherited;
  }
  return nativeDocumentPointerKeywords.contains(value) ? value : inherited;
}
