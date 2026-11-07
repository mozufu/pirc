// @vitest-environment jsdom
// @vitest-environment-options {"url":"http://localhost"}
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { api, ApiError, normalizeEvent } from './api';
import { app } from './app.svelte';
import { demoSnapshot } from './mock';
import { fromSnapshot, reduceEvent } from './state';
import { loadDraft, saveDraft } from './storage';
import type { SessionSnapshot, SessionSummary, Workspace } from './types';

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((done) => (resolve = done));
  return { promise, resolve };
}

function snapshotFor(
  session: SessionSummary,
  interactions = [] as SessionSnapshot['interactions'],
) {
  return {
    ...demoSnapshot,
    session,
    messages: [],
    interactions,
  } satisfies SessionSnapshot;
}

class TestWebSocket extends EventTarget {
  static CONNECTING = 0;
  static OPEN = 1;
  readyState = TestWebSocket.CONNECTING;

  constructor(_url: string) {
    super();
  }

  close() {
    this.readyState = 3;
  }
}

const workspace: Workspace = {
  id: 'w1',
  hostId: 'host',
  displayName: 'Workspace',
  kind: 'directory',
  defaults: {},
};

const memoryProposal = normalizeEvent({
  sessionId: 's1',
  epoch: 'demo-epoch',
  sequence: 2,
  type: 'interaction_created',
  data: {
    id: 'memory:p1:0',
    runnerEpoch: 0,
    kind: 'confirm',
    status: 'pending',
    request: {
      title: 'Add USER memory?',
      message: 'Proposed memory:\nLikes tea.',
      confirmLabel: 'Approve',
      cancelLabel: 'Reject',
    },
  },
});
if (memoryProposal.event.type !== 'interaction_updated')
  throw new Error('Expected a memory proposal interaction.');
const proposalInteraction = memoryProposal.event.interaction;

it('keeps a newer interaction when a legacy removal has no row epoch', () => {
  const session = { ...demoSnapshot.session, id: 's-legacy-event' };
  const newer = { ...proposalInteraction, id: 'interaction:reused', runnerEpoch: '5' };
  const state = fromSnapshot(snapshotFor(session, [newer]));
  const legacyRemoval = normalizeEvent({
    sessionId: session.id,
    epoch: state.runnerEpoch,
    sequence: 1,
    type: 'interaction_answered',
    data: { interactionId: newer.id },
  });

  const updated = reduceEvent(state, legacyRemoval);

  expect(updated.interactions).toEqual([newer]);
  expect(updated.needsSnapshot).toBe(true);
});

beforeEach(() => {
  // These cases exercise the explicitly negotiated legacy conversation flow.
  // Unknown capability discovery is covered by the first-send App tests.
  app.firstCapabilities = { version: 0, canSubmit: false };
  const values = new Map<string, string>();
  vi.stubGlobal('localStorage', {
    get length() {
      return values.size;
    },
    key: (index: number) => [...values.keys()][index] ?? null,
    getItem: (key: string) => values.get(key) ?? null,
    setItem: (key: string, value: string) => values.set(key, value),
    removeItem: (key: string) => values.delete(key),
    clear: () => values.clear(),
  } satisfies Storage);
});

afterEach(() => {
  app.discardDraftSession();
  app.dispose();
  app.demo = undefined;
  app.view = 'session';
  app.scheduleFocus = undefined;
  app.calendarFocus = undefined;
  app.calendarNavigationRevision = 0;
  app.activeSessionId = undefined;
  app.sessionState = undefined;
  app.sessions = [];
  app.workspaces = [];
  app.draft = '';
  app.uploads = [];
  app.pageError = '';
  app.interactionNotice = '';
  app.answeringInteractionIds = [];
  globalThis.localStorage?.clear();
  history.replaceState(history.state, '', '/');
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
});

it('clears notification focus when opening Calendar and preserves explicit schedule links', () => {
  history.replaceState(
    history.state,
    '',
    '/?open=calendar&view=list&date=2026-10-21&manage=schedules&schedule=old&item=event%3Ae1%3A2026-10-21T09%3A00',
  );
  app.scheduleFocus = 'stale-schedule';
  app.calendarFocus = { eventId: 'stale-event', occurrenceStart: '2026-10-21T11:00' };

  app.showCalendar();

  expect(app.view).toBe('schedules');
  expect(app.scheduleFocus).toBeUndefined();
  expect(app.calendarFocus).toBeUndefined();
  expect(app.calendarNavigationRevision).toBe(1);
  const calendarUrl = new URL(location.href);
  expect(calendarUrl.searchParams.get('open')).toBe('calendar');
  expect(calendarUrl.searchParams.get('view')).toBe('list');
  expect(calendarUrl.searchParams.get('date')).toBe('2026-10-21');
  expect(calendarUrl.searchParams.has('manage')).toBe(false);
  expect(calendarUrl.searchParams.has('schedule')).toBe(false);
  expect(calendarUrl.searchParams.has('item')).toBe(false);

  app.showSchedules('requested-schedule');
  expect(app.scheduleFocus).toBe('requested-schedule');
  expect(app.calendarFocus).toBeUndefined();
});

describe('message branch commands', () => {
  function setup() {
    app.connection = 'connected';
    app.demo = undefined;
    app.commandBusy = false;
    app.activeSessionId = demoSnapshot.session.id;
    app.sessionState = fromSnapshot({
      ...demoSnapshot,
      run: null,
      partialMessage: undefined,
      runnerStatus: 'ready',
      control: { ...demoSnapshot.control, heldByCurrentClient: true, generation: 1 },
      messages: [
        {
          id: 'user-1',
          entryId: 'entry-1',
          role: 'user',
          content: 'Original',
          createdAt: new Date(1).toISOString(),
          branches: [
            { entryId: 'entry-1', text: 'Original', selected: true },
            { entryId: 'entry-2', text: 'Edited', selected: false },
          ],
        },
      ],
    });
    const command = vi
      .spyOn(api, 'command')
      .mockResolvedValue({ commandId: 'branch', status: 'accepted' });
    const refresh = vi
      .spyOn(api, 'snapshot')
      .mockResolvedValue({ ...demoSnapshot, run: null, messages: app.sessionState!.messages });
    return { command, refresh };
  }
  it('refreshes stable branch metadata after accepted editing and switching', async () => {
    const { command, refresh } = setup();
    expect(await app.changeBranch('edit_message', 'entry-1', 'Revised')).toBe(true);
    expect(command).toHaveBeenLastCalledWith(
      app.activeSessionId,
      expect.objectContaining({ kind: 'edit_message', entryId: 'entry-1', content: 'Revised' }),
    );
    expect(await app.changeBranch('switch_branch', 'entry-2')).toBe(true);
    expect(refresh).toHaveBeenCalledTimes(2);
  });
  it('reports rejected edits without discarding the composer draft or refreshing', async () => {
    const { command, refresh } = setup();
    app.draft = 'Unrelated unsent draft';
    command.mockResolvedValue({ commandId: 'branch', status: 'rejected', message: 'Busy' });
    expect(await app.changeBranch('edit_message', 'entry-1', 'Revised')).toBe(false);
    expect(app.draft).toBe('Unrelated unsent draft');
    expect(app.pageError).toContain('Busy');
    expect(refresh).not.toHaveBeenCalled();
  });
  it('keeps mutation controls gated until a post-edit snapshot arrives, including failed refreshes', async () => {
    const { refresh } = setup();
    const pending = deferred<SessionSnapshot>();
    refresh.mockReturnValueOnce(pending.promise);
    app.hiddenMessages = 120;
    const edit = app.changeBranch('edit_message', 'entry-1', 'Revised');
    await Promise.resolve();
    expect(app.canChangeBranch).toBe(false);
    pending.resolve({ ...demoSnapshot, run: null, messages: [] });
    expect(await edit).toBe(true);
    expect(app.hiddenMessages).toBe(0);
    expect(app.commandBusy).toBe(false);
  });
  it('does not offer to resubmit accepted edits when snapshot refresh fails', async () => {
    const { refresh } = setup();
    refresh.mockRejectedValueOnce(new Error('Refresh unavailable'));
    expect(await app.changeBranch('edit_message', 'entry-1', 'Revised')).toBe(true);
    expect(app.commandBusy).toBe(false);
    expect(app.canChangeBranch).toBe(false);
    expect(app.pageError).toContain('Refresh unavailable');
    expect(await app.changeBranch('edit_message', 'entry-1', 'Duplicate')).toBe(false);
    await app.refreshSnapshot();
    expect(app.canChangeBranch).toBe(true);
  });
  it('waits for its own authoritative fetch even if a lifecycle snapshot is pending', async () => {
    const { refresh } = setup();
    const before = deferred<SessionSnapshot>();
    const after = deferred<SessionSnapshot>();
    refresh.mockReturnValueOnce(before.promise).mockReturnValueOnce(after.promise);
    const lifecycle = app.refreshSnapshot();
    const edit = app.changeBranch('edit_message', 'entry-1', 'Revised');
    await Promise.resolve();
    before.resolve({ ...demoSnapshot, run: null, messages: [] });
    await lifecycle;
    expect(app.canChangeBranch).toBe(false);
    expect(app.sessionState!.messages).toHaveLength(1);
    after.resolve({ ...demoSnapshot, run: null, messages: [] });
    expect(await edit).toBe(true);
    expect(app.sessionState!.messages).toEqual([]);
  });
  it('guards control, busy runs, unknown entries, and duplicate commands', async () => {
    const { command } = setup();
    expect(await app.changeBranch('edit_message', 'missing', 'Revised')).toBe(false);
    app.sessionState = { ...app.sessionState!, run: { id: 'run', status: 'running' } };
    expect(await app.changeBranch('switch_branch', 'entry-2')).toBe(false);
    app.sessionState = {
      ...app.sessionState!,
      run: null,
      control: { ...app.sessionState!.control, heldByCurrentClient: false },
    };
    expect(await app.changeBranch('edit_message', 'entry-1', 'Revised')).toBe(false);
    app.sessionState = {
      ...app.sessionState!,
      control: { ...app.sessionState!.control, heldByCurrentClient: true },
    };
    app.commandBusy = true;
    expect(await app.changeBranch('switch_branch', 'entry-2')).toBe(false);
    app.commandBusy = false;
    expect(command).not.toHaveBeenCalled();
  });
});

describe('app asynchronous refreshes', () => {
  it('keeps new sessions local and discards an unsent replacement or departure', async () => {
    app.demo = undefined;
    app.workspaces = [workspace];
    app.sessions = [];
    vi.spyOn(api, 'models').mockResolvedValue([]);
    const create = vi.spyOn(api, 'createSession');
    await app.createSession(workspace.id);
    const first = app.activeSessionId!;
    app.setDraft('unsent text');
    app.flushDraft();
    expect(app.view).toBe('session');
    expect(loadDraft(first)).toBe('');
    await app.createSession(workspace.id);
    expect(app.activeSessionId).not.toBe(first);
    expect(app.draft).toBe('');
    app.showWorkspace(workspace.id);
    expect(app.isDraftSession).toBe(false);
    expect(app.activeSessionId).toBeUndefined();
    expect(app.sessions).toEqual([]);
    expect(create).not.toHaveBeenCalled();
  });

  it('awaits an existing control renewal before continuing a first send', async () => {
    app.demo = undefined;
    app.draftWorkspaceId = undefined;
    app.activeSessionId = demoSnapshot.session.id;
    app.sessionState = fromSnapshot({
      ...demoSnapshot,
      control: { heldByCurrentClient: true, generation: 1 },
    });
    const lease = deferred<SessionSnapshot['control']>();
    const heartbeat = vi.spyOn(api, 'heartbeatControl').mockReturnValue(lease.promise);
    const first = app.refreshControl();
    let finished = false;
    const joined = app.refreshControl().then(() => {
      finished = true;
    });
    await Promise.resolve();
    expect(finished).toBe(false);
    expect(heartbeat).toHaveBeenCalledTimes(1);
    lease.resolve({ heldByCurrentClient: true, generation: 2 });
    await Promise.all([first, joined]);
    expect(app.sessionState?.control.generation).toBe(2);
  });

  it('ignores a session list fetched before creating and opening a session', async () => {
    app.demo = undefined;
    vi.stubGlobal('WebSocket', TestWebSocket);
    const existing = { ...demoSnapshot.session, id: 's-old', workspaceId: workspace.id };
    const created = { ...existing, id: 's-new', name: 'New session' };
    const list = deferred<SessionSummary[]>();
    vi.spyOn(api, 'sessions').mockReturnValueOnce(list.promise);
    vi.spyOn(api, 'createSession').mockResolvedValue(created);
    vi.spyOn(api, 'snapshot').mockResolvedValue(snapshotFor(created));
    vi.spyOn(api, 'models').mockResolvedValue([]);
    vi.spyOn(api, 'heartbeatControl').mockResolvedValue(snapshotFor(created).control);

    app.workspaces = [workspace];
    app.sessions = [existing];
    app.activeSessionId = existing.id;
    app.sessionState = fromSnapshot(snapshotFor(existing));
    const staleRefresh = app.refreshSessions();

    expect(await app.createSession(workspace.id)).toBe(true);
    expect(api.createSession).not.toHaveBeenCalled();
    expect(app.sessions.some((s) => s.id === app.activeSessionId)).toBe(false);
    app.setDraft('first message');
    vi.spyOn(api, 'command').mockResolvedValue({ status: 'accepted' } as never);
    await app.sendCommand('prompt');
    saveDraft(created.id, 'keep this draft');
    list.resolve([existing]);
    await staleRefresh;

    expect(app.activeSessionId).toBe(created.id);
    expect(app.sessionState?.session.id).toBe(created.id);
    expect(app.sessions.some((session) => session.id === created.id)).toBe(true);
    expect(loadDraft(created.id)).toBe('keep this draft');
  });

  it('removes a session and its draft when a fresh list confirms it is gone', async () => {
    app.demo = undefined;
    const gone = { ...demoSnapshot.session, id: 's-gone', workspaceId: workspace.id };
    app.sessions = [gone];
    app.workspaces = [workspace];
    app.activeSessionId = gone.id;
    app.sessionState = fromSnapshot(snapshotFor(gone));
    saveDraft(gone.id, 'draft for deleted session');
    vi.spyOn(api, 'sessions').mockResolvedValue([]);

    await app.refreshSessions();

    expect(app.sessions).toEqual([]);
    expect(app.activeSessionId).toBeUndefined();
    expect(loadDraft(gone.id)).toBe('');
  });

  it('ignores an older session list when a newer refresh finishes first', async () => {
    app.demo = undefined;
    const older = { ...demoSnapshot.session, id: 's-older' };
    const newer = { ...demoSnapshot.session, id: 's-newer' };
    const first = deferred<SessionSummary[]>();
    const second = deferred<SessionSummary[]>();
    vi.spyOn(api, 'sessions')
      .mockReturnValueOnce(first.promise)
      .mockReturnValueOnce(second.promise);

    const firstRefresh = app.refreshSessions();
    const secondRefresh = app.refreshSessions();
    second.resolve([newer]);
    await secondRefresh;
    first.resolve([older]);
    await firstRefresh;

    expect(app.sessions.map((session) => session.id)).toEqual(['s-newer']);
  });

  it.each([
    {
      name: 'an approval while an older snapshot is loading',
      initial: [proposalInteraction],
      incoming: normalizeEvent({
        sessionId: 's1',
        epoch: 'demo-epoch',
        sequence: 3,
        type: 'interaction_answered',
        data: {
          interactionId: 'memory:p1:0',
          interactionEpoch: proposalInteraction.runnerEpoch,
        },
      }),
      stale: [proposalInteraction],
      fresh: [],
      expected: [],
    },
    {
      name: 'a new proposal while an older snapshot is loading',
      initial: [],
      incoming: memoryProposal,
      stale: [],
      fresh: [proposalInteraction],
      expected: ['memory:p1:0'],
    },
  ])('$name', async ({ initial, incoming, stale, fresh, expected }) => {
    app.demo = undefined;
    const session = { ...demoSnapshot.session, id: 's1' };
    app.activeSessionId = session.id;
    app.sessions = [session];
    app.sessionState = fromSnapshot(snapshotFor(session, initial));

    const first = deferred<SessionSnapshot>();
    const correction = deferred<SessionSnapshot>();
    const snapshot = vi
      .spyOn(api, 'snapshot')
      .mockReturnValueOnce(first.promise)
      .mockReturnValueOnce(correction.promise);
    const loading = app.refreshSnapshot();
    expect(snapshot).toHaveBeenCalledTimes(1);

    app.sessionState = reduceEvent(app.sessionState!, incoming);
    if (app.sessionState.needsSnapshot) void app.refreshSnapshot();
    expect(app.sessionState.interactions.map((item) => item.id)).toEqual(
      incoming.event.type === 'interaction_removed' ? [] : ['memory:p1:0'],
    );

    first.resolve(snapshotFor(session, stale));
    await loading;
    expect(snapshot).toHaveBeenCalledTimes(2);
    correction.resolve(snapshotFor(session, fresh));
    await Promise.resolve();
    await Promise.resolve();

    expect(app.sessionState?.interactions.map((item) => item.id)).toEqual(expected);
  });

  it('lets a new session reconcile after an older session snapshot is pending', async () => {
    vi.stubGlobal('WebSocket', TestWebSocket);
    app.demo = undefined;
    const oldSession = { ...demoSnapshot.session, id: 's-old' };
    const newSession = { ...demoSnapshot.session, id: 's-new' };
    app.activeSessionId = oldSession.id;
    app.sessions = [oldSession, newSession];
    app.sessionState = fromSnapshot(snapshotFor(oldSession));

    const oldSnapshot = deferred<SessionSnapshot>();
    const newRefresh = deferred<SessionSnapshot>();
    const snapshot = vi
      .spyOn(api, 'snapshot')
      .mockReturnValueOnce(oldSnapshot.promise)
      .mockResolvedValueOnce(snapshotFor(newSession))
      .mockReturnValueOnce(newRefresh.promise);
    vi.spyOn(api, 'models').mockResolvedValue([]);
    vi.spyOn(api, 'heartbeatControl').mockResolvedValue(snapshotFor(newSession).control);

    const oldRefresh = app.refreshSnapshot();
    await app.openSession(newSession.id);
    const reset = normalizeEvent({
      sessionId: newSession.id,
      epoch: 'demo-epoch',
      sequence: 4,
      type: 'reset',
      reason: 'cursor_expired',
    });
    app.sessionState = reduceEvent(app.sessionState!, reset);
    if (app.sessionState.needsSnapshot) void app.refreshSnapshot();
    expect(snapshot).toHaveBeenCalledTimes(3);

    oldSnapshot.resolve(snapshotFor(oldSession));
    await oldRefresh;
    newRefresh.resolve(snapshotFor(newSession, [proposalInteraction]));
    await Promise.resolve();
    await Promise.resolve();

    expect(app.activeSessionId).toBe(newSession.id);
    expect(app.sessionState?.session.id).toBe(newSession.id);
    expect(app.sessionState?.interactions.map((item) => item.id)).toEqual(['memory:p1:0']);
  });

  it('confirms a stale answer as handled only after the exact question disappears from a fresh snapshot', async () => {
    app.demo = undefined;
    const session = { ...demoSnapshot.session, id: 's-answer' };
    const interaction = { ...proposalInteraction, id: 'interaction:q1', runnerEpoch: '4' };
    app.activeSessionId = session.id;
    app.sessionState = {
      ...fromSnapshot(snapshotFor(session, [interaction])),
      control: { heldByCurrentClient: true, generation: 7 },
    };
    const answer = vi
      .spyOn(api, 'answerInteraction')
      .mockRejectedValueOnce(new ApiError('Already answered', 409, 'stale_interaction'));
    vi.spyOn(api, 'snapshot').mockResolvedValue(snapshotFor(session, []));

    await app.answerInteraction(interaction.id, { action: 'answer', value: true });

    expect(answer).toHaveBeenCalledTimes(1);
    expect(app.interactionNotice).toBe('This request has already been handled.');
    expect(app.sessionState?.interactions).toEqual([]);
  });

  it('keeps a conflicting answer available when the exact question is still pending', async () => {
    app.demo = undefined;
    const session = { ...demoSnapshot.session, id: 's-answer' };
    const interaction = { ...proposalInteraction, id: 'interaction:q1', runnerEpoch: '4' };
    app.activeSessionId = session.id;
    app.sessionState = {
      ...fromSnapshot(snapshotFor(session, [interaction])),
      control: { heldByCurrentClient: true, generation: 7 },
    };
    const answer = vi
      .spyOn(api, 'answerInteraction')
      .mockRejectedValueOnce(new ApiError('Control changed', 409, 'lost_control'));
    vi.spyOn(api, 'snapshot').mockResolvedValue(snapshotFor(session, [interaction]));
    vi.spyOn(api, 'heartbeatControl').mockResolvedValue({ heldByCurrentClient: false });

    await app.answerInteraction(interaction.id, { action: 'answer', value: true });

    expect(answer).toHaveBeenCalledTimes(1);
    expect(app.interactionNotice).toBe('This request is still waiting. Take control to answer it.');
    expect(app.sessionState?.interactions).toEqual([interaction]);
  });

  it('does not claim an answer was handled when the authoritative check fails', async () => {
    app.demo = undefined;
    const session = { ...demoSnapshot.session, id: 's-answer' };
    const interaction = { ...proposalInteraction, id: 'interaction:q1', runnerEpoch: '4' };
    app.activeSessionId = session.id;
    app.sessionState = {
      ...fromSnapshot(snapshotFor(session, [interaction])),
      control: { heldByCurrentClient: true, generation: 7 },
    };
    const answer = vi
      .spyOn(api, 'answerInteraction')
      .mockRejectedValueOnce(new ApiError('Stale', 409, 'stale_interaction'));
    vi.spyOn(api, 'snapshot').mockRejectedValueOnce(new Error('offline'));

    await app.answerInteraction(interaction.id, { action: 'answer', value: true });

    expect(answer).toHaveBeenCalledTimes(1);
    expect(app.interactionNotice).toContain('couldn’t verify');
    expect(app.sessionState?.interactions).toEqual([interaction]);
  });

  it('recognizes a stale card callback after remote removal without touching a reused id', async () => {
    app.demo = undefined;
    const session = { ...demoSnapshot.session, id: 's-answer' };
    const oldQuestion = { ...proposalInteraction, id: 'interaction:q1', runnerEpoch: '4' };
    const newQuestion = { ...proposalInteraction, id: oldQuestion.id, runnerEpoch: '5' };
    app.activeSessionId = session.id;
    app.sessionState = fromSnapshot(snapshotFor(session, [oldQuestion]));
    const oldState = app.sessionState;
    app.sessionState = reduceEvent(
      oldState,
      normalizeEvent({
        sessionId: session.id,
        epoch: oldState.runnerEpoch,
        sequence: 1,
        type: 'interaction_answered',
        data: { interactionId: oldQuestion.id, interactionEpoch: oldQuestion.runnerEpoch },
      }),
    );
    app.sessionState = reduceEvent(app.sessionState, {
      sessionId: session.id,
      runnerEpoch: oldState.runnerEpoch,
      sequence: 2,
      cursor: 'new-question',
      event: { type: 'interaction_updated', interaction: newQuestion },
    });
    const answer = vi.spyOn(api, 'answerInteraction');
    vi.spyOn(api, 'snapshot').mockResolvedValue(snapshotFor(session, [newQuestion]));

    await app.answerInteraction(
      oldQuestion.id,
      { action: 'answer', value: true },
      oldQuestion.runnerEpoch,
    );

    expect(answer).not.toHaveBeenCalled();
    expect(app.interactionNotice).toBe('This request has already been handled.');
    expect(app.sessionState?.interactions).toEqual([newQuestion]);
  });

  it('reports a duplicate callback as processing instead of submitting twice', async () => {
    app.demo = undefined;
    const session = { ...demoSnapshot.session, id: 's-answer' };
    const interaction = { ...proposalInteraction, id: 'interaction:q1', runnerEpoch: '4' };
    app.activeSessionId = session.id;
    app.sessionState = {
      ...fromSnapshot(snapshotFor(session, [interaction])),
      control: { heldByCurrentClient: true, generation: 7 },
    };
    const pending = deferred<void>();
    const answer = vi.spyOn(api, 'answerInteraction').mockReturnValueOnce(pending.promise);

    const first = app.answerInteraction(
      interaction.id,
      { action: 'answer', value: true },
      interaction.runnerEpoch,
    );
    await Promise.resolve();
    await app.answerInteraction(
      interaction.id,
      { action: 'answer', value: true },
      interaction.runnerEpoch,
    );

    expect(answer).toHaveBeenCalledTimes(1);
    expect(app.interactionNotice).toBe('This request is already being processed.');
    pending.resolve();
    await first;
  });

  it('answers a relayed confirm without holding the control lease', async () => {
    app.demo = undefined;
    const session = { ...demoSnapshot.session, id: 's-chat' };
    const relayed = { ...proposalInteraction, id: 'relay.d1.interaction_1', runnerEpoch: '0' };
    const local = { ...proposalInteraction, id: 'interaction:q1', runnerEpoch: '0' };
    app.activeSessionId = session.id;
    app.sessionState = {
      ...fromSnapshot(snapshotFor(session, [relayed, local])),
      control: { heldByCurrentClient: false, holderClientId: 'other', generation: 3 },
    };
    const answer = vi.spyOn(api, 'answerInteraction').mockResolvedValue();
    const takeControl = vi.spyOn(api, 'takeControl');

    await app.answerInteraction(relayed.id, { action: 'answer', value: false }, '0');

    expect(answer).toHaveBeenCalledWith(
      session.id,
      relayed.id,
      { action: 'answer', value: false },
      undefined,
    );
    expect(takeControl).not.toHaveBeenCalled();
    expect(app.sessionState?.interactions).toEqual([local]);
  });

  it('applies delegations_changed to the open chat', () => {
    const session = { ...demoSnapshot.session, id: 's-chat' };
    const state = fromSnapshot(snapshotFor(session));
    const delegation = {
      id: 'd1',
      title: 'Fix the tests',
      workspace: 'repo on node',
      status: 'running',
      dispatch: 'approved',
      targetSessionId: 'worker',
    };
    const updated = reduceEvent(
      state,
      normalizeEvent({
        sessionId: session.id,
        epoch: state.runnerEpoch,
        sequence: 1,
        type: 'delegations_changed',
        data: { delegations: [delegation] },
      }),
    );
    expect(updated.delegations).toEqual([delegation]);
    expect(updated.needsSnapshot).toBe(false);
  });

  it('answers a delegated approval from "Needs you" in the chat that holds it', async () => {
    app.demo = undefined;
    const approval = {
      sessionId: 's-chat',
      interactionId: 'relay.d1.interaction_1',
      title: 'Allow network access?',
    };
    const answer = vi.spyOn(api, 'answerRelayed').mockResolvedValue();
    vi.spyOn(api, 'sessions').mockResolvedValue([]);
    await app.answerApproval(approval, true);
    expect(answer).toHaveBeenCalledWith('s-chat', 'relay.d1.interaction_1', true);
    expect(app.pageError).toBe('');

    answer.mockRejectedValueOnce(new ApiError('Already answered', 409, 'conflict'));
    await app.answerApproval(approval, false);
    expect(app.pageError).toBe('Already answered');
    expect(app.answeringInteractionIds).toEqual([]);
  });

  it('reports why a delegation could not be stopped', async () => {
    app.demo = undefined;
    const stop = vi.spyOn(api, 'stopDelegation').mockResolvedValueOnce({ status: 'stopping' });
    await expect(app.stopDelegation('d1')).resolves.toBeUndefined();
    stop.mockRejectedValueOnce(new ApiError('Another device controls it', 409, 'conflict'));
    await expect(app.stopDelegation('d1')).resolves.toBe('Another device controls it');
  });
});

describe('workspace removal', () => {
  function setup() {
    app.demo = undefined;
    app.workspaces = [workspace, { ...workspace, id: 'other' }];
    app.sessions = [
      { ...demoSnapshot.session, id: 'one', workspaceId: workspace.id },
      { ...demoSnapshot.session, id: 'two', workspaceId: 'other' },
    ];
    vi.spyOn(app, 'refreshNodes').mockResolvedValue();
    vi.spyOn(app, 'refreshSchedules').mockResolvedValue();
  }
  it('updates lists and navigation only after success, without deleting sessions or memories', async () => {
    setup();
    app.showWorkspace(workspace.id);
    const remove = vi.spyOn(api, 'removeWorkspace').mockResolvedValue();
    const deleteSession = vi.spyOn(api, 'deleteSession');
    const memoryRevision = app.memoryRevision;
    const scheduleRevision = app.scheduleRevision;
    await app.removeWorkspace(workspace.id);
    expect(remove).toHaveBeenCalledWith(workspace.id);
    expect(app.workspaces.map((w) => w.id)).toEqual(['other']);
    expect(app.sessions.map((s) => s.id)).toEqual(['two']);
    expect(app.view).toBe('session');
    expect(app.workspaceViewId).toBeUndefined();
    expect(location.search).not.toContain('workspace=');
    expect(deleteSession).not.toHaveBeenCalled();
    expect(app.memoryRevision).toBe(memoryRevision);
    expect(app.scheduleRevision).toBe(scheduleRevision + 1);
  });
  it('leaves the workspace and session state intact on a rejected request', async () => {
    setup();
    app.showWorkspace(workspace.id);
    vi.spyOn(api, 'removeWorkspace').mockRejectedValue(new Error('Stop running sessions'));
    await expect(app.removeWorkspace(workspace.id)).rejects.toThrow('Stop running sessions');
    expect(app.workspaces).toHaveLength(2);
    expect(app.sessions).toHaveLength(2);
    expect(app.workspaceViewId).toBe(workspace.id);
    expect(app.view).toBe('workspace');
  });
  it('clears an unsent conversation targeted at the removed workspace', async () => {
    setup();
    vi.spyOn(api, 'removeWorkspace').mockResolvedValue();
    await app.createSession(workspace.id);
    expect(app.draftWorkspaceId).toBe(workspace.id);
    await app.removeWorkspace(workspace.id);
    expect(app.draftWorkspaceId).toBeUndefined();
    expect(app.isDraftSession).toBe(false);
  });
});

it('closes a workspace removed in another client when directory lists refresh', async () => {
  app.demo = undefined;
  app.workspaces = [workspace];
  app.sessions = [{ ...demoSnapshot.session, id: 'removed-session', workspaceId: workspace.id }];
  app.showWorkspace(workspace.id);
  vi.spyOn(api, 'nodes').mockResolvedValue([]);
  vi.spyOn(api, 'workspaces').mockResolvedValue([]);
  vi.spyOn(api, 'modes').mockResolvedValue([]);
  await app.refreshNodes();
  expect(app.workspaces).toEqual([]);
  expect(app.sessions).toEqual([]);
  expect(app.workspaceViewId).toBeUndefined();
  expect(app.view).toBe('session');
  expect(location.search).not.toContain('workspace=');
});

it('ignores an older directory refresh after a newer response removes the workspace', async () => {
  app.demo = undefined;
  app.workspaces = [workspace];
  vi.spyOn(api, 'nodes').mockResolvedValue([]);
  vi.spyOn(api, 'modes').mockResolvedValue([]);
  const older = deferred<Workspace[]>();
  vi.spyOn(api, 'workspaces').mockReturnValueOnce(older.promise).mockResolvedValueOnce([]);
  const pending = app.refreshNodes();
  await app.refreshNodes();
  older.resolve([workspace]);
  await pending;
  expect(app.workspaces).toEqual([]);
});

it('passes the visible environment and keeps the draft after a known stale rejection', async () => {
  app.demo = undefined;
  app.draftWorkspaceId = undefined;
  app.connection = 'connected';
  app.activeSessionId = demoSnapshot.session.id;
  const binding = {
    version: 1 as const,
    membership: { revision: 2, legacyWorkspaceId: demoSnapshot.session.workspaceId },
    execution: {
      generation: 7,
      workspaceId: demoSnapshot.session.workspaceId,
      nodeId: 'node',
      modeId: 'directory',
    },
  };
  app.sessionState = fromSnapshot({
    ...demoSnapshot,
    session: { ...demoSnapshot.session, binding },
    control: { heldByCurrentClient: true, generation: 3 },
  });
  app.setDraft('keep my message');
  const command = vi
    .spyOn(api, 'command')
    .mockRejectedValue(new ApiError('Environment changed', 409, 'stale_environment'));
  // After a switch the binding moved: it is refreshed, and nothing is resent.
  const moved = { ...binding, execution: { ...binding.execution, generation: 8 } };
  const snapshot = vi.spyOn(api, 'snapshot').mockResolvedValue({
    ...demoSnapshot,
    session: { ...demoSnapshot.session, binding: moved },
    control: { heldByCurrentClient: true, generation: 3 },
  } as never);
  await app.sendCommand('prompt');
  expect(command).toHaveBeenCalledTimes(1);
  expect(command.mock.calls[0][1].expectedBinding).toEqual(binding);
  expect(app.draft).toBe('keep my message');
  expect(app.pageError).toBe('Environment changed');
  await vi.waitFor(() => expect(app.sessionState?.session.binding).toEqual(moved));
  expect(snapshot).toHaveBeenCalledWith(demoSnapshot.session.id);
  expect(command).toHaveBeenCalledTimes(1);
  expect(app.draft).toBe('keep my message');
});
