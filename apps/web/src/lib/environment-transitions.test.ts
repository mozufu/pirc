import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
  allowedSwitchActions,
  backoff,
  classifySwitchFailure,
  EnvironmentSwitch,
  environmentTransitionApi,
  isBindingRefusal,
  ITEM_KIND_LABELS,
  ITEM_REASON_LABELS,
  PASSED_THROUGH,
  parseStatus,
  resultOf,
  transitionPhase,
  type SwitchPhase,
  type SwitchState,
  type TransitionLease,
} from './environment-transitions';
import { ApiError } from './http';
import type { ConversationBinding } from './types';

// ---- a scripted Gateway behind fetch ----------------------------------------------

type Reply = { status: number; body?: unknown } | 'network';
interface Call {
  method: string;
  url: URL;
  body: Record<string, any> | undefined;
}
let calls: Call[];
let script: Array<(call: Call) => Reply>;
const node = (...replies: Array<Reply | ((call: Call) => Reply)>) =>
  script.push(...replies.map((reply) => (typeof reply === 'function' ? reply : () => reply)));

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
      if (!next) throw new Error(`unscripted ${call.method} ${call.url.pathname}`);
      const reply = next(call);
      if (reply === 'network') throw new TypeError('Failed to fetch');
      return new Response(JSON.stringify(reply.body ?? null), { status: reply.status });
    }),
  );
  // No local persistence: IndexedDB format 3 is never touched.
  vi.stubGlobal('indexedDB', {
    open: () => {
      throw new Error('environment switching must not use IndexedDB');
    },
  });
});
afterEach(() => vi.unstubAllGlobals());

const posts = () => calls.filter((c) => c.method === 'POST');
const paths = () => calls.map((c) => `${c.method} ${c.url.pathname}`);
const fail = (status: number, code: string) => ({
  status,
  body: { error: { code, message: code } },
});
const ok = (body: unknown) => ({ status: 200, body });

const SOURCE = 'node:source';
const TARGET = 'node:target';
const binding = (generation: number, workspace = SOURCE): ConversationBinding => ({
  version: 1,
  membership: { revision: generation, legacyWorkspaceId: workspace },
  execution: { generation, workspaceId: workspace, nodeId: 'node', modeId: 'research' },
});
const environment = (b: ConversationBinding, activeTransition: unknown = null) => ({
  version: 1,
  sessionId: 's1',
  binding: b,
  project: { revision: 1, workspaceId: b.membership.legacyWorkspaceId, resolution: 'member' },
  modePolicy: { revision: 1, definition: { id: 'research' } },
  workspacePolicy: {
    revision: 1,
    capabilities: {
      version: 1,
      delegation: true,
      memory_search: true,
      remote_recall: false,
      schedules: true,
      web_search: true,
      delegation_approval: 'always',
    },
  },
  enforcement: 'not_tracked',
  activeTransition,
});
const preview = (
  operationId: string,
  extra: {
    state?: string;
    canConfirm?: boolean;
    blockedBy?: string[];
    preflight?: Record<string, unknown>;
  } = {},
) => ({
  preview: {
    operationId,
    sessionId: 's1',
    targetWorkspaceId: TARGET,
    planHash: `plan-${operationId}`,
    plan: {},
    createdAt: 1,
  },
  state: extra.state ?? 'preview',
  canConfirm: extra.canConfirm ?? true,
  blockedBy: extra.blockedBy ?? [],
  nodeObservations: [{ nodeId: 'node', status: 'observed', acknowledgesRevocation: true }],
  resourcePreflight: extra.preflight ?? {
    status: 'observed',
    observationHash: `obs-${operationId}`,
    observation: {},
  },
});
const items = [
  { kind: 'platform_containment', reason: 'descendants_not_contained', acknowledgeable: true },
  { kind: 'host_command', reason: 'host_effects_may_survive', acknowledgeable: true },
];
const revocation = (
  status: string,
  digest = 'digest-1',
  list = items,
  itemsTotal = list.length,
) => ({
  state: status === 'pending' ? 'stopping' : 'supervisor_drained',
  errorCode: null,
  revocationConfirmed: false,
  targetInstalled: false,
  revocation: { status, digest, itemsTotal, confirmsContainment: false, items: list },
  installation: null,
});
const status = (
  operationId: string,
  state: string,
  extra: { progress?: unknown; revocationConfirmed?: boolean; reconciliationState?: string } = {},
) => ({
  transition: {
    operationId,
    sessionId: 's1',
    state,
    createdAt: 1,
    revocationConfirmed: extra.revocationConfirmed ?? false,
    targetInstalled: state === 'installed',
  },
  canConfirm: false,
  ...('progress' in extra ? { progress: extra.progress } : {}),
  ...(extra.reconciliationState ? { reconciliationState: extra.reconciliationState } : {}),
});
/** Replies to a call on operation `op` read from the URL. */
const opOf = (call: Call) =>
  decodeURIComponent(
    call.url.pathname.split('/').filter(Boolean)[4] === 'previews'
      ? call.url.pathname.split('/')[6]!
      : call.url.pathname.split('/')[5]!,
  );

const lease: TransitionLease = { sessionId: 's1', clientId: 'client-a', generation: 7 };
let delays: number[];
let changes: SwitchState[];
let bindings: ConversationBinding[];
const flows: EnvironmentSwitch[] = [];
afterEach(() => flows.splice(0).forEach((flow) => flow.dispose()));
/** `poll: true` reads again immediately; otherwise automatic reads wait until disposed. */
function controller(options: { poll?: boolean } = {}) {
  delays = [];
  changes = [];
  bindings = [];
  const flow = new EnvironmentSwitch({
    sessionId: 's1',
    sleep: (ms, signal) => {
      delays.push(ms);
      if (options.poll) return Promise.resolve();
      return new Promise((_, reject) =>
        signal.addEventListener('abort', () => reject(new DOMException('', 'AbortError'))),
      );
    },
    onchange: (state) => changes.push(state),
    onbinding: (b) => bindings.push(b),
  });
  flows.push(flow);
  return flow;
}
/** Preview and review a move; leaves the switch in `review`. */
async function reviewed(flow: EnvironmentSwitch) {
  node((call) => ok(preview(call.body!.operationId)));
  await flow.preview(TARGET, binding(1));
  expect(flow.state.phase).toBe('review');
  return flow.state.operationId!;
}
const settle = async () => {
  for (let i = 0; i < 10; i++) await new Promise((resolve) => setTimeout(resolve, 0));
};

// ---- mapping ----------------------------------------------------------------------

describe('state mapping', () => {
  const rows: Array<[string, unknown, SwitchPhase]> = [
    ['accepted', status('o', 'accepted'), 'awaiting_dispatch'],
    ['outcome_unknown', status('o', 'outcome_unknown'), 'outcome_unknown'],
    ['node_fenced without progress', status('o', 'node_fenced', { progress: null }), 'draining'],
    ['node_fenced, receipt read', status('o', 'node_fenced'), 'draining'],
    ['pending', status('o', 'node_fenced', { progress: revocation('pending') }), 'draining'],
    ['blocked', status('o', 'node_fenced', { progress: revocation('blocked') }), 'blocked'],
    [
      'unproven',
      status('o', 'node_fenced', { progress: revocation('unproven') }),
      'needs_acknowledgement',
    ],
    ['confirmed', status('o', 'node_fenced', { progress: revocation('confirmed') }), 'installing'],
    ['installed', status('o', 'installed', { revocationConfirmed: true }), 'switched'],
    ['released', status('o', 'released'), 'cancelled'],
    ['deleted', status('o', 'deleted'), 'deleted'],
    ['a future state', status('o', 'paused'), 'unknown_state'],
    [
      'a future revocation status',
      status('o', 'node_fenced', { progress: revocation('later') }),
      'unknown_state',
    ],
  ];
  for (const [name, raw, phase] of rows)
    it(`maps ${name}`, () => expect(transitionPhase(parseStatus(raw))).toBe(phase));

  it('distinguishes the three results', () => {
    expect(resultOf(parseStatus(status('o', 'installed', { revocationConfirmed: true })))).toBe(
      'revocation_confirmed',
    );
    expect(resultOf(parseStatus(status('o', 'installed', { revocationConfirmed: false })))).toBe(
      'revocation_not_fully_confirmed',
    );
    expect(resultOf(parseStatus(status('o', 'released')))).toBe('original_kept');
    expect(resultOf(parseStatus(status('o', 'node_fenced')))).toBeUndefined();
  });

  it('never reads confirmed revocation from a transition that is not installed', () => {
    const raw = status('o', 'node_fenced', { revocationConfirmed: true });
    expect(parseStatus(raw).transition.revocationConfirmed).toBe(false);
  });

  it('tells a read without progress from one with none yet, and keeps the items sanitized', () => {
    expect(parseStatus(status('o', 'node_fenced')).progress).toBeUndefined();
    expect(parseStatus(status('o', 'node_fenced', { progress: null })).progress).toBeNull();
    const parsed = parseStatus(
      status('o', 'node_fenced', { progress: revocation('unproven', 'd', items, 140) }),
    );
    expect(parsed.progress?.revocation).toEqual({
      status: 'unproven',
      digest: 'd',
      itemsTotal: 140,
      confirmsContainment: false,
      items,
    });
  });

  it('has plain-language labels for every Node item kind and reason', () => {
    for (const kind of [
      'sandbox_launch',
      'host_command',
      'terminal',
      'host_terminal',
      'browser',
      'native_proxy',
      'legacy_history',
      'unattributed',
      'platform_containment',
    ])
      expect(ITEM_KIND_LABELS[kind]).toBeTruthy();
    for (const reason of [
      'unresolved',
      'uncontained_launch',
      'untracked_launch',
      'launches_before_journals',
      'host_effects_may_survive',
      'other_workspace',
      'no_binding_generation',
      'binding_changed_without_generation',
      'descendants_not_contained',
    ])
      expect(ITEM_REASON_LABELS[reason]).toBeTruthy();
  });

  it('offers actions by phase, cancel only until installation', () => {
    const at = (phase: SwitchPhase, extra: Partial<SwitchState> = {}) => ({ phase, ...extra });
    const unproven = parseStatus(status('o', 'node_fenced', { progress: revocation('unproven') }));
    const cases: Array<[SwitchState, string[], string[]]> = [
      [at('idle'), ['preview'], ['preview']],
      [
        at('review', {
          preview: {
            operationId: 'o',
            targetWorkspaceId: TARGET,
            planHash: 'p',
            state: 'preview',
            canConfirm: true,
            blockedBy: [],
            resourcePreflightStatus: 'observed',
            observationHash: 'h',
            nodeObservations: [],
          },
        }),
        ['confirm', 'refresh', 'discard'],
        ['refresh', 'discard'],
      ],
      [at('review_blocked'), ['refresh', 'discard'], ['refresh', 'discard']],
      [at('review_stale'), ['review_again', 'discard'], ['review_again', 'discard']],
      [at('switching_disabled'), ['discard'], ['discard']],
      [at('preview_unknown'), ['refresh'], ['refresh']],
      [at('preview_missing'), ['resend', 'discard'], ['resend', 'discard']],
      [at('confirm_unknown'), ['refresh'], ['refresh']],
      [at('awaiting_dispatch'), ['refresh', 'cancel'], ['refresh']],
      [at('outcome_unknown'), ['refresh', 'cancel'], ['refresh']],
      [at('draining'), ['refresh', 'cancel'], ['refresh']],
      [at('blocked'), ['refresh', 'cancel'], ['refresh']],
      [at('installing'), ['refresh', 'cancel'], ['refresh']],
      [
        at('needs_acknowledgement', { status: unproven }),
        ['acknowledge', 'refresh', 'cancel'],
        ['refresh'],
      ],
      [at('needs_acknowledgement'), ['refresh'], ['refresh']],
      [at('switched'), ['discard'], ['discard']],
      [at('cancelled'), ['discard'], ['discard']],
      [at('deleted'), ['discard'], ['discard']],
      [at('legacy_fence'), ['refresh'], ['refresh']],
      [at('unknown_state'), ['refresh'], ['refresh']],
      [at('rejected'), ['discard'], ['discard']],
      [at('previewing'), [], []],
      [at('confirming'), [], []],
    ];
    for (const [state, withControl, without] of cases) {
      expect(allowedSwitchActions(state, lease), state.phase).toEqual(withControl);
      expect(allowedSwitchActions(state, undefined), state.phase).toEqual(without);
    }
  });

  it('classifies every passed-through and Gateway code', () => {
    const c = (status: number, code?: string) =>
      classifySwitchFailure(new ApiError(code ?? 'x', status, code));
    expect(classifySwitchFailure(new TypeError('Failed to fetch'))).toBe('ambiguous');
    expect(c(502, 'transition_step_failed')).toBe('ambiguous');
    expect(c(502, 'invalid_transition_receipt')).toBe('ambiguous');
    expect(c(504, 'node_timeout')).toBe('ambiguous');
    expect(c(503, 'node_offline')).toBe('ambiguous');
    expect(c(404, 'not_found')).toBe('not_found');
    expect(c(409, 'transition_coordinator_unavailable')).toBe('disabled');
    expect(c(409, 'transition_review_changed')).toBe('stale');
    expect(c(409, 'stale_environment')).toBe('stale');
    expect(c(409, 'revocation_digest_changed')).toBe('digest_changed');
    expect(c(409, 'transition_installed')).toBe('installed');
    expect(c(409, 'transition_released')).toBe('released');
    expect(c(409, 'lost_control')).toBe('lost_control');
    for (const code of [
      'revocation_unconfirmed',
      'transition_not_unproven',
      'transition_not_drained',
      'transition_draining',
      'transition_target_unreviewed',
      'stale_transition_target',
      'transition_outcome_unknown',
      'transition_not_reviewable',
      'conflict',
    ])
      expect(c(409, code), code).toBe('rejected');
  });

  it('recognizes binding refusals of commands', () => {
    expect(isBindingRefusal(new ApiError('x', 409, 'stale_environment'))).toBe(true);
    expect(isBindingRefusal(new ApiError('x', 409, 'environment_required'))).toBe(true);
    expect(isBindingRefusal(new ApiError('x', 409, 'lost_control'))).toBe(false);
  });

  it('backs off by doubling up to 30 s', () => {
    expect([0, 1, 2, 3, 4, 5, 6].map(backoff)).toEqual([
      1000, 2000, 4000, 8000, 16000, 30000, 30000,
    ]);
  });
});

// ---- preview ----------------------------------------------------------------------

describe('preview', () => {
  it('sends a fresh operation identity per action and refreshes by GET', async () => {
    const flow = controller();
    const first = await reviewed(flow);
    expect(posts()[0]!.url.pathname).toBe('/api/sessions/s1/environment-transitions/previews');
    expect(posts()[0]!.body).toEqual({
      operationId: first,
      targetWorkspaceId: TARGET,
      expectedBinding: binding(1),
    });
    expect(first).toMatch(/^[A-Za-z0-9_-]{1,100}$/);
    expect(allowedSwitchActions(flow.state, lease)).toContain('confirm');
    node(ok(preview(first, { canConfirm: false, blockedBy: ['source_has_pending_work'] })));
    await flow.refresh();
    expect(calls[1]!.method).toBe('GET');
    expect(calls[1]!.url.pathname).toBe(
      `/api/sessions/s1/environment-transitions/previews/${first}`,
    );
    expect(flow.state.phase).toBe('review_blocked');
    expect(flow.state.preview?.blockedBy).toEqual(['source_has_pending_work']);
    expect(allowedSwitchActions(flow.state, lease)).not.toContain('confirm');
    flow.discard();
    const second = await reviewed(flow);
    expect(second).not.toBe(first);
  });

  it('offers no confirm without an observed preflight even if canConfirm were set', async () => {
    const flow = controller();
    node((call) => ok(preview(call.body!.operationId, { preflight: { status: 'offline' } })));
    await flow.preview(TARGET, binding(1));
    expect(flow.state.phase).toBe('review_blocked');
    expect(await flow.confirm(lease)).toBe(false);
    expect(posts()).toHaveLength(1);
  });

  it('shows switching as disabled on a Gateway without the coordinator', async () => {
    const flow = controller();
    node((call) =>
      ok(
        preview(call.body!.operationId, {
          canConfirm: false,
          blockedBy: ['coordinator_not_available'],
        }),
      ),
    );
    await flow.preview(TARGET, binding(1));
    expect(flow.state.phase).toBe('switching_disabled');
    expect(allowedSwitchActions(flow.state, lease)).toEqual(['discard']);
  });

  it('asks for a new review of a stale preview, under a new identity', async () => {
    const flow = controller();
    node((call) =>
      ok(
        preview(call.body!.operationId, {
          state: 'stale',
          canConfirm: false,
          blockedBy: ['preview_stale'],
        }),
      ),
    );
    await flow.preview(TARGET, binding(1));
    expect(flow.state.phase).toBe('review_stale');
    const old = flow.state.operationId;
    await reviewed(flow);
    expect(flow.state.operationId).not.toBe(old);
  });

  it('treats a stale expected binding as a new review', async () => {
    const flow = controller();
    node(fail(409, 'stale_environment'));
    await flow.preview(TARGET, binding(1));
    expect(flow.state).toMatchObject({
      phase: 'review_stale',
      error: { code: 'stale_environment' },
    });
  });

  it('resolves a lost preview reply by GET, and re-sends the same identity only if absent', async () => {
    const flow = controller();
    node('network', fail(404, 'not_found'));
    await flow.preview(TARGET, binding(1));
    expect(flow.state.phase).toBe('preview_missing');
    const sent = posts()[0]!.body;
    node((call) => ok(preview(call.body!.operationId)));
    expect(await flow.resend()).toBe(true);
    expect(posts()[1]!.body).toEqual(sent);
    expect(flow.state.phase).toBe('review');

    const other = controller();
    calls = [];
    node(fail(504, 'node_timeout'), (call) => ok(preview(opOf(call))));
    await other.preview(TARGET, binding(1));
    expect(other.state.phase).toBe('review');
    expect(paths()).toEqual([
      'POST /api/sessions/s1/environment-transitions/previews',
      `GET /api/sessions/s1/environment-transitions/previews/${other.state.operationId}`,
    ]);
  });
});

// ---- confirm and progress ---------------------------------------------------------

describe('confirm and progress', () => {
  it('confirms with the exact hashes, then advances once and waits for acknowledgement', async () => {
    const flow = controller();
    const op = await reviewed(flow);
    node(ok(status(op, 'node_fenced', { progress: null })));
    node(ok(status(op, 'node_fenced', { progress: revocation('unproven') })));
    expect(await flow.confirm(lease)).toBe(true);
    expect(posts()[1]!.url.pathname).toBe(
      `/api/sessions/s1/environment-transitions/previews/${op}/confirm`,
    );
    expect(posts()[1]!.body).toEqual({
      planHash: `plan-${op}`,
      observationHash: `obs-${op}`,
      clientId: 'client-a',
      generation: 7,
    });
    expect(posts()[2]!.url.pathname).toBe(`/api/sessions/s1/environment-transitions/${op}/advance`);
    expect(posts()[2]!.body).toEqual({ clientId: 'client-a', generation: 7 });
    expect(flow.state.phase).toBe('needs_acknowledgement');
    await settle();
    expect(posts()).toHaveLength(3); // no automatic acknowledgement or further advance
  });

  it('refuses confirm while switching is disabled or the review changed', async () => {
    for (const [code, phase] of [
      ['transition_coordinator_unavailable', 'switching_disabled'],
      ['transition_review_changed', 'review_stale'],
      ['stale_environment', 'review_stale'],
      ['lost_control', 'rejected'],
    ] as const) {
      calls = [];
      const flow = controller();
      await reviewed(flow);
      node(fail(409, code));
      await flow.confirm(lease);
      expect(flow.state, code).toMatchObject({ phase, error: { code } });
      expect(posts()).toHaveLength(2);
    }
  });

  it('resolves a lost confirmation by status, re-sending only the same input', async () => {
    const flow = controller();
    const op = await reviewed(flow);
    node('network', fail(404, 'not_found'));
    await flow.confirm(lease);
    expect(flow.state.phase).toBe('confirm_missing');
    expect(calls[2]!.method).toBe('GET');
    expect(calls[2]!.url.pathname).toBe(`/api/sessions/s1/environment-transitions/receipts/${op}`);
    // A changed lease cannot re-send it.
    expect(await flow.resend({ ...lease, generation: 8 })).toBe(false);
    expect(allowedSwitchActions(flow.state, { ...lease, generation: 8 })).toEqual(['discard']);
    node(ok(status(op, 'installed', { revocationConfirmed: true, progress: null })));
    node(ok(environment(binding(2, TARGET))));
    expect(await flow.resend(lease)).toBe(true);
    expect(posts()[2]!.body).toEqual(posts()[1]!.body);
    expect(flow.state.phase).toBe('switched');
  });

  it('adopts an accepted transition found after a lost confirmation reply', async () => {
    const flow = controller({ poll: true });
    const op = await reviewed(flow);
    flow.setLease(lease);
    node(fail(504, 'node_timeout'));
    node(ok(status(op, 'node_fenced')));
    node(ok(status(op, 'node_fenced', { progress: revocation('blocked') })));
    await flow.confirm(lease);
    await settle();
    expect(flow.state.phase).toBe('blocked');
    expect(paths().slice(1)).toEqual([
      `POST /api/sessions/s1/environment-transitions/previews/${op}/confirm`,
      `GET /api/sessions/s1/environment-transitions/receipts/${op}`,
      `POST /api/sessions/s1/environment-transitions/${op}/advance`,
    ]);
  });

  it('polls with backoff while draining, then installs and refreshes the binding', async () => {
    const flow = controller({ poll: true });
    const op = await reviewed(flow);
    const pending = ok(status(op, 'node_fenced', { progress: revocation('pending') }));
    node(ok(status(op, 'node_fenced', { progress: null })));
    node(ok(status(op, 'node_fenced', { progress: null }))); // first advance
    node(pending, pending, pending); // unchanged: slower each time
    node(
      ok(status(op, 'node_fenced', { progress: null, reconciliationState: 'node_unavailable' })),
    );
    node(ok(status(op, 'node_fenced', { progress: revocation('confirmed', 'none', []) })));
    node(ok(status(op, 'installed', { revocationConfirmed: true, progress: null })));
    node(ok(environment(binding(2, TARGET))));
    await flow.confirm(lease);
    await settle();
    expect(flow.state).toMatchObject({ phase: 'switched', result: 'revocation_confirmed' });
    // Unchanged reads slow down; any change starts again at 1 s.
    expect(delays).toEqual([1000, 1000, 2000, 4000, 1000, 1000]);
    expect(changes.some((s) => s.nodeUnavailable)).toBe(true);
    expect(changes.filter((s) => s.phase === 'installing')).not.toHaveLength(0);
    // Every poll was an `advance` (no acknowledgement, no cancel).
    expect(
      posts()
        .slice(2)
        .every((c) => c.url.pathname.endsWith('/advance')),
    ).toBe(true);
    expect(calls[calls.length - 1]!.url.pathname).toBe('/api/sessions/s1/environment');
    expect(flow.state.binding).toEqual(binding(2, TARGET));
    expect(bindings).toEqual([binding(2, TARGET)]);
  });

  it('keeps reading through ambiguous polls and stops on a definite refusal', async () => {
    const flow = controller({ poll: true });
    const op = await reviewed(flow);
    node(ok(status(op, 'node_fenced', { progress: null })));
    node(ok(status(op, 'node_fenced', { progress: revocation('pending') })));
    node(fail(502, 'transition_step_failed'), 'network');
    node(fail(409, 'stale_transition_target'));
    await flow.confirm(lease);
    await settle();
    expect(flow.state).toMatchObject({
      phase: 'draining',
      stalled: true,
      error: { code: 'stale_transition_target' },
    });
    expect(delays).toEqual([1000, 2000, 4000]);
    expect(allowedSwitchActions(flow.state, lease)).toEqual(['refresh', 'cancel']);
    // Refresh resumes.
    node(ok(status(op, 'released')));
    await flow.refresh(lease);
    expect(flow.state).toMatchObject({ phase: 'cancelled', result: 'original_kept' });
  });

  for (const code of PASSED_THROUGH)
    it(`passes ${code} through by code`, async () => {
      const flow = controller();
      node(ok(environment(binding(1), { operationId: 'o1', state: 'node_fenced' })));
      flow.setLease(lease);
      node(
        fail(code.startsWith('transition_step') || code.startsWith('invalid') ? 502 : 409, code),
      );
      await flow.discover();
      expect(flow.state.error?.code).toBe(code);
      expect(flow.state.stalled).toBe(true);
      expect(posts().every((c) => c.url.pathname.endsWith('/advance'))).toBe(true);
    });
});

// ---- reload discovery -------------------------------------------------------------

describe('reload discovery', () => {
  it('rediscovers an active transition through activeTransition and advances it with control', async () => {
    const flow = controller();
    flow.setLease(lease);
    node(
      ok(
        environment(binding(1), {
          operationId: 'op-x',
          state: 'node_fenced',
          revocationConfirmed: false,
          targetInstalled: false,
        }),
      ),
    );
    node(ok(status('op-x', 'node_fenced', { progress: revocation('unproven', 'd1', items, 3) })));
    await flow.discover();
    expect(flow.state).toMatchObject({ phase: 'needs_acknowledgement', operationId: 'op-x' });
    expect(flow.state.status?.progress?.revocation?.itemsTotal).toBe(3);
    expect(paths()).toEqual([
      'GET /api/sessions/s1/environment',
      'POST /api/sessions/s1/environment-transitions/op-x/advance',
    ]);
  });

  it('only reads without control, and keeps reading without advancing', async () => {
    const flow = controller({ poll: true });
    node(ok(environment(binding(1), { operationId: 'op-x', state: 'outcome_unknown' })));
    node(ok(status('op-x', 'outcome_unknown')));
    node(ok(status('op-x', 'node_fenced')));
    node(ok(status('op-x', 'installed', { revocationConfirmed: false })));
    node(ok(environment(binding(2, TARGET))));
    await flow.discover();
    await settle();
    expect(flow.state).toMatchObject({
      phase: 'switched',
      result: 'revocation_not_fully_confirmed',
    });
    expect(posts()).toHaveLength(0);
    expect(bindings).toEqual([binding(2, TARGET)]);
  });

  it('stays idle without an active transition and shows a fence without acceptance', async () => {
    const flow = controller();
    node(ok(environment(binding(1))));
    await flow.discover();
    expect(flow.state.phase).toBe('idle');
    expect(calls).toHaveLength(1);
    node(ok(environment(binding(1), { operationId: 'legacy', state: 'fenced' })));
    await flow.discover();
    expect(flow.state).toMatchObject({ phase: 'legacy_fence', operationId: 'legacy' });
    expect(calls).toHaveLength(2);
  });
});

// ---- acknowledgement --------------------------------------------------------------

describe('acknowledgement', () => {
  async function unproven(flow: EnvironmentSwitch, digest = 'digest-1') {
    flow.setLease(lease);
    node(ok(environment(binding(1), { operationId: 'op', state: 'node_fenced' })));
    node(ok(status('op', 'node_fenced', { progress: revocation('unproven', digest) })));
    await flow.discover();
    expect(flow.state.phase).toBe('needs_acknowledgement');
  }

  it('acknowledges exactly the digest shown and reports a not fully confirmed switch', async () => {
    const flow = controller();
    await unproven(flow);
    node(ok(status('op', 'installed', { revocationConfirmed: false, progress: null })));
    node(ok(environment(binding(2, TARGET))));
    expect(await flow.acknowledge(lease)).toBe(true);
    const sent = posts().find((c) => c.url.pathname.endsWith('/acknowledge'))!;
    expect(sent.url.pathname).toBe('/api/sessions/s1/environment-transitions/op/acknowledge');
    expect(sent.body).toEqual({ digest: 'digest-1', clientId: 'client-a', generation: 7 });
    expect(flow.state).toMatchObject({
      phase: 'switched',
      result: 'revocation_not_fully_confirmed',
      binding: binding(2, TARGET),
    });
  });

  it('re-reads on a changed digest, shows the new items and never re-acknowledges by itself', async () => {
    const flow = controller();
    await unproven(flow);
    const more = [
      ...items,
      { kind: 'legacy_history', reason: 'untracked_launch', acknowledgeable: true },
    ];
    node(fail(409, 'revocation_digest_changed'));
    node(ok(status('op', 'node_fenced', { progress: revocation('unproven', 'digest-2', more) })));
    await flow.acknowledge(lease);
    await settle();
    expect(flow.state).toMatchObject({
      phase: 'needs_acknowledgement',
      digestChanged: true,
      error: { code: 'revocation_digest_changed' },
    });
    expect(flow.state.status?.progress?.revocation?.items).toHaveLength(3);
    expect(posts().filter((c) => c.url.pathname.endsWith('/acknowledge'))).toHaveLength(1);
    // The user acknowledges again: the new digest.
    node(ok(status('op', 'installed', { revocationConfirmed: false })));
    node(ok(environment(binding(2, TARGET))));
    await flow.acknowledge(lease);
    expect(
      posts()
        .filter((c) => c.url.pathname.endsWith('/acknowledge'))
        .map((c) => c.body!.digest),
    ).toEqual(['digest-1', 'digest-2']);
  });

  it('offers nothing to acknowledge for blocked evidence', async () => {
    const flow = controller();
    flow.setLease(lease);
    node(ok(environment(binding(1), { operationId: 'op', state: 'node_fenced' })));
    const blocking = [{ kind: 'browser', reason: 'unresolved', acknowledgeable: false }];
    node(ok(status('op', 'node_fenced', { progress: revocation('blocked', 'b', blocking) })));
    await flow.discover();
    expect(flow.state.phase).toBe('blocked');
    expect(allowedSwitchActions(flow.state, lease)).not.toContain('acknowledge');
    expect(await flow.acknowledge(lease)).toBe(false);
    expect(posts().filter((c) => c.url.pathname.endsWith('/acknowledge'))).toHaveLength(0);
  });

  it('resolves an ambiguous acknowledgement by advance, not a second acknowledgement', async () => {
    const flow = controller();
    await unproven(flow);
    node('network');
    node(ok(status('op', 'installed', { revocationConfirmed: false })));
    node(ok(environment(binding(2, TARGET))));
    await flow.acknowledge(lease);
    expect(flow.state.phase).toBe('switched');
    expect(posts().map((c) => c.url.pathname.split('/').pop())).toEqual([
      'advance',
      'acknowledge',
      'advance',
    ]);
  });

  it('re-reads read-only after losing control', async () => {
    const flow = controller();
    await unproven(flow);
    node(fail(409, 'lost_control'));
    node(ok(status('op', 'node_fenced')));
    await flow.acknowledge(lease);
    expect(flow.state).toMatchObject({
      phase: 'needs_acknowledgement',
      error: { code: 'lost_control' },
    });
    expect(calls[calls.length - 1]!.method).toBe('GET');
  });
});

// ---- cancel -----------------------------------------------------------------------

describe('cancel', () => {
  it('cancels before the fence and keeps the original workspace', async () => {
    const flow = controller();
    flow.setLease(lease);
    node(ok(environment(binding(1), { operationId: 'op', state: 'accepted' })));
    node(ok(status('op', 'accepted')));
    await flow.discover();
    expect(flow.state.phase).toBe('awaiting_dispatch');
    node(ok(status('op', 'released')));
    expect(await flow.cancel(lease)).toBe(true);
    expect(posts()[posts().length - 1]!.url.pathname).toBe(
      '/api/sessions/s1/environment-transitions/op/cancel',
    );
    expect(posts()[posts().length - 1]!.body).toEqual({ clientId: 'client-a', generation: 7 });
    expect(flow.state).toMatchObject({ phase: 'cancelled', result: 'original_kept' });
    expect(bindings).toEqual([]);
  });

  it('cancels after the fence, while waiting for acknowledgement', async () => {
    const flow = controller();
    flow.setLease(lease);
    node(ok(environment(binding(1), { operationId: 'op', state: 'node_fenced' })));
    node(ok(status('op', 'node_fenced', { progress: revocation('unproven') })));
    await flow.discover();
    node(ok(status('op', 'released')));
    await flow.cancel(lease);
    expect(flow.state).toMatchObject({ phase: 'cancelled', result: 'original_kept' });
  });

  it('is too late after installation', async () => {
    const flow = controller();
    flow.setLease(lease);
    node(ok(environment(binding(1), { operationId: 'op', state: 'node_fenced' })));
    node(ok(status('op', 'node_fenced', { progress: revocation('unproven') })));
    await flow.discover();
    node(fail(409, 'transition_installed'));
    node(ok(status('op', 'installed', { revocationConfirmed: false })));
    node(ok(environment(binding(2, TARGET))));
    await flow.cancel(lease);
    expect(flow.state).toMatchObject({
      phase: 'switched',
      result: 'revocation_not_fully_confirmed',
      error: { code: 'transition_installed' },
    });
    expect(calls[calls.length - 2]!.method).toBe('GET'); // read, never advanced past the cancel
    expect(allowedSwitchActions(flow.state, lease)).not.toContain('cancel');
  });

  it('keeps later reads read-only after an undecided or refused cancel', async () => {
    const flow = controller();
    flow.setLease(lease);
    node(ok(environment(binding(1), { operationId: 'op', state: 'node_fenced' })));
    node(ok(status('op', 'node_fenced', { progress: revocation('pending') })));
    await flow.discover();
    node(fail(409, 'transition_draining'));
    node(ok(status('op', 'node_fenced')));
    await flow.cancel(lease);
    await settle();
    expect(flow.state).toMatchObject({
      phase: 'draining',
      cancelRequested: true,
      error: { code: 'transition_draining' },
    });
    // Ambiguous cancel: a GET, never an advance that could install.
    node('network');
    node(ok(status('op', 'released')));
    await flow.cancel(lease);
    expect(flow.state.phase).toBe('cancelled');
    expect(
      posts()
        .slice(1)
        .map((c) => c.url.pathname.split('/').pop()),
    ).toEqual(['cancel', 'cancel']);
  });
});

it('reads the environment through the existing parser', async () => {
  node(ok(environment(binding(3), { operationId: 'o', state: 'node_fenced' })));
  const read = await environmentTransitionApi.environment('s1');
  expect(read.environment.binding).toEqual(binding(3));
  expect(read.activeTransition).toEqual({ operationId: 'o', state: 'node_fenced' });
});
