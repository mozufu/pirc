import 'dart:typed_data';

/// SHA-1 of [message], used only to check `Sec-WebSocket-Accept` during the
/// manual WebSocket handshake (no `package:crypto` dependency).
Uint8List sha1(List<int> message) {
  final length = message.length;
  final padded = Uint8List(((length + 8) ~/ 64 + 1) * 64)
    ..setRange(0, length, message);
  padded[length] = 0x80;
  final bits = ByteData.sublistView(padded);
  bits.setUint32(padded.length - 8, (length * 8) ~/ 0x100000000);
  bits.setUint32(padded.length - 4, (length * 8) & 0xffffffff);

  var h0 = 0x67452301, h1 = 0xefcdab89, h2 = 0x98badcfe;
  var h3 = 0x10325476, h4 = 0xc3d2e1f0;
  final w = Uint32List(80);
  int rotl(int x, int n) => ((x << n) | (x >> (32 - n))) & 0xffffffff;
  for (var chunk = 0; chunk < padded.length; chunk += 64) {
    for (var i = 0; i < 16; i++) {
      w[i] = bits.getUint32(chunk + i * 4);
    }
    for (var i = 16; i < 80; i++) {
      w[i] = rotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
    }
    var a = h0, b = h1, c = h2, d = h3, e = h4;
    for (var i = 0; i < 80; i++) {
      final int f, k;
      if (i < 20) {
        f = (b & c) | ((~b & 0xffffffff) & d);
        k = 0x5a827999;
      } else if (i < 40) {
        f = b ^ c ^ d;
        k = 0x6ed9eba1;
      } else if (i < 60) {
        f = (b & c) | (b & d) | (c & d);
        k = 0x8f1bbcdc;
      } else {
        f = b ^ c ^ d;
        k = 0xca62c1d6;
      }
      final t = (rotl(a, 5) + f + e + k + w[i]) & 0xffffffff;
      e = d;
      d = c;
      c = rotl(b, 30);
      b = a;
      a = t;
    }
    h0 = (h0 + a) & 0xffffffff;
    h1 = (h1 + b) & 0xffffffff;
    h2 = (h2 + c) & 0xffffffff;
    h3 = (h3 + d) & 0xffffffff;
    h4 = (h4 + e) & 0xffffffff;
  }
  final out = ByteData(20)
    ..setUint32(0, h0)
    ..setUint32(4, h1)
    ..setUint32(8, h2)
    ..setUint32(12, h3)
    ..setUint32(16, h4);
  return out.buffer.asUint8List();
}
