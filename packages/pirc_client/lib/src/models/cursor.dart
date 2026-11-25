import 'package:meta/meta.dart';

import '../json.dart';

/// A position in a session's event stream: `"<epoch>:<sequence>"`.
@immutable
class Cursor implements Comparable<Cursor> {
  const Cursor(this.epoch, this.sequence);

  /// Parses `"<epoch>:<sequence>"`; null when malformed.
  static Cursor? tryParse(String? value) {
    if (value == null) return null;
    final parts = value.split(':');
    if (parts.length != 2) return null;
    final epoch = int.tryParse(parts[0]);
    final sequence = int.tryParse(parts[1]);
    if (epoch == null || sequence == null || epoch < 0 || sequence < 0) {
      return null;
    }
    return Cursor(epoch, sequence);
  }

  /// A `{epoch, sequence}` object (a snapshot or reset `watermark`).
  static Cursor? fromJson(Object? json) {
    final epoch = number(field(json, 'epoch'));
    final sequence = number(field(json, 'sequence'));
    return epoch == null || sequence == null ? null : Cursor(epoch, sequence);
  }

  final int epoch;
  final int sequence;

  Map<String, Object?> toJson() => {'epoch': epoch, 'sequence': sequence};

  @override
  int compareTo(Cursor other) => epoch != other.epoch
      ? epoch.compareTo(other.epoch)
      : sequence.compareTo(other.sequence);

  bool operator <=(Cursor other) => compareTo(other) <= 0;

  @override
  bool operator ==(Object other) =>
      other is Cursor && other.epoch == epoch && other.sequence == sequence;

  @override
  int get hashCode => Object.hash(epoch, sequence);

  @override
  String toString() => '$epoch:$sequence';
}
