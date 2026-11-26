import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../../platform/files.dart';
import 'attachments.dart';

/// Opens the file picker for a composer. Returns the pick, or null when the
/// picker could not open; either problem is shown in a snack bar. A tap
/// while a picker is already open (`BUSY`) is ignored quietly.
Future<AttachmentPick?> pickAttachments(
  BuildContext context,
  WidgetRef ref,
) async {
  final l10n = AppLocalizations.of(context);
  final messenger = ScaffoldMessenger.maybeOf(context);
  final AttachmentPick pick;
  try {
    pick = await ref.read(filePickerProvider)();
  } on FilesFailure catch (error) {
    if (error.code != FilesError.busy) {
      messenger?.showSnackBar(SnackBar(content: Text(l10n.filePickerFailed)));
    }
    return null;
  } on Exception {
    messenger?.showSnackBar(SnackBar(content: Text(l10n.filePickerFailed)));
    return null;
  }
  showRefusedAttachments(messenger, l10n, pick);
  return pick;
}

/// Names the files of [pick] that were not added, by reason, if any.
void showRefusedAttachments(
  ScaffoldMessengerState? messenger,
  AppLocalizations l10n,
  AttachmentPick pick,
) {
  if (pick.refused.isEmpty) return;
  String names(String reason) => [
    for (final file in pick.refused)
      if (file.reason == reason) file.name,
  ].join(', ');
  final tooLarge = names(RefusedFile.tooLarge);
  final tooMany = names(RefusedFile.tooMany);
  final unreadable = [
    for (final file in pick.refused)
      if (file.reason != RefusedFile.tooLarge &&
          file.reason != RefusedFile.tooMany)
        file.name,
  ].join(', ');
  messenger?.showSnackBar(
    SnackBar(
      content: Text(
        [
          if (tooLarge.isNotEmpty) l10n.filesTooLarge(tooLarge),
          if (tooMany.isNotEmpty) l10n.filesTooMany(tooMany),
          if (unreadable.isNotEmpty) l10n.filesUnreadable(unreadable),
        ].join('\n'),
      ),
    ),
  );
}

/// Reads the clipboard's images through the files channel and gives them
/// to [onPick]; the text part is pasted by Flutter as usual.
void pasteClipboardImages(
  FilesPlatform files,
  void Function(FilePick pick) onPick,
) {
  unawaited(() async {
    try {
      // The description first: only a clip with images is read.
      if (!await files.clipboardHasImages()) return;
      final pick = await files.clipboardImages();
      if (!pick.isEmpty) onPick(pick);
    } on Object {
      // A clipboard that cannot be read pastes its text only.
    }
  }());
}

/// The composer field's text menu. With the files channel (Android) its
/// Paste also takes the clipboard's images, as in the old app. Paste is
/// always offered there: Flutter shows its own only for text, and an image
/// has none.
Widget composerContextMenu(
  BuildContext context,
  EditableTextState editable, {
  required FilesPlatform? files,
  required void Function(FilePick pick) onPick,
}) {
  if (files == null) {
    return AdaptiveTextSelectionToolbar.editableText(
      editableTextState: editable,
    );
  }
  void paste() {
    editable.hideToolbar();
    pasteClipboardImages(files, onPick);
    unawaited(editable.pasteText(SelectionChangedCause.toolbar));
  }

  final items = [
    for (final item in editable.contextMenuButtonItems)
      item.type == ContextMenuButtonType.paste
          ? ContextMenuButtonItem(
              type: ContextMenuButtonType.paste,
              onPressed: paste,
            )
          : item,
  ];
  if (!editable.widget.readOnly &&
      !items.any((item) => item.type == ContextMenuButtonType.paste)) {
    items.insert(
      0,
      ContextMenuButtonItem(
        type: ContextMenuButtonType.paste,
        onPressed: paste,
      ),
    );
  }
  return AdaptiveTextSelectionToolbar.buttonItems(
    anchors: editable.contextMenuAnchors,
    buttonItems: items,
  );
}

/// The paste shortcut (Ctrl+V, `PasteTextIntent`) with images, for an
/// `Actions` above the composer field; empty without the files channel.
Map<Type, Action<Intent>> pasteActions({
  required FilesPlatform? files,
  required void Function(FilePick pick) onPick,
}) => files == null
    ? const {}
    : {PasteTextIntent: _PasteWithImages(files, onPick)};

/// Overrides the field's own paste: takes the images, then lets the field
/// paste the text.
class _PasteWithImages extends Action<PasteTextIntent> {
  _PasteWithImages(this.files, this.onPick);

  final FilesPlatform files;
  final void Function(FilePick pick) onPick;

  @override
  Object? invoke(PasteTextIntent intent) {
    pasteClipboardImages(files, onPick);
    return callingAction?.invoke(intent);
  }
}

/// Images the keyboard inserts (Gboard's clipboard and stickers send them
/// with `commitContent`, not through the text menu), as in the old app.
/// Null without the files channel: Web and macOS keep the default.
ContentInsertionConfiguration? keyboardImages({
  required FilesPlatform? files,
  required void Function(FilePick pick) onPick,
}) => files == null
    ? null
    : ContentInsertionConfiguration(
        allowedMimeTypes: const [
          ...kDefaultContentInsertionMimeTypes,
          'image/avif',
          'image/heic',
          'image/heif',
        ],
        onContentInserted: (content) => onPick(keyboardImage(content)),
      );

/// One keyboard insertion as a pick, refused when it has no bytes or more
/// than [FilesPlatform.maxFileBytes].
///
/// Flutter's engine reads the inserted content whole into memory on its
/// own, before Dart sees it, so this limit decides only what is attached,
/// not what is read.
FilePick keyboardImage(KeyboardInsertedContent content) {
  final name = cleanFileName(
    Uri.tryParse(content.uri)?.pathSegments.lastOrNull,
  );
  final data = content.data;
  if (!content.mimeType.startsWith('image/')) return FilePick.empty;
  if (data == null || data.isEmpty) {
    return FilePick(refused: [RefusedFile(name, RefusedFile.unreadable)]);
  }
  if (data.length > FilesPlatform.maxFileBytes) {
    return FilePick(refused: [RefusedFile(name, RefusedFile.tooLarge)]);
  }
  return FilePick(
    files: [PickedFile(name: name, mimeType: content.mimeType, bytes: data)],
  );
}

/// The last part of [name] without control (Cc) or format (Cf) characters,
/// at most 200 UTF-16 units, as Kotlin's `cleanFileName` does; [fallback]
/// when nothing is left.
String cleanFileName(String? name, {String fallback = 'image'}) {
  final last = (name ?? '').split(RegExp(r'[/\\]')).last;
  var clean = last
      .replaceAll(RegExp(r'[\p{Cc}\p{Cf}]', unicode: true), '')
      .trim();
  if (clean.length > 200) {
    clean = clean.substring(0, 200);
    final end = clean.codeUnitAt(199);
    if (end >= 0xd800 && end <= 0xdbff) clean = clean.substring(0, 199);
  }
  return clean.isEmpty || clean == '.' || clean == '..' ? fallback : clean;
}

/// Takes images dropped from another app onto [child] (Android, split
/// screen or a desktop window). It gives Kotlin its visible bounds after a
/// build or a change of metrics, then checks them after every drawn frame
/// while it is registered (so a moving ancestor is caught) and sends them
/// only when they change. It takes them back when it is covered, disabled,
/// in the background or gone.
class ComposerDropTarget extends StatefulWidget {
  const ComposerDropTarget({
    super.key,
    required this.files,
    required this.onPick,
    required this.child,
    this.enabled = true,
  });

  final FilesPlatform files;
  final void Function(FilePick pick) onPick;
  final Widget child;

  /// False while the composer takes no input: drops are not offered.
  final bool enabled;

  @override
  State<ComposerDropTarget> createState() => _ComposerDropTargetState();
}

class _ComposerDropTargetState extends State<ComposerDropTarget>
    with WidgetsBindingObserver {
  static var _tokens = 0;

  final _bounds = GlobalKey();
  final int _token = ++_tokens;
  StreamSubscription<FileDrop>? _drops;
  Rect? _registered;
  bool _queued = false;
  bool _shown = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _listen();
  }

  void _listen() {
    _drops = widget.files.drops.listen((drop) {
      if (drop.token == _token && _registered != null && mounted) {
        widget.onPick(drop.pick);
      }
    });
  }

  @override
  void didUpdateWidget(ComposerDropTarget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.files != widget.files) {
      unawaited(_drops?.cancel());
      if (_registered != null) _clear(oldWidget.files);
      _listen();
    }
  }

  @override
  void didChangeMetrics() => _schedule();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Inactive stays: in split screen the window loses focus while the
    // user drags from the other app.
    _shown =
        state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;
    // No frame is drawn in the background: take the target back now.
    if (!_shown && _registered != null) {
      _clear(widget.files);
    } else {
      _schedule();
    }
  }

  void _schedule() {
    if (_queued || !mounted) return;
    _queued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _queued = false;
      if (!mounted) return;
      _sync();
      // Checks again after the next drawn frame; this asks for no frame.
      if (_registered != null) _schedule();
    });
  }

  void _sync() {
    final box = _bounds.currentContext?.findRenderObject();
    final visible =
        widget.enabled &&
        _shown &&
        box is RenderBox &&
        box.attached &&
        box.hasSize &&
        TickerMode.valuesOf(context).enabled &&
        ModalRoute.of(context)?.isCurrent != false;
    final rect = visible ? box.localToGlobal(Offset.zero) & box.size : null;
    if (rect == _registered) return;
    if (rect == null || rect.isEmpty) {
      if (_registered != null) _clear(widget.files);
      return;
    }
    _registered = rect;
    unawaited(
      widget.files
          .setDropTarget(_token, rect, View.of(context).devicePixelRatio)
          .catchError((Object _) => _registered = null),
    );
  }

  void _clear(FilesPlatform files) {
    _registered = null;
    unawaited(files.clearDropTarget(_token).catchError((Object _) {}));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_drops?.cancel());
    if (_registered != null) _clear(widget.files);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _schedule();
    return KeyedSubtree(key: _bounds, child: widget.child);
  }
}
