import 'html_controls.dart';
import 'html_date.dart';
import 'html_file.dart';
import 'html_range.dart';
import 'html_select.dart';
import 'html_text_fields.dart';

/// Owns detached native controls for one live static fetched document. This is
/// memory-only DOM state, separate from history snapshots or fresh responses.
/// Retiring it disposes parked resources and invalidates pending picker results.
class NativeHtmlDocumentControls {
  Object? _owner;
  NativeHtmlDetachedControls? _detached;
  bool _disposed = false;
  bool get isDisposed => _disposed;
  bool get hasDetachedControls => _detached != null;

  NativeHtmlDetachedControls? take(Object owner) {
    if (_disposed) return null;
    _owner = owner;
    final value = _detached;
    _detached = null;
    if (value != null) value.taken = true;
    return value;
  }

  bool retain(Object owner, NativeHtmlDetachedControls value) {
    if (_disposed || !identical(owner, _owner)) return false;
    _owner = null;
    _detached?.dispose();
    value.pause();
    _detached = value;
    return true;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _owner = null;
    _detached?.dispose();
    _detached = null;
  }
}

/// Detached models never retain renderer callbacks, forms or button actions.
/// A new renderer adopts uniquely identified records into freshly parsed
/// descriptors, preserving authored defaults for Reset.
class NativeHtmlDetachedControls {
  NativeHtmlDetachedControls({
    required this.controls,
    required this.textFields,
    required this.ranges,
    required this.selects,
    required this.dates,
    required this.files,
  });
  final NativeHtmlControlState controls;
  final NativeHtmlTextFieldState textFields;
  final NativeHtmlRangeState ranges;
  final NativeHtmlSelectState selects;
  final NativeHtmlDateState dates;
  final NativeHtmlFileInputState files;
  bool taken = false;
  bool _disposed = false;
  bool get isDisposed => _disposed;

  void pause() {
    controls
      ..onUserEvent = null
      ..onActivateControl = null;
    textFields
      ..onUserEvent = null
      ..onDetailedUserEvent = null
      ..onUserKeyEvent = null
      ..onSubmit = null;
    selects
      ..onUserEvent = null
      ..onDetailedUserEvent = null
      ..onUserKeyEvent = null;
    ranges.onUserEvent = null;
    dates
      ..onUserEvent = null
      ..onSubmit = null;
    files
      ..onUserEvent = null
      ..onActivateControl = null
      ..picker = _inactivePicker;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    controls.dispose();
    textFields.dispose();
    ranges.dispose();
    selects.dispose();
    dates.dispose();
    files.dispose();
  }
}

Future<List<NativeHtmlFile>?> _inactivePicker(
  NativeHtmlFilePickerRequest _,
) async => null;
