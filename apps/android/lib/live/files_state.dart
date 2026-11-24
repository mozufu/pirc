import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:pirc_render/src/file_links.dart';
import 'gateway.dart';

class FilesState extends ChangeNotifier {
  FilesState(this.controller, {String initialPath = ''}) {
    controller.addListener(observe);
    observe();
    if (initialPath.isNotEmpty) {
      final target = parseFileTarget(initialPath);
      if (target != null) unawaited(open(target));
    }
  }
  final LiveController controller;
  String? session, origin, client, runStatus;
  String dir = '';
  List<Json> entries = [];
  Json? file;
  String? directoryError, fileError;
  bool loading = false, fileLoading = false, truncated = false, rendered = true;
  bool active = true, stale = false, disposed = false;
  int scope = 0, directoryRead = 0, fileRead = 0, focusRevision = 0;
  int? line, endLine;
  String? get error => fileError ?? directoryError;
  String get cacheKey =>
      'files:${Uri.encodeComponent(origin ?? '')}:${Uri.encodeComponent(client ?? '')}:$session';
  void emit() {
    if (disposed) return;
    if (session != null) {
      controller.panelState[cacheKey] = {
        'dir': dir,
        'entries': entries,
        'file': file,
        'line': line,
        'endLine': endLine,
        'rendered': rendered,
        'truncated': truncated,
      };
    }
    notifyListeners();
  }

  bool valid(int epoch) => !disposed && epoch == scope;
  void observe() {
    final c = controller,
        nextStatus = obj(controller.state['run'])['status'] as String?;
    if (session != c.sessionId || origin != c.origin || client != c.clientId) {
      scope++;
      directoryRead++;
      fileRead++;
      session = c.sessionId;
      origin = c.origin;
      client = c.clientId;
      final cached = controller.panelState[cacheKey] ?? {};
      dir = '${cached['dir'] ?? ''}';
      entries = rows(cached['entries']);
      file = cached['file'] is Map ? obj(cached['file']) : null;
      line = cached['line'] as int?;
      endLine = cached['endLine'] as int?;
      rendered = cached['rendered'] as bool? ?? true;
      directoryError = fileError = null;
      truncated = cached['truncated'] == true;
      stale = false;
      fileLoading = false;
      runStatus = nextStatus;
      if (session != null) {
        unawaited(list(dir));
        if (file != null) {
          unawaited(open(FileTarget('${file!['path']}'), refresh: true));
        }
      } else {
        loading = false;
        emit();
      }
      return;
    }
    final finished = runStatus == 'running' && nextStatus != 'running';
    runStatus = nextStatus;
    if (finished) {
      if (active) {
        reload();
      } else {
        stale = true;
      }
    }
  }

  void setActive(bool value) {
    active = value;
    if (active && stale) reload();
  }

  String describe(Object e) =>
      e is PlatformException && e.code.startsWith('HTTP_') && e.message != null
      ? e.message!
      : LiveController.describe(e);
  Future<void> list(String path, {bool navigate = false}) async {
    final id = session;
    if (id == null) return;
    if (navigate) {
      closeFile();
    }
    final epoch = scope, token = ++directoryRead;
    loading = true;
    directoryError = null;
    if (file == null) fileError = null;
    emit();
    try {
      final result = await controller.gateway.request(
        '${sessionPath(id)}/files?path=${enc(path)}',
      );
      if (!valid(epoch) || token != directoryRead) return;
      dir = '${result['path'] ?? path}';
      entries = rows(result['entries']);
      truncated = result['truncated'] == true;
    } catch (e) {
      if (valid(epoch) && token == directoryRead) directoryError = describe(e);
    } finally {
      if (valid(epoch) && token == directoryRead) {
        loading = false;
        emit();
      }
    }
  }

  Future<void> open(FileTarget target, {bool refresh = false}) async {
    final id = session;
    if (id == null) return;
    final epoch = scope, token = ++fileRead;
    fileLoading = true;
    fileError = null;
    emit();
    try {
      final result = await controller.gateway.request(
        '${sessionPath(id)}/files/content?path=${enc(target.path)}',
      );
      if (!valid(epoch) || token != fileRead) return;
      file = result;
      if (!refresh) {
        final count = '${result['content'] ?? ''}'
            .replaceFirst(RegExp(r'\n$'), '')
            .split('\n')
            .length;
        line = target.line?.clamp(1, count);
        endLine = line == null
            ? null
            : (target.endLine ?? line!).clamp(line!, count);
        rendered = line == null;
        focusRevision++;
      }
      final parent = '${result['path']}'.split('/')..removeLast();
      if (parent.join('/') != dir) unawaited(list(parent.join('/')));
    } catch (e) {
      if (valid(epoch) && token == fileRead) {
        file = null;
        fileError = '${target.path}: ${describe(e)}';
      }
    } finally {
      if (valid(epoch) && token == fileRead) {
        fileLoading = false;
        emit();
      }
    }
  }

  void reload() {
    stale = false;
    unawaited(list(dir));
    if (file != null) {
      unawaited(open(FileTarget('${file!['path']}'), refresh: true));
    }
  }

  void closeFile() {
    ++fileRead;
    fileLoading = false;
    file = null;
    line = endLine = null;
    fileError = null;
    emit();
  }

  void toggle() {
    rendered = !rendered;
    emit();
  }

  @override
  void dispose() {
    disposed = true;
    scope++;
    controller.removeListener(observe);
    super.dispose();
  }
}
