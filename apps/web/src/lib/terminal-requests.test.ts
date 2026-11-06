import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { ApiError } from './http';
import { panelApi, type TerminalInfo } from './panel-api';
import {
  allowedActions,
  blocksTransitions,
  canAcknowledge,
  classifyFailure,
  parseCapabilities,
  phaseOf,
  terminalOffer,
  terminalRequestApi,
  TerminalRequests,
  type TerminalIntent,
  type TerminalOffer,
  type TerminalRequestResult,
  type TrackedRequest,
} from './terminal-requests';

// ---- a scripted Node behind fetch -------------------------------------------------

type Reply = { status: number; body?: unknown } | 'network';
interface Call {
  method: string;
  url: URL;
  body: Record<string, any> | undefined;
}
let calls: Call[];
let script: Array<(call: Call) => Reply | undefined>;

function node(...replies: Array<Reply | ((call: Call) => Reply | undefined)>) {
  script.push(...replies.map((reply) => (typeof reply === 'function' ? reply : () => reply)));
}

beforeEach(() => {
  calls = [];
  script = [];
  vi.stubGlobal(
    'fetch',
    vi.fn(async (input: string, init: RequestInit = {}) => {
      const call: Call = {
        method: init.method ?? 'GET',
        url: new URL(input, 'http://pirc.test'),
        body: init.body ? JSON.parse(init.body as string) : undefined,
      };
      calls.push(call);
      const next = script.shift();
      const reply = next?.(call);
      if (!reply) throw new Error(`unscripted ${call.method} ${call.url.search}`);
      if (reply === 'network') throw new TypeError('Failed to fetch');
      return new Response(reply.body === undefined ? null : JSON.stringify(reply.body), {
        status: reply.status,
      });
    }),
  );
  // Pending IDs are never persisted: IndexedDB stays at format 3 untouched.
  vi.stubGlobal('indexedDB', {
    open: () => {
      throw new Error('terminal requests must not use IndexedDB');
    },
  });
});
afterEach(() => vi.unstubAllGlobals());

const posts = () => calls.filter((call) => call.method === 'POST');
const gets = () => calls.filter((call) => call.method === 'GET');
const fail = (status: number, code: string) => ({
  status,
  body: { error: { code, message: code } },
});

const intent: TerminalIntent = {
  sessionId: 's1',
  clientId: 'client-a',
  generation: 7,
  cols: 80,
  rows: 24,
};
const terminal = (id = 't1', executionPath = 'isolated_work'): TerminalInfo => ({
  id,
  executionPath,
  sessionId: 's1',
  title: 'zsh',
  cwd: '/work',
  cols: 80,
  rows: 24,
  createdAt: 1,
  exitCode: null,
  exited: false,
});
const work = (
  requestId: string,
  state: string,
  extra: { errorCode?: string; terminal?: TerminalInfo; acknowledgedAt?: number | null } = {},
): TerminalRequestResult => ({
  workRequest: {
    version: 1,
    requestId,
    state,
    errorCode: extra.errorCode ?? null,
    terminalId: extra.terminal?.id ?? null,
    acknowledgedAt: extra.acknowledgedAt ?? null,
  },
  terminal: extra.terminal ?? null,
});
const WARNING =
  "Runs with the Node account's host permissions. Detached jobs and external effects may survive closing this terminal and keep workspace switching blocked.";
const host = (
  requestId: string,
  state: string,
  extra: {
    errorCode?: string;
    terminal?: TerminalInfo;
    cols?: number;
    rows?: number;
    acknowledgedAt?: number | null;
  } = {},
): TerminalRequestResult => ({
  hostManagement: {
    version: 1,
    requestId,
    id: `host_terminal_${requestId}`,
    reviewHash: `hash-${requestId}`,
    review: {
      version: 1,
      executionPath: 'host_management',
      workspaceId: 'w1',
      cwd: '/work',
      shell: '/bin/zsh',
      cols: extra.cols ?? 80,
      rows: extra.rows ?? 24,
      runnerEpoch: 3,
      warning: WARNING,
    },
    expiresAt: 99,
    state,
    errorCode: extra.errorCode ?? null,
    terminalId: extra.terminal?.id ?? null,
    acknowledgedAt: extra.acknowledgedAt ?? null,
  },
  terminal: extra.terminal ?? null,
});
/** The request ID of the first work/host POST, as sent. */
const sentId = (index = 0) => posts()[index]!.body!.requestId as string;
/** Replies to a POST with a result echoing the request ID the client sent. */
const echo =
  (status: number, result: (id: string) => TerminalRequestResult) =>
  (call: Call): Reply => ({ status, body: result(call.body!.requestId) });
/** Replies to a GET with a result for the queried ID. */
const read =
  (key: 'workRequestId' | 'hostRequestId', result: (id: string) => TerminalRequestResult) =>
  (call: Call): Reply => {
    expect(call.method).toBe('GET');
    return { status: 200, body: result(call.url.searchParams.get(key)!) };
  };

const isolated: TerminalOffer = { kind: 'isolated', hostManagement: true };
const unavailable: TerminalOffer = { kind: 'isolation_unavailable', hostManagement: true };
const capsV = (workTerminalRequestVersion: number) => ({
  enabled: true,
  isolatedTerminalVersion: 1,
  hostTerminalReviewVersion: 1,
  workTerminalRequestVersion,
});
function controller(options: { onterminal?: (t: TerminalInfo) => void; version?: number } = {}) {
  return new TerminalRequests({
    sessionId: 's1',
    sleep: async () => {},
    onterminal: options.onterminal,
    capabilities: capsV(options.version ?? 3),
  });
}

// ---- capabilities -----------------------------------------------------------------

describe('capabilities', () => {
  it('reads the per-session capability query', async () => {
    node({
      status: 200,
      body: {
        terminalCapabilities: {
          version: 1,
          enabled: true,
          isolatedTerminalVersion: 1,
          hostTerminalReviewVersion: 1,
          workTerminalRequestVersion: 2,
        },
      },
    });
    const caps = await terminalRequestApi.capabilities('s 1');
    expect(calls[0]!.url.pathname).toBe('/api/sessions/s%201/terminals');
    expect(calls[0]!.url.search).toBe('?capabilities=1');
    expect(terminalOffer(caps)).toEqual({ kind: 'isolated', hostManagement: true });
  });

  it('asks to update a Node without the query or with work-request version 1', async () => {
    // An older Node ignores the query and lists terminals.
    node({ status: 200, body: { terminals: [] } });
    const old = await terminalRequestApi.capabilities('s1');
    expect(old).toBeNull();
    expect(terminalOffer(old)).toEqual({ kind: 'update_node' });
    const v1 = parseCapabilities({
      terminalCapabilities: {
        enabled: true,
        isolatedTerminalVersion: 1,
        hostTerminalReviewVersion: 1,
        workTerminalRequestVersion: 1,
      },
    });
    expect(terminalOffer(v1)).toEqual({ kind: 'update_node' });
  });

  it('treats a missing field as version 0', () => {
    const caps = parseCapabilities({ terminalCapabilities: { enabled: true } })!;
    expect(caps).toEqual({
      enabled: true,
      isolatedTerminalVersion: 0,
      hostTerminalReviewVersion: 0,
      workTerminalRequestVersion: 0,
    });
    expect(terminalOffer(caps)).toEqual({ kind: 'update_node' });
    expect(
      terminalOffer(
        parseCapabilities({
          terminalCapabilities: { enabled: true, workTerminalRequestVersion: 2 },
        }),
      ),
    ).toEqual({ kind: 'isolation_unavailable', hostManagement: false });
  });

  it('distinguishes disabled, isolated and unavailable isolation', () => {
    const caps = (enabled: boolean, isolated: number, review: number) =>
      parseCapabilities({
        terminalCapabilities: {
          enabled,
          isolatedTerminalVersion: isolated,
          hostTerminalReviewVersion: review,
          workTerminalRequestVersion: 2,
        },
      });
    expect(terminalOffer(caps(false, 1, 1))).toEqual({ kind: 'disabled' });
    expect(terminalOffer(caps(true, 0, 1))).toEqual({
      kind: 'isolation_unavailable',
      hostManagement: true,
    });
    expect(terminalOffer(caps(true, 0, 0))).toEqual({
      kind: 'isolation_unavailable',
      hostManagement: false,
    });
  });
});

// ---- state table ------------------------------------------------------------------

describe('state table', () => {
  const tracked = (result: TerminalRequestResult, extra: Partial<TrackedRequest> = {}) =>
    ({
      kind: 'workRequest' in result ? 'work' : 'host',
      requestId: 'r1',
      phase: phaseOf(result),
      result,
      ...extra,
    }) as TrackedRequest;
  const rows: Array<[string, TerminalRequestResult, string, string[], boolean]> = [
    ['review', host('r1', 'review'), 'review', ['confirm', 'refresh', 'dismiss'], false],
    ['stale', host('r1', 'stale'), 'review_unusable', ['host_review', 'dismiss'], false],
    ['expired', host('r1', 'expired'), 'review_unusable', ['host_review', 'dismiss'], false],
    ['preparing', work('r1', 'preparing'), 'preparing', [], false],
    ['launching', work('r1', 'launching', { terminal: terminal() }), 'live', ['attach'], false],
    ['running', work('r1', 'running', { terminal: terminal() }), 'live', ['attach'], false],
    [
      'host running',
      host('r1', 'running', { terminal: terminal('t2', 'host_management') }),
      'live',
      ['attach'],
      false,
    ],
    [
      'not_started (spawn failure)',
      work('r1', 'not_started', { errorCode: 'runner_unavailable' }),
      'not_started',
      ['new_terminal', 'dismiss'],
      false,
    ],
    [
      'not_started (isolation unavailable)',
      work('r1', 'not_started', { errorCode: 'isolated_terminal_unavailable' }),
      'not_started',
      ['new_terminal', 'host_review', 'dismiss'],
      false,
    ],
    [
      'host not_started',
      host('r1', 'not_started', { errorCode: 'runner_unavailable' }),
      'not_started',
      ['host_review', 'dismiss'],
      false,
    ],
    [
      'outcome_unknown',
      work('r1', 'outcome_unknown', { errorCode: 'terminal_start_unconfirmed' }),
      'start_unconfirmed',
      ['refresh', 'dismiss'],
      true,
    ],
    [
      'running without a terminal',
      work('r1', 'running'),
      'start_unconfirmed',
      ['refresh', 'dismiss'],
      true,
    ],
    ['settled', work('r1', 'settled'), 'closed', ['dismiss'], false],
    ['unconfirmed', host('r1', 'unconfirmed'), 'closed_unconfirmed', ['dismiss'], true],
    ['a future state', work('r1', 'paused'), 'unknown_state', ['refresh', 'dismiss'], true],
    [
      'review on a work request',
      work('r1', 'review'),
      'unknown_state',
      ['refresh', 'dismiss'],
      true,
    ],
  ];
  for (const [name, result, phase, actions, blocks] of rows)
    it(`maps ${name}`, () => {
      const request = tracked(result, { intent });
      expect(request.phase).toBe(phase);
      expect(allowedActions(request, { intent, offer: isolated })).toEqual(actions);
      expect(blocksTransitions(request.phase)).toBe(blocks);
    });

  it('never offers a force-clear or automatic retry', () => {
    for (const [, result] of rows) {
      const actions = allowedActions(tracked(result, { intent }), { intent, offer: isolated });
      expect(actions).not.toContain('resubmit');
      expect(actions.join()).not.toMatch(/clear|force|retry/);
    }
  });

  it('offers no new isolated terminal or host action without isolation or control', () => {
    const failed = tracked(
      work('r1', 'not_started', { errorCode: 'isolated_terminal_unavailable' }),
    );
    expect(allowedActions(failed, { intent, offer: unavailable })).toEqual([
      'host_review',
      'dismiss',
    ]);
    expect(
      allowedActions(failed, {
        intent,
        offer: { kind: 'isolation_unavailable', hostManagement: false },
      }),
    ).toEqual(['dismiss']);
    expect(allowedActions(failed, { offer: isolated })).toEqual(['dismiss']);
    expect(allowedActions(tracked(host('r1', 'review')), { offer: isolated })).toEqual([
      'refresh',
      'dismiss',
    ]);
  });

  it('needs a new review after the lease changed', () => {
    const review = tracked(host('r1', 'review'), { intent });
    expect(
      allowedActions(review, { intent: { ...intent, generation: 8 }, offer: isolated }),
    ).toEqual(['refresh', 'dismiss']);
    // A discovered review (no known lease) is left to the Node to check.
    expect(allowedActions(tracked(host('r1', 'review')), { intent, offer: isolated })).toEqual([
      'confirm',
      'refresh',
      'dismiss',
    ]);
  });

  it('classifies failures', () => {
    expect(classifyFailure(new TypeError('Failed to fetch'))).toBe('ambiguous');
    expect(classifyFailure(new ApiError('x', 504, 'node_timeout'))).toBe('ambiguous');
    expect(classifyFailure(new ApiError('x', 503, 'node_offline'))).toBe('ambiguous');
    expect(classifyFailure(new ApiError('x', 502))).toBe('ambiguous');
    expect(classifyFailure(new ApiError('x', 404, 'terminal_request_not_found'))).toBe('not_found');
    // Any other 404, e.g. a missing session or an older Node's generic code, is definite.
    expect(classifyFailure(new ApiError('x', 404, 'not_found'))).toBe('rejected');
    expect(classifyFailure(new ApiError('x', 404))).toBe('rejected');
    expect(classifyFailure(new ApiError('x', 409, 'terminal_capacity'))).toBe('capacity');
    expect(classifyFailure(new ApiError('x', 409, 'terminal_request_not_unknown'))).toBe(
      'not_unknown',
    );
    expect(classifyFailure(new ApiError('x', 409, 'work_terminal_request_conflict'))).toBe(
      'conflict',
    );
    expect(classifyFailure(new ApiError('x', 409, 'host_terminal_review_required'))).toBe(
      'review_required',
    );
    expect(classifyFailure(new ApiError('x', 409, 'conflict'))).toBe('rejected');
    expect(classifyFailure(new ApiError('x', 400, 'work_terminal_request_required'))).toBe(
      'rejected',
    );
  });
});

// ---- isolated work requests -------------------------------------------------------

describe('isolated work requests', () => {
  it('sends isolated work with a fresh request ID per action and attaches a live terminal', async () => {
    const live: TerminalInfo[] = [];
    const requests = controller({ onterminal: (t) => live.push(t) });
    node(echo(201, (id) => work(id, 'running', { terminal: terminal('t1') })));
    node(echo(201, (id) => work(id, 'running', { terminal: terminal('t2') })));
    const first = await requests.openWork(intent);
    const second = await requests.openWork(intent);
    expect(posts()).toHaveLength(2);
    for (const call of posts()) {
      expect(call.url.pathname).toBe('/api/sessions/s1/terminals');
      expect(Object.keys(call.body!).sort()).toEqual(
        ['clientId', 'cols', 'executionPath', 'generation', 'requestId', 'rows'].sort(),
      );
      expect(call.body).toMatchObject({
        executionPath: 'isolated_work',
        clientId: 'client-a',
        generation: 7,
        cols: 80,
        rows: 24,
      });
      expect(call.body!.requestId).toMatch(/^[A-Za-z0-9_-]{1,128}$/);
    }
    expect(sentId(0)).not.toBe(sentId(1));
    expect(first).toMatchObject({ phase: 'live', requestId: sentId(0) });
    expect(second.phase).toBe('live');
    expect(live.map((t) => t.id)).toEqual(['t1', 't2']);
    expect(gets()).toHaveLength(0);
  });

  it('accepts a 200 repeat of an existing request', async () => {
    const requests = controller();
    node(echo(200, (id) => work(id, 'running', { terminal: terminal() })));
    expect((await requests.openWork(intent)).phase).toBe('live');
  });

  it('polls a 202 by GET until a final state, never POSTing again', async () => {
    const live: TerminalInfo[] = [];
    const requests = controller({ onterminal: (t) => live.push(t) });
    node(echo(202, (id) => work(id, 'preparing')));
    node(read('workRequestId', (id) => work(id, 'preparing')));
    node(read('workRequestId', (id) => work(id, 'preparing')));
    node(read('workRequestId', (id) => work(id, 'running', { terminal: terminal() })));
    const pending = await requests.openWork(intent);
    expect(pending.phase).toBe('preparing');
    await vi.waitFor(() => expect(requests.get(sentId())?.phase).toBe('live'));
    expect(posts()).toHaveLength(1);
    expect(gets().map((call) => call.url.searchParams.get('workRequestId'))).toEqual([
      sentId(),
      sentId(),
      sentId(),
    ]);
    expect([...gets()[0]!.url.searchParams.keys()]).toEqual(['workRequestId']);
    expect(live).toHaveLength(1);
  });

  it('polls a 202 into a known no-start', async () => {
    const requests = controller();
    node(echo(202, (id) => work(id, 'preparing')));
    node(
      read('workRequestId', (id) => work(id, 'not_started', { errorCode: 'runner_unavailable' })),
    );
    await requests.openWork(intent);
    await vi.waitFor(() => expect(requests.list[0]?.phase).toBe('not_started'));
    expect(requests.list[0]!.result).toMatchObject({
      workRequest: { errorCode: 'runner_unavailable' },
    });
  });

  it('stops polling on an unreachable Node and resumes on refresh', async () => {
    const requests = controller();
    node(echo(202, (id) => work(id, 'preparing')));
    node(fail(504, 'node_timeout'));
    await requests.openWork(intent);
    await vi.waitFor(() => expect(requests.list[0]?.stalled).toBe(true));
    expect(allowedActions(requests.list[0]!, { intent, offer: isolated })).toEqual(['refresh']);
    node(read('workRequestId', (id) => work(id, 'preparing')));
    node(read('workRequestId', (id) => work(id, 'running', { terminal: terminal() })));
    await requests.refresh(sentId());
    await vi.waitFor(() => expect(requests.list[0]?.phase).toBe('live'));
    expect(posts()).toHaveLength(1);
  });

  it('stops polling once disposed', async () => {
    let wake!: () => void;
    const requests = new TerminalRequests({
      sessionId: 's1',
      sleep: (_ms, signal) =>
        new Promise((resolve, reject) => {
          wake = resolve;
          signal.addEventListener('abort', () => reject(new DOMException('', 'AbortError')));
        }),
    });
    node(echo(202, (id) => work(id, 'preparing')));
    await requests.openWork(intent);
    requests.dispose();
    wake?.();
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(gets()).toHaveLength(0);
  });

  it('answers a 409 conflict with the original result, not a new ID', async () => {
    const requests = controller();
    node(fail(409, 'work_terminal_request_conflict'));
    node(read('workRequestId', (id) => work(id, 'outcome_unknown')));
    const result = await requests.openWork(intent);
    expect(result).toMatchObject({ phase: 'start_unconfirmed', conflict: true });
    expect(gets()[0]!.url.searchParams.get('workRequestId')).toBe(sentId());
    expect(posts()).toHaveLength(1);
  });

  for (const [name, reply] of [
    ['504 node_timeout', fail(504, 'node_timeout')],
    ['503 node_offline', fail(503, 'node_offline')],
    ['network loss', 'network'],
  ] as const)
    it(`resolves ${name} by GET`, async () => {
      const requests = controller();
      node(reply);
      node(read('workRequestId', (id) => work(id, 'running', { terminal: terminal() })));
      const result = await requests.openWork(intent);
      expect(result.phase).toBe('live');
      expect(posts()).toHaveLength(1);
      expect(gets()[0]!.url.searchParams.get('workRequestId')).toBe(sentId());
    });

  it('re-POSTs the same ID with the same intent after a 404', async () => {
    const requests = controller();
    node(fail(504, 'node_timeout'));
    node(fail(404, 'terminal_request_not_found'));
    const lost = await requests.openWork(intent);
    expect(lost.phase).toBe('not_admitted');
    expect(allowedActions(lost, { intent, offer: isolated })).toEqual(['resubmit', 'dismiss']);
    expect(posts()).toHaveLength(1); // nothing automatic
    node(echo(201, (id) => work(id, 'running', { terminal: terminal() })));
    expect(await requests.resubmit(lost.requestId, { ...intent })).toBe(true);
    expect(posts()).toHaveLength(2);
    expect(posts()[1]!.body).toEqual(posts()[0]!.body);
    expect(requests.get(lost.requestId)?.phase).toBe('live');
  });

  for (const [name, changed] of [
    ['control lease', { generation: 8 }],
    ['client', { clientId: 'client-b' }],
    ['size', { cols: 120 }],
  ] as const)
    it(`reads only after the ${name} changed`, async () => {
      const requests = controller();
      node(fail(503, 'node_offline'));
      node(fail(404, 'terminal_request_not_found'));
      const lost = await requests.openWork(intent);
      const current = { ...intent, ...changed };
      expect(allowedActions(lost, { intent: current, offer: isolated })).toEqual(['dismiss']);
      expect(await requests.resubmit(lost.requestId, current)).toBe(false);
      expect(posts()).toHaveLength(1);
      // Reading stays available.
      node(fail(404, 'terminal_request_not_found'));
      await requests.refresh(lost.requestId);
      expect(gets()).toHaveLength(2);
      expect(posts()).toHaveLength(1);
    });

  it('keeps an unanswered check readable without resending', async () => {
    const requests = controller();
    node(fail(504, 'node_timeout'));
    node('network');
    const lost = await requests.openWork(intent);
    expect(lost.phase).toBe('unknown_delivery');
    expect(allowedActions(lost, { intent, offer: isolated })).toEqual(['refresh']);
    node(read('workRequestId', (id) => work(id, 'preparing')));
    node(read('workRequestId', (id) => work(id, 'settled')));
    await requests.refresh(lost.requestId);
    await vi.waitFor(() => expect(requests.list[0]?.phase).toBe('closed'));
    expect(posts()).toHaveLength(1);
  });

  it('records a definite refusal without reading or retrying', async () => {
    const requests = controller();
    node(fail(409, 'conflict'));
    const refused = await requests.openWork(intent);
    expect(refused).toMatchObject({ phase: 'rejected', error: { code: 'conflict' } });
    expect(allowedActions(refused, { intent, offer: isolated })).toEqual(['dismiss']);
    expect(calls).toHaveLength(1);
  });

  it('has no omitted-path host terminal call left', () => {
    expect('createTerminal' in panelApi).toBe(false);
  });
});

// ---- isolation unavailable and host management ------------------------------------

describe('host management', () => {
  it('never falls back to a host terminal when isolation is unavailable', async () => {
    const requests = controller();
    node(
      echo(201, (id) => work(id, 'not_started', { errorCode: 'isolated_terminal_unavailable' })),
    );
    const failed = await requests.openWork(intent);
    expect(failed.phase).toBe('not_started');
    expect(calls).toHaveLength(1);
    expect(posts()[0]!.body!.executionPath).toBe('isolated_work');
    // The host path is a separate, explicit action only.
    expect(allowedActions(failed, { intent, offer: isolated })).toContain('host_review');
  });

  it('reviews, then confirms with the exact review identity', async () => {
    const live: TerminalInfo[] = [];
    const requests = controller({ onterminal: (t) => live.push(t) });
    node(echo(200, (id) => host(id, 'review')));
    const review = await requests.reviewHost(intent);
    expect(posts()[0]!.body).toEqual({
      executionPath: 'host_management',
      action: 'review',
      requestId: review.requestId,
      clientId: 'client-a',
      generation: 7,
      cols: 80,
      rows: 24,
    });
    expect(review.phase).toBe('review');
    const details = (review.result as any).hostManagement.review;
    expect(details).toMatchObject({ shell: '/bin/zsh', cwd: '/work', cols: 80, rows: 24 });
    expect(details.warning).toBe(WARNING);
    node(echo(201, (id) => host(id, 'running', { terminal: terminal('t9', 'host_management') })));
    expect(await requests.confirmHost(review.requestId, intent)).toBe(true);
    expect(posts()[1]!.body).toEqual({
      executionPath: 'host_management',
      action: 'confirm',
      requestId: review.requestId,
      reviewId: `host_terminal_${review.requestId}`,
      reviewHash: `hash-${review.requestId}`,
      confirmed: true,
      clientId: 'client-a',
      generation: 7,
      cols: 80,
      rows: 24,
    });
    expect(requests.get(review.requestId, 'host')?.phase).toBe('live');
    expect(live.map((t) => t.executionPath)).toEqual(['host_management']);
  });

  it('confirms with the size the Node reviewed', async () => {
    const requests = controller();
    node(echo(200, (id) => host(id, 'review', { cols: 20, rows: 5 })));
    const review = await requests.reviewHost({ ...intent, cols: 10, rows: 2 });
    node(echo(201, (id) => host(id, 'running', { terminal: terminal() })));
    await requests.confirmHost(review.requestId, { ...intent, cols: 10, rows: 2 });
    expect(posts()[1]!.body).toMatchObject({ cols: 20, rows: 5 });
  });

  it('refuses to confirm after a lease change', async () => {
    const requests = controller();
    node(echo(200, (id) => host(id, 'review')));
    const review = await requests.reviewHost(intent);
    expect(await requests.confirmHost(review.requestId, { ...intent, generation: 8 })).toBe(false);
    expect(posts()).toHaveLength(1);
  });

  it('reads the review state when a confirm is refused', async () => {
    const requests = controller();
    node(echo(200, (id) => host(id, 'review')));
    const review = await requests.reviewHost(intent);
    node(fail(409, 'host_terminal_review_required'));
    node(read('hostRequestId', (id) => host(id, 'expired')));
    await requests.confirmHost(review.requestId, intent);
    const after = requests.get(review.requestId, 'host')!;
    expect(after.phase).toBe('review_unusable');
    expect(after.error?.code).toBe('host_terminal_review_required');
    expect(allowedActions(after, { intent, offer: unavailable })).toEqual([
      'host_review',
      'dismiss',
    ]);
    expect(gets()[0]!.url.searchParams.get('hostRequestId')).toBe(review.requestId);
  });

  it('recovers an ambiguous confirm by GET', async () => {
    const requests = controller();
    node(echo(200, (id) => host(id, 'review')));
    const review = await requests.reviewHost(intent);
    node(fail(504, 'node_timeout'));
    node(read('hostRequestId', (id) => host(id, 'running', { terminal: terminal() })));
    await requests.confirmHost(review.requestId, intent);
    expect(requests.get(review.requestId, 'host')?.phase).toBe('live');
    expect(posts()).toHaveLength(2);
  });

  it('re-sends a lost review under the same ID after a 404', async () => {
    const requests = controller();
    node('network');
    node(fail(404, 'terminal_request_not_found'));
    const lost = await requests.reviewHost(intent);
    expect(lost.phase).toBe('not_admitted');
    node(echo(200, (id) => host(id, 'review')));
    expect(await requests.resubmit(lost.requestId, intent, 'host')).toBe(true);
    expect(posts()[1]!.body).toEqual(posts()[0]!.body);
    expect(requests.get(lost.requestId, 'host')?.phase).toBe('review');
  });

  it('answers a changed review intent under the same ID with its stored review', async () => {
    const requests = controller();
    node(fail(409, 'host_terminal_review_required'));
    node(read('hostRequestId', (id) => host(id, 'stale')));
    const result = await requests.reviewHost(intent);
    expect(result.phase).toBe('review_unusable');
  });
});

// ---- discovery --------------------------------------------------------------------

describe('unresolved-request recovery', () => {
  it('follows next through short and empty pages', async () => {
    node(
      {
        status: 200,
        body: {
          terminalRequests: { version: 1, items: [work('a', 'preparing')], next: '1.work.a' },
        },
      },
      { status: 200, body: { terminalRequests: { version: 1, items: [], next: '2.host.b' } } },
      {
        status: 200,
        body: {
          terminalRequests: {
            version: 1,
            items: [host('c', 'review'), work('d', 'outcome_unknown')],
            next: null,
          },
        },
      },
    );
    const items = await terminalRequestApi.unresolved('s1', { limit: 2 });
    expect(
      items.map(
        (item) => ('workRequest' in item ? item.workRequest : item.hostManagement).requestId,
      ),
    ).toEqual(['a', 'c', 'd']);
    expect(calls.map((call) => call.url.search)).toEqual([
      '?unresolvedRequests=1&limit=2',
      '?unresolvedRequests=1&limit=2&after=1.work.a',
      '?unresolvedRequests=1&limit=2&after=2.host.b',
    ]);
  });

  it('stops on a cursor that does not advance', async () => {
    const page = {
      status: 200,
      body: { terminalRequests: { version: 1, items: [], next: 'x.work.a' } },
    };
    node(page, page);
    await expect(terminalRequestApi.unresolved('s1')).rejects.toThrow(/advance/);
    expect(calls.map((call) => call.url.search)).toEqual([
      '?unresolvedRequests=1',
      '?unresolvedRequests=1&after=x.work.a',
    ]);
  });

  it('restores pending requests after a reload, without stored IDs', async () => {
    const live: TerminalInfo[] = [];
    const requests = controller({ onterminal: (t) => live.push(t) });
    node(
      {
        status: 200,
        body: {
          terminalRequests: { version: 1, items: [work('a', 'preparing')], next: '1.work.a' },
        },
      },
      {
        status: 200,
        body: {
          terminalRequests: {
            version: 1,
            items: [host('b', 'review'), work('c', 'outcome_unknown')],
            next: null,
          },
        },
      },
    );
    node(read('workRequestId', (id) => work(id, 'running', { terminal: terminal() })));
    await requests.recover();
    expect(requests.get('b', 'host')?.phase).toBe('review');
    expect(requests.get('c')?.phase).toBe('start_unconfirmed');
    await vi.waitFor(() => expect(requests.get('a')?.phase).toBe('live'));
    expect(live).toHaveLength(1);
    expect(posts()).toHaveLength(0);
    // The rediscovered review confirms under the current lease and its reviewed size.
    expect(allowedActions(requests.get('b', 'host')!, { intent, offer: unavailable })).toContain(
      'confirm',
    );
    node(echo(201, (id) => host(id, 'running', { terminal: terminal('t5') })));
    await requests.confirmHost('b', intent);
    expect(posts()[0]!.body).toMatchObject({ requestId: 'b', reviewId: 'host_terminal_b' });
  });

  it('rejects when discovery cannot be read', async () => {
    const requests = controller();
    node(fail(504, 'node_timeout'));
    await expect(requests.recover()).rejects.toBeInstanceOf(ApiError);
    expect(requests.list).toEqual([]);
  });
});

// ---- v3: specific errors ----------------------------------------------------------

describe('specific errors (v3)', () => {
  it('refuses a full quota with its own reason, without reading or retrying', async () => {
    const requests = controller();
    node(fail(409, 'terminal_capacity'));
    const refused = await requests.openWork(intent);
    expect(refused).toMatchObject({
      phase: 'rejected',
      error: { code: 'terminal_capacity', reason: 'capacity' },
    });
    expect(allowedActions(refused, { intent, offer: isolated })).toEqual(['dismiss']);
    expect(calls).toHaveLength(1);
  });

  it('treats a POST 404 for a missing session as a definite refusal', async () => {
    const requests = controller();
    node(fail(404, 'not_found'));
    const refused = await requests.openWork(intent);
    expect(refused).toMatchObject({ phase: 'rejected', error: { reason: 'rejected' } });
    expect(calls).toHaveLength(1);
  });

  it('offers no same-ID resend when the GET 404 is not terminal_request_not_found', async () => {
    const requests = controller();
    node(fail(504, 'node_timeout'));
    node(fail(404, 'not_found'));
    const lost = await requests.openWork(intent);
    expect(lost.phase).toBe('unknown_delivery');
    expect(allowedActions(lost, { intent, offer: isolated })).toEqual(['refresh']);
    expect(await requests.resubmit(lost.requestId, intent)).toBe(false);
    expect(posts()).toHaveLength(1);
  });
});

// ---- v3: acknowledgement ----------------------------------------------------------

describe('acknowledgement (v3)', () => {
  const unknown = (id = 'u1') =>
    ({
      kind: 'work',
      requestId: id,
      phase: 'start_unconfirmed',
      result: work(id, 'outcome_unknown'),
    }) as TrackedRequest;
  const page = (...items: TerminalRequestResult[]) => ({
    status: 200,
    body: { terminalRequests: { version: 1, items, next: null } },
  });

  it('needs workTerminalRequestVersion 3', () => {
    expect(canAcknowledge(null)).toBe(false);
    expect(canAcknowledge(parseCapabilities({ terminalCapabilities: capsV(2) }))).toBe(false);
    expect(canAcknowledge(parseCapabilities({ terminalCapabilities: capsV(3) }))).toBe(true);
    expect(canAcknowledge(parseCapabilities({ terminalCapabilities: { enabled: false } }))).toBe(
      false,
    );
  });

  it('is offered only for outcome_unknown, on v3, with the current lease', () => {
    const v3 = { intent, offer: isolated, acknowledge: true };
    expect(allowedActions(unknown(), v3)).toEqual(['acknowledge', 'refresh', 'dismiss']);
    // Also while new terminals are disabled.
    expect(allowedActions(unknown(), { ...v3, offer: { kind: 'disabled' } })).toContain(
      'acknowledge',
    );
    expect(allowedActions(unknown(), { intent, offer: isolated })).toEqual(['refresh', 'dismiss']);
    expect(allowedActions(unknown(), { ...v3, intent: undefined })).toEqual(['refresh', 'dismiss']);
    const done = { ...unknown(), result: work('u1', 'outcome_unknown', { acknowledgedAt: 5 }) };
    expect(allowedActions(done, v3)).toEqual(['refresh', 'dismiss']);
    const liveless = { ...unknown(), result: work('u1', 'running') };
    expect(liveless.phase).toBe('start_unconfirmed');
    expect(allowedActions(liveless, v3)).toEqual(['refresh', 'dismiss']);
    for (const result of [
      work('u1', 'preparing'),
      work('u1', 'not_started', { errorCode: 'runner_unavailable' }),
      host('u1', 'review'),
      work('u1', 'settled'),
      host('u1', 'unconfirmed'),
    ]) {
      const request = { ...unknown(), result, phase: phaseOf(result) } as TrackedRequest;
      expect(allowedActions(request, v3)).not.toContain('acknowledge');
    }
  });

  for (const kind of ['work', 'host'] as const)
    it(`acknowledges a recovered ${kind} request and stops listing it`, async () => {
      const changes: TrackedRequest[][] = [];
      const requests = new TerminalRequests({
        sessionId: 's1',
        sleep: async () => {},
        capabilities: capsV(3),
        onchange: (list) => changes.push(list),
      });
      const make = kind === 'work' ? work : host;
      node(page(make('u1', 'outcome_unknown', { errorCode: 'terminal_start_unconfirmed' })));
      await requests.recover();
      expect(requests.get('u1', kind)?.phase).toBe('start_unconfirmed');
      node((call) => ({
        status: 200,
        body: make(
          call.body![kind === 'work' ? 'workRequestId' : 'hostRequestId'],
          'outcome_unknown',
          {
            acknowledgedAt: 1234,
          },
        ),
      }));
      expect(await requests.acknowledge('u1', { ...intent, generation: 9 }, kind)).toBe(true);
      expect(posts()[0]!.url.pathname).toBe('/api/sessions/s1/terminals');
      expect(posts()[0]!.body).toEqual({
        action: 'acknowledge',
        clientId: 'client-a',
        generation: 9,
        [kind === 'work' ? 'workRequestId' : 'hostRequestId']: 'u1',
      });
      expect(requests.get('u1', kind)).toBeUndefined();
      expect(requests.list).toEqual([]);
      // Nothing ever showed it as closed.
      expect(changes.flat().map((r) => r.phase)).not.toContain('closed');
      // A later recovery that still returned it (it should not) keeps it hidden.
      node(page(make('u1', 'outcome_unknown', { acknowledgedAt: 1234 })));
      await requests.recover();
      expect(requests.list).toEqual([]);
    });

  it('sends nothing to a v2 Node', async () => {
    const requests = controller({ version: 2 });
    node(page(work('u1', 'outcome_unknown')));
    await requests.recover();
    expect(await requests.acknowledge('u1', intent)).toBe(false);
    expect(posts()).toHaveLength(0);
  });

  it('does not acknowledge other states', async () => {
    const requests = controller();
    node(page(work('p1', 'preparing')));
    node(read('workRequestId', (id) => work(id, 'preparing')));
    await requests.recover();
    expect(await requests.acknowledge('p1', intent)).toBe(false);
    expect(posts()).toHaveLength(0);
    requests.dispose();
  });

  it('re-reads the result on 409 terminal_request_not_unknown', async () => {
    const requests = controller();
    node(page(work('u1', 'outcome_unknown')));
    await requests.recover();
    node(fail(409, 'terminal_request_not_unknown'));
    node(read('workRequestId', (id) => work(id, 'unconfirmed')));
    await requests.acknowledge('u1', intent);
    const after = requests.get('u1')!;
    expect(after.phase).toBe('closed_unconfirmed');
    expect(after.error).toMatchObject({
      code: 'terminal_request_not_unknown',
      reason: 'not_unknown',
    });
    expect(gets()[gets().length - 1]!.url.searchParams.get('workRequestId')).toBe('u1');
  });

  it('resolves an ambiguous acknowledgement by GET', async () => {
    const requests = controller();
    node(page(work('u1', 'outcome_unknown'), work('u2', 'outcome_unknown')));
    await requests.recover();
    // Recorded before the reply was lost.
    node(fail(504, 'node_timeout'));
    node(read('workRequestId', (id) => work(id, 'outcome_unknown', { acknowledgedAt: 7 })));
    await requests.acknowledge('u1', intent);
    expect(requests.get('u1')).toBeUndefined();
    // Not recorded: still unknown and acknowledgeable again (the Node repeats idempotently).
    node('network');
    node(read('workRequestId', (id) => work(id, 'outcome_unknown')));
    await requests.acknowledge('u2', intent);
    const still = requests.get('u2')!;
    expect(still.phase).toBe('start_unconfirmed');
    expect(allowedActions(still, { intent, offer: isolated, acknowledge: true })).toContain(
      'acknowledge',
    );
    expect(posts()).toHaveLength(2);
  });

  it('keeps the request on a definite refusal', async () => {
    const requests = controller();
    node(page(work('u1', 'outcome_unknown')));
    await requests.recover();
    node(fail(409, 'control_lease_stale'));
    await requests.acknowledge('u1', intent);
    expect(requests.get('u1')).toMatchObject({
      phase: 'start_unconfirmed',
      error: { code: 'control_lease_stale' },
    });
    expect(gets()).toHaveLength(1); // only the discovery page
  });
});
