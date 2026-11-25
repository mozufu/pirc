/// JSON access with JavaScript semantics, so the ported reducer reads decoded
/// JSON (`jsonDecode` output) the way the web client does: `null` and absent
/// are the same, numbers print as `String(n)`, and truthiness follows JS.
library;

/// Milliseconds since the epoch; injected so tests are deterministic.
typedef Now = int Function();

int systemNow() => DateTime.now().millisecondsSinceEpoch;

/// `value?.[key]`: a field of an object, `null` for anything else.
Object? field(Object? value, String key) => value is Map ? value[key] : null;

/// The value when it is a JSON string.
String? str(Object? value) => value is String ? value : null;

/// `String(value)` of a primitive; `null` for null, objects and arrays.
String? text(Object? value) => switch (value) {
  String() => value,
  num() => jsNumber(value),
  bool() => value.toString(),
  _ => null,
};

/// A JSON number as an integer (fractions are cut).
int? number(Object? value) => switch (value) {
  int() => value,
  double() when value.isFinite => value.toInt(),
  _ => null,
};

/// The value when it is a JSON array.
List<Object?>? array(Object? value) => value is List ? value.cast() : null;

/// The value when it is a JSON object.
Map<String, Object?>? object(Object? value) =>
    value is Map ? value.cast() : null;

/// JavaScript truthiness of a JSON value.
bool truthy(Object? value) => switch (value) {
  null => false,
  String() => value.isNotEmpty,
  bool() => value,
  num() => value != 0 && !value.isNaN,
  _ => true,
};

/// `typeof value === 'number' ? value : Date.now()`.
int at(Object? value, Now now) => number(value) ?? now();

/// JavaScript's `String(n)` for the numbers JSON carries.
String jsNumber(num value) {
  if (value is int) return value.toString();
  final d = value.toDouble();
  if (d.isFinite && d == d.truncateToDouble() && d.abs() < 1e21) {
    return d.toInt().toString();
  }
  return d.toString();
}

/// `1200` → `1,200` (`toLocaleString('en-US')` for integers).
String groupThousands(int value) {
  final digits = value.abs().toString();
  final out = StringBuffer(value < 0 ? '-' : '');
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
    out.write(digits[i]);
  }
  return out.toString();
}
