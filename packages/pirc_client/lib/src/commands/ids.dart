import 'dart:convert';
import 'dart:math';

final _random = Random.secure();

/// A random URL-safe identifier (128 bits, base64url without padding):
/// command IDs, first-send operation IDs and client IDs.
String randomId() => base64Url
    .encode(List.generate(16, (_) => _random.nextInt(256)))
    .replaceAll('=', '');
