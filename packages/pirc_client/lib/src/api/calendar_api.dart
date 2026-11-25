import '../api_client.dart';
import '../json.dart';
import '../transport/transport.dart';

/// `/api/calendar*` and `/api/schedules*`: personal events and agent tasks.
/// Replies are JSON maps; the calendar screens read them as they are.
class CalendarApi {
  const CalendarApi(this.api);
  final ApiClient api;

  static String _id(String id) => Uri.encodeComponent(id);

  /// Every item between [from] and [to] (epoch ms, at most 93 days), all
  /// pages. [timezone] is an IANA name or a fixed offset (`+08:00`).
  Future<List<Map<String, Object?>>> items({
    required int from,
    required int to,
    required String timezone,
  }) async {
    final items = <Map<String, Object?>>[];
    String? cursor;
    do {
      final reply = await api.get(
        '/api/calendar',
        query: {
          'from': '$from',
          'to': '$to',
          'timezone': timezone,
          'cursor': ?cursor,
        },
      );
      for (final item in array(field(reply, 'items')) ?? const []) {
        if (object(item) case final item?) items.add(item);
      }
      cursor = str(field(reply, 'nextCursor'));
    } while (cursor != null);
    return items;
  }

  Future<Map<String, Object?>> event(String id) async =>
      object(
        field(await api.get('/api/calendar/events/${_id(id)}'), 'event'),
      ) ??
      const {};

  /// Creates a personal event; [key] makes a retry safe.
  Future<Map<String, Object?>> createEvent(
    String key,
    Map<String, Object?> spec,
  ) async =>
      object(
        field(
          await api.post('/api/calendar/events', {
            'idempotencyKey': key,
            'event': spec,
          }),
          'event',
        ),
      ) ??
      const {};

  /// [scope] is `series`, `occurrence` or `following`; the last two need
  /// [occurrence] (the item's `originalStart`).
  Future<Map<String, Object?>> updateEvent(
    String id, {
    required int revision,
    required Map<String, Object?> spec,
    String scope = 'series',
    String? occurrence,
  }) async =>
      object(
        field(
          await api.patch('/api/calendar/events/${_id(id)}', {
            'revision': revision,
            'event': spec,
            'scope': scope,
            'occurrence': ?occurrence,
          }),
          'event',
        ),
      ) ??
      const {};

  Future<void> deleteEvent(
    String id, {
    required int revision,
    String scope = 'series',
    String? occurrence,
  }) => api.json(
    ApiRequest(
      'DELETE',
      '/api/calendar/events/${_id(id)}',
      json: {'revision': revision, 'scope': scope, 'occurrence': ?occurrence},
    ),
  );

  Future<List<Map<String, Object?>>> schedules() async => [
    for (final s
        in array(field(await api.get('/api/schedules'), 'schedules')) ??
            const [])
      ?object(s),
  ];

  /// `{schedule, runs}`.
  Future<Map<String, Object?>> schedule(String id) async =>
      object(await api.get('/api/schedules/${_id(id)}')) ?? const {};

  Future<Map<String, Object?>> createSchedule(
    Map<String, Object?> body,
  ) async =>
      object(field(await api.post('/api/schedules', body), 'schedule')) ??
      const {};

  /// Edits fields, or pauses and resumes with `status`.
  Future<Map<String, Object?>> updateSchedule(
    String id,
    Map<String, Object?> body,
  ) async =>
      object(
        field(await api.patch('/api/schedules/${_id(id)}', body), 'schedule'),
      ) ??
      const {};

  Future<void> deleteSchedule(String id) =>
      api.delete('/api/schedules/${_id(id)}');

  /// Runs now; with [runId], allows that missed run.
  Future<Map<String, Object?>> run(String id, {String? runId}) async =>
      object(
        field(
          await api.post('/api/schedules/${_id(id)}/run', {'runId': ?runId}),
          'run',
        ),
      ) ??
      const {};

  Future<Map<String, Object?>> dismiss(String id, String runId) async =>
      object(
        field(
          await api.post(
            '/api/schedules/${_id(id)}/runs/${_id(runId)}/dismiss',
          ),
          'run',
        ),
      ) ??
      const {};
}
