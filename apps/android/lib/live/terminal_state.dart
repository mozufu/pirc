import '../l10n/app_i18n.dart';
import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'terminal_input.dart';
import 'terminal_requests.dart';
import 'gateway.dart';

String terminalError(Object error, String fallback) => switch (error) {
  PlatformException(:final message) => message ?? fallback,
  StateError(:final message) => message,
  Exception() => error.toString().replaceFirst(RegExp(r'^Exception: '), ''),
  _ => fallback,
};

/// The small execution-path label of a terminal tab; untagged legacy
/// terminals stay unlabeled and are never shown as isolated.
String? terminalPathLabel(Json terminal) => switch (terminal['executionPath']) {
  'isolated_work' => tr("isolated"),
  'host_management' => tr("host management"),
  _ => null,
};

/// Why the ordinary New terminal action did not POST.
String terminalUnavailableMessage(TerminalRequestTracker tracker) {
  final error = tracker.capabilitiesError, caps = tracker.capabilities;
  if (error != null) {
    return terminalError(error, tr("Unable to read terminal capabilities."));
  }
  return switch (caps?.availability) {
    TerminalAvailability.disabled => tr(
      "New terminals are disabled on this Node.",
    ),
    TerminalAvailability.isolationUnavailable =>
      caps!.offersHostManagement
          ? tr(
              "Isolated terminals are unavailable on this Node. A host management terminal can be reviewed separately.",
            )
          : tr("Isolated terminals are unavailable on this Node."),
    _ => tr("Update the Node to open terminals from this app."),
  };
}

/// The client-facing text of each contract state.
String terminalRequestMessage(TerminalRequestEntry entry) {
  final code = entry.errorCode ?? '';
  final message = switch (entry.status) {
    TerminalRequestStatus.submitting => tr("Starting terminal…"),
    TerminalRequestStatus.ambiguous => tr(
      "The terminal request's outcome is unknown. Check its status; it is not sent again automatically.",
    ),
    TerminalRequestStatus.notAdmitted => tr(
      "The Node has not received this terminal request.",
    ),
    TerminalRequestStatus.conflict => tr(
      "This terminal request belongs to a different terminal intent.",
    ),
    TerminalRequestStatus.rejected => tr(
      "The terminal request was refused: {0}",
      [terminalError(entry.error ?? '', tr("Unable to open a terminal."))],
    ),
    TerminalRequestStatus.review => tr("Review the host management terminal"),
    TerminalRequestStatus.stale => tr(
      "This review is from an earlier Node run and cannot be confirmed.",
    ),
    TerminalRequestStatus.expired => tr(
      "This review expired and cannot be confirmed.",
    ),
    TerminalRequestStatus.preparing => tr("Preparing isolated terminal…"),
    TerminalRequestStatus.live => tr("Terminal running."),
    TerminalRequestStatus.notStarted => tr("The terminal did not start: {0}", [
      code.isEmpty ? '—' : code,
    ]),
    TerminalRequestStatus.outcomeUnknown => tr(
      "Start not confirmed. Workspace switching may stay blocked until the Node resolves it.",
    ),
    TerminalRequestStatus.settled => tr("Terminal closed."),
    TerminalRequestStatus.unconfirmed => tr(
      "Terminal closed, but its retirement is not confirmed. Workspace switching may stay blocked.",
    ),
    TerminalRequestStatus.unrecognized => tr(
      "Unknown terminal request state: {0}",
      [entry.result?.state ?? '—'],
    ),
  };
  final failure = entry.error;
  return failure != null &&
          entry.status != TerminalRequestStatus.rejected &&
          entry.status != TerminalRequestStatus.conflict
      ? '$message (${terminalError(failure, tr("Unable to open a terminal."))})'
      : message;
}

String terminalRequestActionLabel(
  TerminalRequestAction action,
  TerminalRequestKind kind,
) => switch (action) {
  TerminalRequestAction.refresh => tr("Check status"),
  TerminalRequestAction.resubmit => tr("Send again"),
  TerminalRequestAction.confirm => tr("Confirm and open"),
  TerminalRequestAction.attach => tr("Open terminal"),
  TerminalRequestAction.startOver =>
    kind == TerminalRequestKind.host ? tr("New review") : tr("Try again"),
  TerminalRequestAction.hostManagement => tr("Host management terminal…"),
  TerminalRequestAction.dismiss => tr("Dismiss"),
};

class TerminalPaneState extends ChangeNotifier {
  TerminalPaneState(this.controller) {
    controller.addListener(observe);
    observe();
  }
  final LiveController controller;
  String? session, origin, client, current;
  String error = '', listError = '';
  List<Json> terminals = [];
  bool busy = false, disposed = false;
  int epoch = 0, listRevision = 0;
  final closing = <String>{};

  /// The terminal execution-path request flow of the current session.
  TerminalRequestTracker? requests;
  bool get hasControl => controller.control['held'] == true;
  dynamic get generation => controller.control['generation'];

  /// What a terminal POST would carry now; null without the control lease.
  TerminalIntent? get intent {
    final id = session, owner = client, value = generation;
    if (id == null || owner == null || value == null || !hasControl) {
      return null;
    }
    return TerminalIntent(sessionId: id, clientId: owner, generation: value);
  }

  /// Requests to show: everything not yet attached as a live terminal tab.
  List<TerminalRequestEntry> get pendingRequests => [
    for (final entry in requests?.entries ?? const <TerminalRequestEntry>[])
      if (entry.status != TerminalRequestStatus.live) entry,
  ];
  bool valid(int e) =>
      !disposed &&
      e == epoch &&
      session == controller.sessionId &&
      origin == controller.origin &&
      client == controller.clientId;
  void emit() {
    if (!disposed) notifyListeners();
  }

  void observe() {
    if (session != controller.sessionId ||
        origin != controller.origin ||
        client != controller.clientId) {
      epoch++;
      session = controller.sessionId;
      origin = controller.origin;
      client = controller.clientId;
      terminals = [];
      current = null;
      error = listError = '';
      busy = false;
      closing.clear();
      requests?.dispose();
      requests = session == null ? null : tracker(session!);
      if (session != null) unawaited(load());
    }
    emit();
  }

  TerminalRequestTracker tracker(String id) => TerminalRequestTracker(
    api: TerminalRequestApi(controller.gateway),
    session: id,
    current: () => intent,
    onLive: attach,
  )..addListener(emit);

  /// Show a live terminal linked to a request and attach to its stream.
  void attach(Json terminal) {
    final id = '${terminal['id']}';
    listRevision++;
    terminals = [
      ...terminals.where((t) => t['exited'] != true && t['id'] != id),
      terminal,
    ];
    current = id;
    emit();
  }

  Future<void> load() async {
    final e = epoch, revision = ++listRevision, id = session;
    if (id == null) return;
    listError = '';
    final flow = requests;
    if (flow != null) {
      // Discovery replaces persisted pending IDs; it needs no control lease.
      unawaited(flow.loadCapabilities());
      unawaited(flow.recover());
    }
    try {
      final data = await controller.gateway.request(
        '${sessionPath(id)}/terminals',
      );
      if (!valid(e) || revision != listRevision) return;
      terminals = rows(data['terminals']);
      if (!terminals.any((t) => t['id'] == current)) {
        current = terminals.lastOrNull?['id'];
      }
    } catch (e2) {
      if (valid(e) && revision == listRevision) {
        listError = terminalError(e2, tr("Terminals are unavailable."));
      }
    }
    if (valid(e)) emit();
  }

  void select(String id) {
    current = id;
    emit();
  }

  /// The ordinary New terminal action: an isolated work request with a new
  /// ID, never the omitted-path host terminal.
  Future<void> create() async {
    final flow = requests;
    if (busy || session == null || flow == null) return;
    if (!hasControl || generation == null) {
      error = tr("Take control of the session to open a terminal.");
      emit();
      return;
    }
    final e = epoch;
    busy = true;
    error = '';
    emit();
    try {
      final entry = await flow.openWork();
      if (valid(e) && entry == null) error = terminalUnavailableMessage(flow);
    } finally {
      if (valid(e)) {
        busy = false;
        emit();
      }
    }
  }

  /// The separate, explicit host-management action: ask for a Node review.
  Future<void> reviewHost() async {
    final flow = requests;
    if (busy || session == null || flow == null) return;
    if (!hasControl || generation == null) {
      error = tr("Take control of the session to open a terminal.");
      emit();
      return;
    }
    final e = epoch;
    busy = true;
    error = '';
    emit();
    try {
      final entry = await flow.reviewHost();
      if (valid(e) && entry == null) error = terminalUnavailableMessage(flow);
    } finally {
      if (valid(e)) {
        busy = false;
        emit();
      }
    }
  }

  Future<void> perform(
    TerminalRequestEntry entry,
    TerminalRequestAction action,
  ) async {
    final flow = requests;
    if (flow == null || !flow.entries.contains(entry)) return;
    switch (action) {
      case TerminalRequestAction.refresh:
        await flow.refresh(entry);
      case TerminalRequestAction.resubmit:
        await flow.resubmit(entry);
      case TerminalRequestAction.confirm:
        await flow.confirm(entry);
      case TerminalRequestAction.attach:
        final terminal = entry.result?.terminal;
        if (terminal != null) attach(terminal);
      case TerminalRequestAction.startOver:
        if (busy) return;
        final e = epoch;
        busy = true;
        emit();
        try {
          final next = await flow.startOver(entry);
          if (valid(e) && next == null) {
            error = terminalUnavailableMessage(flow);
          }
        } finally {
          if (valid(e)) {
            busy = false;
            emit();
          }
        }
      case TerminalRequestAction.hostManagement:
        await reviewHost();
      case TerminalRequestAction.dismiss:
        flow.dismiss(entry);
    }
  }

  Future<void> close(Json terminal) async {
    final e = epoch, id = '${terminal['id']}', owner = session;
    if (owner == null || closing.contains(id)) return;
    if (terminal['exited'] != true && (!hasControl || generation == null)) {
      error = tr("Take control of the session to close a terminal.");
      emit();
      return;
    }
    closing.add(id);
    try {
      if (terminal['exited'] != true) {
        await controller.gateway.request(
          '${sessionPath(owner)}/terminals/${enc(id)}/close',
          method: 'POST',
          body: {'clientId': client, 'generation': generation},
        );
      }
    } catch (e2) {
      if (!valid(e)) return;
      final message = terminalError(e2, tr("Unable to close the terminal."));
      if (!RegExp('not found', caseSensitive: false).hasMatch(message)) {
        error = message;
        emit();
        return;
      }
    } finally {
      if (valid(e)) closing.remove(id);
    }
    if (!valid(e)) return;
    listRevision++;
    terminals = terminals.where((t) => t['id'] != id).toList();
    if (current == id) current = terminals.lastOrNull?['id'];
    emit();
  }

  void exited(String id, int? code) {
    terminals = [
      for (final t in terminals)
        t['id'] == id ? {...t, 'exited': true, 'exitCode': code} : t,
    ];
    emit();
  }

  @override
  void dispose() {
    disposed = true;
    epoch++;
    requests?.dispose();
    controller.removeListener(observe);
    super.dispose();
  }
}

/// One PTY connection, retained across terminal/side-panel switches.
class NativeTerminalSession extends ChangeNotifier {
  NativeTerminalSession(this.controller, this.info, {required this.onExit})
    : session = controller.sessionId!,
      origin = controller.origin,
      client = controller.clientId,
      exited = info['exited'] == true {
    terminal = makeTerminal();
    subscription = controller.gateway.events.listen(frame);
    controller.addListener(controlChanged);
    held = controller.control['held'] == true;
    controlGeneration = controller.control['generation'];
    unawaited(connect());
  }
  final LiveController controller;
  final Json info;
  final String session;
  final String? origin, client;
  final void Function(int?) onExit;
  late NativeTerminalInput terminal;
  late final StreamSubscription<Json> subscription;
  static int serial = 0;
  String tag = '';
  String notice = '', sentSize = '';
  bool exited,
      ready = false,
      disposed = false,
      foreground = true,
      visible = false,
      held = false;
  int attempts = 0;
  dynamic controlGeneration;
  Timer? retry, resizeTimer;
  bool get valid =>
      !disposed &&
      session == controller.sessionId &&
      origin == controller.origin &&
      client == controller.clientId;
  NativeTerminalInput makeTerminal() => NativeTerminalInput(
    onModifiersChanged: emit,
    onOutput: input,
    onResize: (_, _, _, _) => scheduleResize(),
  );
  void emit() {
    if (!disposed) notifyListeners();
  }

  Future<void> connect() async {
    if (!valid || exited || !foreground) return;
    retry?.cancel();
    ready = false;
    final old = tag;
    tag = 'native-terminal-${++serial}';
    final ticket = tag;
    if (old.isNotEmpty) unawaited(closeSocket(old));
    try {
      await controller.gateway.call('socketOpen', {
        'tag': ticket,
        'path':
            '${sessionPath(session)}/terminals/${enc('${info['id']}')}/stream',
      });
      if (!valid || ticket != tag || !foreground) await closeSocket(ticket);
    } catch (e) {
      if (valid && ticket == tag) reconnect();
    }
  }

  Future<void> closeSocket(String value) async {
    try {
      await controller.gateway.call('socketClose', {'tag': value});
    } catch (_) {
      /* A disposed bridge already closed its sockets. */
    }
  }

  void reconnect() {
    if (!valid || exited || !foreground) return;
    ready = false;
    notice = tr("Reconnecting…");
    emit();
    retry?.cancel();
    retry = Timer(
      Duration(
        milliseconds: math.min(10000, 500 * (1 << attempts.clamp(0, 5))),
      ),
      connect,
    );
    attempts++;
  }

  void frame(Json event) {
    final data = obj(event['data']);
    if (!valid || !foreground || data['tag'] != tag) return;
    if (event['type'] == 'socketClosed') {
      ready = false;
      if (data['code'] == 4404) {
        exited = true;
        notice = tr("This terminal no longer exists.");
        retry?.cancel();
        onExit(null);
        emit();
      } else {
        reconnect();
      }
      return;
    }
    if (event['type'] != 'socket') return;
    final message = obj(data['frame']);
    switch (message['type']) {
      case 'ready':
        attempts = 0;
        ready = true;
        notice = '';
        retry?.cancel();
        final width = terminal.viewWidth, height = terminal.viewHeight;
        terminal = makeTerminal()
          ..resize(width, height)
          ..write('${message['replay'] ?? ''}');
        sentSize = '';
        scheduleResize();
        emit();
      case 'output':
        terminal.write('${message['data'] ?? ''}');
      case 'exit':
        exited = true;
        retry?.cancel();
        final code = message['exitCode'] as int?;
        terminal.write(
          '\r\n\x1b[2m[process exited${code == null ? '' : ' with code $code'}]\x1b[0m\r\n',
        );
        onExit(code);
        emit();
      case 'error':
        if (message['code'] == 'lost_control') {
          notice = 'Take control of the session to type here.';
          emit();
        }
    }
  }

  void input(String data) {
    if (controller.control['held'] != true) {
      notice = tr("Take control of the session to type here.");
      emit();
      return;
    }
    unawaited(send({'type': 'input', 'data': data}));
  }

  Future<void> send(Json data) async {
    if (!valid ||
        !foreground ||
        !ready ||
        exited ||
        controller.control['held'] != true ||
        controller.control['generation'] == null) {
      return;
    }
    final ticket = tag;
    try {
      await controller.gateway.call('socketSend', {
        'tag': ticket,
        'data': {
          ...data,
          'clientId': client,
          'generation': controller.control['generation'],
        },
      });
    } catch (_) {
      if (valid && ticket == tag) reconnect();
    }
  }

  void scheduleResize() {
    resizeTimer?.cancel();
    resizeTimer = Timer(const Duration(milliseconds: 50), () {
      if (!valid ||
          !visible ||
          !foreground ||
          !ready ||
          exited ||
          controller.control['held'] != true ||
          controller.control['generation'] == null) {
        return;
      }
      final size = '${terminal.viewWidth}x${terminal.viewHeight}';
      if (size == sentSize) return;
      sentSize = size;
      unawaited(
        send({
          'type': 'resize',
          'cols': terminal.viewWidth,
          'rows': terminal.viewHeight,
        }),
      );
    });
  }

  void setVisible(bool value) {
    if (visible == value) return;
    visible = value;
    if (value) scheduleResize();
  }

  void controlChanged() {
    if (!valid) {
      retry?.cancel();
      resizeTimer?.cancel();
      ready = false;
      if (tag.isNotEmpty) unawaited(closeSocket(tag));
      return;
    }
    final value = controller.control['held'] == true;
    final generation = controller.control['generation'];
    if (value == held && generation == controlGeneration) return;
    if (value && (!held || generation != controlGeneration)) {
      if (notice.startsWith('Take control')) notice = '';
      sentSize = '';
      scheduleResize();
    }
    if (!value || generation != controlGeneration) {
      terminal.clearModifiers(notify: false);
    }
    held = value;
    controlGeneration = generation;
    emit();
  }

  void setForeground(bool value) {
    if (foreground == value) return;
    foreground = value;
    if (value) {
      unawaited(connect());
    } else {
      retry?.cancel();
      resizeTimer?.cancel();
      ready = false;
      if (tag.isNotEmpty) unawaited(closeSocket(tag));
    }
  }

  @override
  void dispose() {
    disposed = true;
    retry?.cancel();
    resizeTimer?.cancel();
    subscription.cancel();
    controller.removeListener(controlChanged);
    if (tag.isNotEmpty) unawaited(closeSocket(tag));
    super.dispose();
  }
}
