import 'package:meta/meta.dart';

import '../json.dart';

/// The gateway's error body `{error: {code, message, details?}}`.
@immutable
class ErrorBody {
  const ErrorBody({required this.code, required this.message, this.details});

  /// Null when [json] has no `error` object.
  static ErrorBody? fromJson(Object? json) {
    final error = field(json, 'error');
    if (error is! Map) return null;
    return ErrorBody(
      code: text(field(error, 'code')) ?? '',
      message: text(field(error, 'message')) ?? '',
      details: field(error, 'details'),
    );
  }

  final String code;
  final String message;
  final Object? details;
}
