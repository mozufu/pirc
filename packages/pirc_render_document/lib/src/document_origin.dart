/// Serializes a trusted native document location as its HTTP(S) origin.
/// Blob documents inherit the origin of their validated creator-owned URL.
/// This derives request context only; it never grants pairing authorization.
String nativeDocumentOrigin(String location) {
  final candidate = location.startsWith('blob:')
      ? location.substring('blob:'.length)
      : location;
  final url = Uri.tryParse(candidate);
  if (url == null ||
      !{'http', 'https'}.contains(url.scheme) ||
      !url.hasAuthority ||
      url.host.isEmpty) {
    return 'null';
  }
  return url.origin;
}
