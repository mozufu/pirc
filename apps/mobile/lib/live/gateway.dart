import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

typedef Json = Map<String, dynamic>;
Json obj(dynamic value) =>
    value is Map ? value.map((k, v) => MapEntry('$k', v)) : {};
List<Json> rows(dynamic value) => value is List ? value.map(obj).toList() : [];
String enc(String value) => Uri.encodeComponent(value);
String sessionPath(String id) => '/api/sessions/${enc(id)}';

class Gateway {
  static const channel = MethodChannel('dev.pirc.mobile/gateway');
  static const eventChannel = EventChannel('dev.pirc.mobile/events');
  late final Stream<Json> events = eventChannel
      .receiveBroadcastStream()
      .map(obj)
      .asBroadcastStream();
  Future<dynamic> call(String method, [Json args = const {}]) =>
      channel.invokeMethod(method, args);
  Future<Json> request(
    String path, {
    String method = 'GET',
    dynamic body,
  }) async => obj(
    await call('request', {'method': method, 'path': path, 'body': body}),
  );
  Future<Json> command(String id, Json payload) async => obj(
    await call('command', {
      'sessionId': id,
      'payload': payload,
      'commandId': List.generate(
        16,
        (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join(),
    }),
  );
}

class ReadingState {
  ReadingState(String first) : versions = [first];
  final List<String> versions;
  final offsets = <int, double>{};
  int selected = 0;
}

class LiveController extends ChangeNotifier {
  LiveController(this.gateway);
  final Gateway gateway;
  String? origin, clientId, sessionId, error, actionError, pairLink, routePage;
  Json state = {}, control = {}, preferences = {};
  Json? notificationQuestion;
  bool fromNotification = false;
  List<Json> sessions = [],
      workspaces = [],
      nodes = [],
      models = [],
      attachments = [];
  bool onboardingComplete = true;
  bool booting = true,
      busy = false,
      loading = false,
      active = true,
      unknownCommand = false;
  String connection = 'connecting', draft = '', mode = 'work';
  String? workspaceFilter;
  final readers = <String, ReadingState>{};
  final panelState = <String, Json>{};
  int _accountRevision = 0;
  Timer? _poll, _save;
  StreamSubscription<Json>? _events;
  bool _disposed = false;
  int _selection = 0, _draftRevision = 0;
  String get title => '${obj(state['session'])['name'] ?? '新對話'}';
  bool get running => [
    'queued',
    'running',
    'waiting_input',
    'stopping',
  ].contains(obj(state['run'])['status']);
  bool get canWrite =>
      sessionId != null &&
      connection == 'live' &&
      control['held'] == true &&
      !busy;
  bool get chat => workspaces.any(
    (w) =>
        w['id'] == obj(state['session'])['workspaceId'] && w['kind'] == 'chat',
  );
  List<Json> get messages => rows(state['messages']);
  List<Json> get questions =>
      rows(
        state['interactions'],
      ).where((q) => q['status'] == 'pending').toList()..sort(
        (a, b) => ((a['expiresAt'] as num?)?.toInt() ?? 9007199254740991)
            .compareTo((b['expiresAt'] as num?)?.toInt() ?? 9007199254740991),
      );
  void changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> boot() async {
    _events ??= gateway.events.listen(
      _event,
      onError: (Object e) {
        error = describe(e);
        changed();
      },
    );
    try {
      final data = obj(await gateway.call('boot'));
      onboardingComplete = data['onboardingComplete'] != false;
      preferences = obj(await gateway.call('preferences'));
      origin = data['origin'] as String?;
      clientId = data['clientId'] as String?;
      pairLink = data['pairLink'] as String?;
      routePage = data['route'] as String?;
      if (origin != null) {
        await refreshList();
        if (data['targetSession'] != null) {
          await open('${data['targetSession']}');
          fromNotification = true;
          if (data['interactionId'] != null ||
              data['confirmQuestion'] == true) {
            notificationQuestion = data;
          }
        }
      }
    } catch (e) {
      error = describe(e);
    }
    booting = false;
    changed();
    _poll ??= Timer.periodic(const Duration(seconds: 20), (_) {
      if (active && origin != null) unawaited(refreshList());
    });
  }

  Future<void> savePreferences(Json changes) async {
    preferences = obj(await gateway.call('savePreferences', changes));
    changed();
  }

  Future<void> pair(String link) async {
    if (busy) return;
    _accountRevision++;
    _selection++;
    loading = false;
    busy = true;
    error = null;
    changed();
    try {
      final data = obj(await gateway.call('pair', {'link': link}));
      origin = data['origin'];
      clientId = data['clientId'];
      pairLink = null;
      sessionId = null;
      state = {};
      draft = '';
      attachments = [];
      readers.clear();
      panelState.clear();
      unknownCommand = false;
      await refreshList();
    } catch (e) {
      error = describe(e);
    } finally {
      busy = false;
      changed();
    }
  }

  Future<void> unpair() async {
    _accountRevision++;
    _selection++;
    loading = false;
    await flushDraft();
    await gateway.call('unpair');
    readers.clear();
    panelState.clear();
    origin = null;
    sessionId = null;
    state = {};
    sessions = [];
    draft = '';
    attachments = [];
    changed();
  }

  Future<void> refreshList() async {
    if (origin == null || loading) return;
    loading = true;
    final revision = _accountRevision;
    try {
      final result = await Future.wait([
        gateway.request('/api/sessions'),
        gateway.request('/api/workspaces'),
        gateway.request('/api/nodes'),
      ]);
      if (revision != _accountRevision) return;
      sessions = rows(result[0]['sessions']);
      workspaces = rows(result[1]['workspaces']);
      nodes = rows(result[2]['nodes']);
      if (!workspaces.any((w) => w['id'] == workspaceFilter)) {
        workspaceFilter = null;
      }
      error = null;
    } catch (e) {
      if (revision == _accountRevision) error = describe(e);
    } finally {
      if (revision == _accountRevision) loading = false;
      changed();
    }
  }

  Future<void> open(String id) async {
    final selection = ++_selection;
    await flushDraft();
    if (selection != _selection) return;
    sessionId = id;
    state = {};
    control = {};
    models = [];
    attachments = [];
    connection = 'connecting';
    actionError = null;
    draft = '';
    unknownCommand = false;
    changed();
    try {
      final revision = _draftRevision;
      final saved = await gateway.call('watch', {'sessionId': id});
      if (selection != _selection) return;
      if (_draftRevision == revision) draft = saved as String? ?? '';
      final uncertain = await gateway.call('commandStatus', {'sessionId': id});
      if (selection != _selection) return;
      unknownCommand = uncertain == true;
      if (unknownCommand) actionError = '先前送出結果不明，請先檢查最新狀態。';
      changed();
      final data = await gateway.request('/api/models?sessionId=${enc(id)}');
      if (selection == _selection) models = rows(data['models']);
    } catch (e) {
      if (selection == _selection) error = describe(e);
    }
    changed();
  }

  Future<void> home() async {
    final selection = ++_selection;
    await flushDraft();
    if (selection != _selection) return;
    await gateway.call('unwatch');
    if (selection != _selection) return;
    sessionId = null;
    state = {};
    control = {};
    attachments = [];
    draft = '';
    actionError = null;
    error = null;
    unknownCommand = false;
    changed();
  }

  Future<void> create(String workspaceId) async {
    final data = await gateway.request(
      '/api/sessions',
      method: 'POST',
      body: {'workspaceId': workspaceId},
    );
    await refreshList();
    await open('${obj(data['session'])['id']}');
  }

  Future<void> updateSession(Json patch, {String? targetId}) async {
    final id = targetId ?? sessionId;
    if (id == null) return;
    final data = await gateway.request(
      sessionPath(id),
      method: 'PATCH',
      body: patch,
    );
    if (sessionId == id) state = {...state, 'session': data['session']};
    await refreshList();
    changed();
  }

  void _event(Json event) {
    if (event['type'] == 'route') {
      final data = obj(event['data']);
      pairLink = data['pairLink'];
      routePage = data['page'];
      if (data['sessionId'] != null && origin != null) {
        unawaited(
          open('${data['sessionId']}').then((_) {
            fromNotification = true;
            if (data['interactionId'] != null ||
                data['confirmQuestion'] == true) {
              notificationQuestion = data;
            }
            changed();
          }),
        );
      }
      changed();
      return;
    }
    if (event['sessionId'] != sessionId) return;
    switch (event['type']) {
      case 'snapshot':
        state = obj(event['data']);
        error = null;
      case 'connection':
        connection = '${event['data']}';
      case 'control':
        control = obj(event['data']);
      case 'error':
        error = '${event['data']}';
      default:
        return;
    }
    changed();
  }

  void editDraft(String value) {
    _draftRevision++;
    draft = value;
    _save?.cancel();
    _save = Timer(const Duration(milliseconds: 250), flushDraft);
  }

  Future<void> flushDraft() async {
    _save?.cancel();
    final id = sessionId;
    if (id != null) {
      await gateway.call('draft', {'sessionId': id, 'text': draft});
    }
  }

  Future<void> lifecycle(bool visible) async {
    active = visible;
    if (origin == null) return;
    if (!visible) {
      await flushDraft();
      await gateway.call('unwatch');
    } else {
      await refreshList();
      if (sessionId != null) {
        await gateway.call('watch', {'sessionId': sessionId});
      }
    }
  }

  Future<void> takeControl({bool force = false}) async {
    final id = sessionId;
    if (id == null) return;
    final next = obj(
      await gateway.call('control', {
        'sessionId': id,
        'acquire': true,
        'force': force,
      }),
    );
    if (sessionId == id) control = next;
    changed();
  }

  Future<void> refreshSession() async {
    final id = sessionId;
    if (id == null) return;
    final next = obj(await gateway.call('refresh', {'sessionId': id}));
    if (sessionId == id) {
      state = next;
      changed();
    }
  }

  Future<bool> sendCommand(Json payload) async {
    if (!canWrite) return false;
    final id = sessionId!;
    if (unknownCommand && payload['type'] != 'stop') return false;
    busy = true;
    actionError = null;
    changed();
    try {
      final receipt = await gateway.command(id, payload);
      if (sessionId != id) return receipt['status'] == 'accepted';
      if (receipt['status'] != 'accepted') {
        unknownCommand = receipt['status'] == 'outcome_unknown';
        actionError = '${receipt['message'] ?? receipt['status']}';
        return false;
      }
      return true;
    } catch (e) {
      if (sessionId != id) return false;
      unknownCommand =
          e is! PlatformException ||
          !e.code.startsWith('HTTP_4') ||
          obj(e.details)['code'] == 'outcome_unknown';
      actionError = unknownCommand ? '送出結果不明，請檢查對話；不會自動重送。' : describe(e);
      return false;
    } finally {
      busy = false;
      changed();
    }
  }

  Future<void> acknowledgeCommand() async {
    final id = sessionId;
    if (id == null) return;
    await gateway.call('acknowledgeCommand', {'sessionId': id});
    if (id == sessionId) {
      unknownCommand = false;
      actionError = null;
      changed();
    }
  }

  Future<void> send(String kind) async {
    if (draft.trim().isEmpty || unknownCommand) return;
    final text = draft;
    final sentAttachments = List<Json>.of(attachments);
    final id = sessionId;
    if (await sendCommand({
      'type': kind,
      'message': text.trim(),
      'uploadIds': sentAttachments.map((a) => a['id']).toList(),
    })) {
      if (sessionId == id && draft == text) {
        draft = '';
        attachments.removeWhere((a) => sentAttachments.contains(a));
        await flushDraft();
        changed();
      }
    }
  }

  Future<void> attach() async {
    final id = sessionId;
    if (id == null) return;
    final data = await gateway.call('pickUpload', {'sessionId': id});
    if (data != null && sessionId == id) {
      attachments.add(obj(data));
      changed();
    }
  }

  static String describe(Object e) {
    if (e is StateError) return e.message;
    if (e is PlatformException) {
      switch (e.code) {
        case 'SCAN_DOWNLOADING':
          return '掃描元件正在下載，請稍後再試，也可以貼上配對連結。';
        case 'SCAN_UNSUPPORTED':
          return '掃描器需要更新 Google Play 服務。也可以貼上配對連結。';
        case 'SCAN_BUSY':
          return '掃描器已開啟，請完成或關閉目前的掃描。';
        case 'SCAN':
          return '暫時無法開啟掃描器，請重試或貼上配對連結。';
        case 'HTTP_401':
          return '此裝置的配對已失效，請重新配對。';
        case 'HTTP_403':
          return '目前沒有執行這項操作的權限。';
        case 'HTTP_404':
          return '找不到這個項目，請重新載入。';
        case 'HTTP_409':
          return '狀態已改變，請重新載入後再操作。';
        case 'NETWORK':
          return '連線或裝置操作失敗，請確認連線後重試。';
      }
      final message = e.message;
      if (message != null &&
          !message.contains('java.') &&
          !message.contains('Exception') &&
          !message.contains('null object')) {
        return message;
      }
      return '操作未完成，請重試。';
    }
    return '操作未完成，請重新載入後再試。';
  }

  @override
  void dispose() {
    _disposed = true;
    _events?.cancel();
    _poll?.cancel();
    _save?.cancel();
    super.dispose();
  }
}
