import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
  allowedSwitchActions,
  backoff,
  CANCEL_PENDING_LABELS,
  classifySwitchFailure,
  needsReauthorization,
  parseActiveTransition,
  parsePreview,
  parseSummary,
  READINESS_LABELS,
  readinessOf,
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
    // An older Gateway's shape parses with C2 defaults.
    expect(parsed.progress?.revocation).toEqual({
      status: 'unproven',
      digest: 'd',
      evaluationId: null,
      itemsTotal: 140,
      confirmsContainment: false,
      items: items.map((item) => ({ ...item, inherited: false, generation: null })),
      currentGeneration: null,
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
            operationAuthority: { available: false, durationSeconds: null },
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
      [at('reconciliation_required'), ['reconcile'], ['reconcile']],
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
    for (const code of [
      'preview_not_found',
      'acceptance_not_found',
      'receipt_not_found',
      'conversation_not_found',
    ])
      expect(c(404, code), code).toBe('not_found');
    // Any other 404 (generic, evaluation, older Gateways) is a definite refusal.
    expect(c(404, 'not_found')).toBe('rejected');
    expect(c(404, 'evaluation_not_found')).toBe('rejected');
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
    node('network', fail(404, 'preview_not_found'));
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
    node('network', fail(404, 'receipt_not_found'));
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
    expect(flow.state).toMatchObject({
      phase: 'reconciliation_required',
      operationId: 'legacy',
    });
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
  expect(read.activeTransition).toEqual({
    operationId: 'o',
    state: 'node_fenced',
    targetWorkspaceId: null,
    recoveryReason: null,
    safeActions: [],
  });
  expect(read.lastFinishedTransition).toBeNull();
});

// ---- C1–C4 contracts (Gateway 1032) -----------------------------------------------

const authority = (state: string, revision = 1, extra: Record<string, unknown> = {}) => ({
  revision,
  deadlineAt: 5000,
  state,
  reauthorizationRequired: state !== 'active',
  ...extra,
});
const inheritedItems = [
  {
    kind: 'host_command',
    reason: 'host_effects_may_survive',
    acknowledgeable: true,
    inherited: true,
    generation: 1,
  },
  {
    kind: 'legacy_history',
    reason: 'launches_before_journals',
    acknowledgeable: true,
    inherited: true,
    generation: null,
  },
  {
    kind: 'platform_containment',
    reason: 'descendants_not_contained',
    acknowledgeable: true,
    inherited: false,
    generation: 2,
  },
];
const evaluated = (
  status: string,
  evaluationId = 'ev-aaaa',
  extra: { digest?: string; itemsTotal?: number; list?: unknown[]; current?: unknown } = {},
) => ({
  ...revocation(status),
  observedAt: 1234,
  revocation: {
    status,
    digest: extra.digest ?? `digest-${evaluationId}`,
    evaluationId,
    itemsTotal: extra.itemsTotal ?? 140,
    confirmsContainment: false,
    items: extra.list ?? inheritedItems,
    currentGeneration: extra.current ?? { status: 'confirmed', itemsTotal: 0 },
  },
});
/** A Gateway 1032 status: progress, authority and cancellation are always present. */
const full = (
  operationId: string,
  state: string,
  extra: {
    progress?: unknown;
    authority?: unknown;
    cancellation?: unknown;
    revocationConfirmed?: boolean;
  } = {},
) => ({
  ...status(operationId, state, {
    progress: extra.progress ?? null,
    revocationConfirmed: extra.revocationConfirmed,
  }),
  authority: extra.authority ?? null,
  cancellation: extra.cancellation ?? null,
});
const installed = (runtimeReady: string, confirmed = false) => ({
  state: 'installed',
  errorCode: null,
  revocationConfirmed: confirmed,
  targetInstalled: true,
  revocation: null,
  observedAt: 99,
  cancellation: null,
  installation: {
    revocation: confirmed ? 'confirmed' : 'unproven',
    environmentEvent: 'delivered',
    bindingCommitted: true,
    policyValidated: true,
    runtimeReady,
  },
});
const page = (
  evaluationId: string,
  list: unknown[],
  next: string | null,
  digest = `digest-${evaluationId}`,
) =>
  ok({
    evaluation: { evaluationId, digest, status: 'unproven', itemsTotal: 5, items: list, next },
  });
async function found(
  flow: EnvironmentSwitch,
  reply: unknown,
  active: Record<string, unknown> = { operationId: 'op', state: 'node_fenced' },
  ...then: Reply[]
) {
  node(ok(environment(binding(1), active)));
  node(ok(reply));
  node(...then);
  await flow.discover();
}

describe('G1–G5 read model', () => {
  it('reads the complete read model without control, never advancing', async () => {
    const flow = controller();
    await found(
      flow,
      full('op', 'node_fenced', {
        progress: evaluated('unproven'),
        authority: authority('active'),
      }),
    );
    expect(paths()).toEqual([
      'GET /api/sessions/s1/environment',
      'GET /api/sessions/s1/environment-transitions/receipts/op',
    ]);
    expect(flow.state.phase).toBe('needs_acknowledgement');
    expect(flow.state.status?.progress?.observedAt).toBe(1234);
    expect(flow.state.status?.authority).toEqual(authority('active'));
    expect(flow.state.status?.cancellation).toBeNull();
    expect(allowedSwitchActions(flow.state, undefined)).toEqual(['more_items', 'refresh']);
  });

  it('finds the last finished transition and the target of an active one', async () => {
    const flow = controller();
    const last = {
      operationId: 'done',
      state: 'installed',
      createdAt: 7,
      targetWorkspaceId: TARGET,
      targetInstalled: true,
      revocationConfirmed: true,
    };
    node(ok({ ...environment(binding(2, TARGET)), lastFinishedTransition: last }));
    await flow.discover();
    expect(flow.state).toMatchObject({ phase: 'idle', lastFinished: last });
    const read = parseActiveTransition({
      operationId: 'op',
      state: 'node_fenced',
      targetWorkspaceId: TARGET,
    });
    expect(read?.targetWorkspaceId).toBe(TARGET);
    // A summary never claims confirmed revocation for a released switch.
    expect(
      parseSummary({ ...last, state: 'released', revocationConfirmed: true })?.revocationConfirmed,
    ).toBe(false);
  });

  it('offers only reconcile for a bare Node fence, and never advances it', async () => {
    const flow = controller();
    flow.setLease(lease);
    const bare = {
      operationId: 'bare',
      state: 'reconciliation_required',
      targetWorkspaceId: TARGET,
      recoveryReason: 'no_gateway_acceptance',
      safeActions: ['reconcile'],
    };
    node(ok(environment(binding(1), bare)));
    await flow.discover();
    expect(flow.state).toMatchObject({
      phase: 'reconciliation_required',
      operationId: 'bare',
      targetWorkspaceId: TARGET,
      recoveryReason: 'no_gateway_acceptance',
    });
    expect(allowedSwitchActions(flow.state, lease)).toEqual(['reconcile']);
    expect(await flow.cancel(lease)).toBe(false);
    node(ok({ state: 'fenced', transition: null, duplicate: false }));
    node(ok(environment(binding(1), bare)));
    expect(await flow.reconcile()).toBe(true);
    const reconcile = calls[1]!;
    expect(`${reconcile.method} ${reconcile.url.pathname}`).toBe(
      'POST /api/sessions/s1/environment-transitions/previews/bare/reconcile',
    );
    expect(reconcile.body).toBeUndefined();
    expect(flow.state).toMatchObject({
      phase: 'reconciliation_required',
      reconciliation: 'fenced',
    });
    expect(paths().some((p) => p.endsWith('/advance'))).toBe(false);
    // An older Gateway's `fenced` is the same condition.
    expect(parseActiveTransition({ operationId: 'x', state: 'fenced' })).toMatchObject({
      state: 'reconciliation_required',
      safeActions: ['reconcile'],
    });
  });

  it('pages the transition history to its end', async () => {
    const summary = (id: string) => ({
      operationId: id,
      state: 'released',
      createdAt: 1,
      targetWorkspaceId: TARGET,
      targetInstalled: false,
      revocationConfirmed: false,
    });
    node(ok({ transitions: { version: 1, items: [summary('b')], next: '2.b' } }));
    node(ok({ transitions: { version: 1, items: [], next: null } }));
    const first = await environmentTransitionApi.history('s1', { limit: 1 });
    const second = await environmentTransitionApi.history('s1', { cursor: first.next!, limit: 1 });
    expect(first.items.map((i) => i.operationId)).toEqual(['b']);
    expect(second).toEqual({ items: [], next: null });
    expect(calls.map((c) => `${c.url.pathname}${c.url.search}`)).toEqual([
      '/api/sessions/s1/environment-transitions?limit=1',
      '/api/sessions/s1/environment-transitions?cursor=2.b&limit=1',
    ]);
  });

  it('offers only cancel for an acceptance that needs review again', async () => {
    const flow = controller();
    flow.setLease(lease);
    const progress = {
      stage: 'review_required',
      waitReason: 'lost_control',
      safeActions: ['cancel'],
      revocationConfirmed: false,
      targetInstalled: false,
      observedAt: 5,
    };
    await found(flow, full('op', 'accepted', { progress }), {
      operationId: 'op',
      state: 'accepted',
    });
    expect(flow.state.phase).toBe('review_required');
    expect(flow.state.status?.progress).toMatchObject({
      stage: 'review_required',
      waitReason: 'lost_control',
      safeActions: ['cancel'],
    });
    expect(allowedSwitchActions(flow.state, lease)).toEqual(['cancel', 'refresh']);
    expect(allowedSwitchActions(flow.state, undefined)).toEqual(['refresh']);
    node(ok(full('op', 'released', { cancellation: { requestedAt: 9 } })));
    await flow.cancel(lease);
    expect(flow.state).toMatchObject({ phase: 'cancelled', result: 'original_kept' });
  });

  it('treats only the specific missing-object codes as not stored', async () => {
    const flow = controller();
    node('network', fail(404, 'not_found'));
    await flow.preview(TARGET, binding(1));
    // A generic 404 is not proof of absence: no same-identity resend.
    expect(flow.state.phase).toBe('preview_unknown');
    expect(allowedSwitchActions(flow.state, lease)).toEqual(['refresh']);
  });
});

describe('C1 operation authority', () => {
  it('shows the operation authority offer before confirmation', async () => {
    const flow = controller();
    node((call) =>
      ok({
        ...preview(call.body!.operationId),
        operationAuthority: { available: true, durationSeconds: 600 },
      }),
    );
    await flow.preview(TARGET, binding(1));
    expect(flow.state.preview?.operationAuthority).toEqual({
      available: true,
      durationSeconds: 600,
    });
    expect(parsePreview(preview('o')).operationAuthority).toEqual({
      available: false,
      durationSeconds: null,
    });
  });

  it('asks for reauthorization after expiry, only with control, then installs', async () => {
    const flow = controller();
    flow.setLease(lease);
    await found(
      flow,
      full('op', 'node_fenced', {
        progress: evaluated('confirmed', 'ev-c', { list: [], itemsTotal: 0 }),
        authority: authority('expired'),
      }),
    );
    expect(flow.state.phase).toBe('authority_required');
    expect(needsReauthorization(flow.state)).toBe(true);
    expect(allowedSwitchActions(flow.state, lease)).toEqual(['reauthorize', 'refresh', 'cancel']);
    expect(allowedSwitchActions(flow.state, undefined)).toEqual(['refresh']);
    expect(await flow.reauthorize({ ...lease, sessionId: 'other' })).toBe(false);
    node(
      ok(
        full('op', 'installed', {
          progress: installed('not_started', true),
          authority: authority('active', 2),
          revocationConfirmed: true,
        }),
      ),
    );
    node(ok(environment(binding(2, TARGET))));
    expect(await flow.reauthorize(lease)).toBe(true);
    const sent = posts()[1]!;
    expect(sent.url.pathname).toBe('/api/sessions/s1/environment-transitions/op/reauthorize');
    expect(sent.body).toEqual({ clientId: 'client-a', generation: 7 });
    expect(flow.state).toMatchObject({ phase: 'switched', result: 'revocation_confirmed' });
    expect(flow.state.status?.authority?.revision).toBe(2);
  });

  it('offers reauthorization beside acknowledgement while consent is still needed', async () => {
    const flow = controller();
    flow.setLease(lease);
    await found(
      flow,
      full('op', 'node_fenced', {
        progress: evaluated('unproven'),
        authority: authority('clock_uncertain', 1, { reauthorizationRequired: undefined }),
      }),
    );
    expect(flow.state.status?.authority?.reauthorizationRequired).toBe(true);
    expect(allowedSwitchActions(flow.state, lease)).toEqual([
      'more_items',
      'acknowledge',
      'reauthorize',
      'refresh',
      'cancel',
    ]);
  });

  it('explains a changed plan and passes authority codes through', async () => {
    const flow = controller();
    flow.setLease(lease);
    const expired = full('op', 'node_fenced', {
      progress: evaluated('confirmed', 'ev-c', { list: [], itemsTotal: 0 }),
      authority: authority('expired'),
    });
    await found(flow, expired);
    node(fail(409, 'plan_changed'), ok(expired));
    await flow.reauthorize(lease);
    expect(flow.state).toMatchObject({
      phase: 'authority_required',
      stalled: true,
      error: { code: 'plan_changed', reason: 'plan_changed' },
    });
    node(fail(409, 'operation_authority_unavailable'), ok(expired));
    await flow.reauthorize(lease);
    expect(flow.state.error).toMatchObject({
      code: 'operation_authority_unavailable',
      reason: 'authority_unavailable',
    });
    for (const code of [
      'operation_authority_missing',
      'operation_authority_superseded',
      'operation_authority_revoked',
      'operation_authority_expired',
      'operation_authority_clock_uncertain',
      'operation_authority_revision',
      'operation_authority_invalid',
    ])
      expect(classifySwitchFailure(new ApiError(code, 409, code)), code).toBe('authority');
    expect(classifySwitchFailure(new ApiError('x', 409, 'transition_ended'))).toBe('rejected');
  });

  it('needs no reauthorization once the transition ended', () => {
    const state: SwitchState = {
      phase: 'switched',
      status: parseStatus(full('op', 'installed', { authority: authority('expired') })),
    };
    expect(needsReauthorization(state)).toBe(false);
  });
});

describe('C2 inherited risk and evaluation pages', () => {
  it('parses both statuses and inherited items', () => {
    const parsed = parseStatus(full('op', 'node_fenced', { progress: evaluated('unproven') }));
    const rev = parsed.progress?.revocation;
    expect(rev).toMatchObject({
      status: 'unproven',
      evaluationId: 'ev-aaaa',
      itemsTotal: 140,
      currentGeneration: { status: 'confirmed', itemsTotal: 0 },
    });
    expect(rev?.items.map((i) => [i.inherited, i.generation])).toEqual([
      [true, 1],
      [true, null],
      [false, 2],
    ]);
  });

  it('pages one immutable snapshot to its end', async () => {
    const flow = controller();
    await found(
      flow,
      full('op', 'node_fenced', { progress: evaluated('unproven', 'ev-a', { itemsTotal: 5 }) }),
    );
    node(page('ev-a', inheritedItems.slice(0, 2), 'c1'));
    node(page('ev-a', inheritedItems.slice(2), 'c2'));
    node(page('ev-a', [inheritedItems[0], inheritedItems[1]], null));
    await flow.loadAllItems(2);
    expect(calls.slice(2).map((c) => `${c.url.pathname}${c.url.search}`)).toEqual([
      '/api/sessions/s1/environment-transitions/op/evaluations/ev-a?limit=2',
      '/api/sessions/s1/environment-transitions/op/evaluations/ev-a?cursor=c1&limit=2',
      '/api/sessions/s1/environment-transitions/op/evaluations/ev-a?cursor=c2&limit=2',
    ]);
    expect(flow.state.evaluation).toMatchObject({
      evaluationId: 'ev-a',
      complete: true,
      next: null,
    });
    expect(flow.state.evaluation?.items).toHaveLength(5);
    expect(allowedSwitchActions(flow.state, undefined)).toEqual(['refresh']);
    expect(await flow.loadMoreItems()).toBe(false);
  });

  it('drops pages when the evaluation changes while paging', async () => {
    const flow = controller();
    await found(
      flow,
      full('op', 'node_fenced', { progress: evaluated('unproven', 'ev-a', { itemsTotal: 5 }) }),
    );
    node(page('ev-a', inheritedItems.slice(0, 2), 'c1'));
    await flow.loadMoreItems(2);
    expect(flow.state.evaluation?.items).toHaveLength(2);
    // A new risk appeared: the receipt now names another snapshot.
    node(
      ok(full('op', 'node_fenced', { progress: evaluated('unproven', 'ev-b', { itemsTotal: 6 }) })),
    );
    await flow.refresh();
    expect(flow.state.evaluation).toBeUndefined();
    expect(flow.state.digestChanged).toBe(true);
    node(page('ev-b', inheritedItems, null));
    await flow.loadMoreItems();
    expect(calls[calls.length - 1]!.url.pathname).toBe(
      '/api/sessions/s1/environment-transitions/op/evaluations/ev-b',
    );
    expect(calls[calls.length - 1]!.url.search).toBe('');
    expect(flow.state.evaluation).toMatchObject({ evaluationId: 'ev-b', complete: true });
  });

  it('refuses pages that do not form one snapshot, and reports a missing evaluation', async () => {
    const flow = controller();
    await found(
      flow,
      full('op', 'node_fenced', { progress: evaluated('unproven', 'ev-a', { itemsTotal: 5 }) }),
    );
    node(page('ev-a', inheritedItems.slice(0, 1), 'c1'));
    node(page('ev-a', inheritedItems.slice(1, 2), 'c2', 'other-digest'));
    await flow.loadMoreItems(1);
    await flow.loadMoreItems(1);
    expect(flow.state.error?.message).toMatch(/one snapshot/);
    expect(flow.state.evaluation?.items).toHaveLength(1);
    const other = controller();
    await found(other, full('op', 'node_fenced', { progress: evaluated('unproven', 'ev-a') }));
    node(fail(404, 'evaluation_not_found'));
    await other.loadMoreItems();
    expect(other.state.error).toMatchObject({ code: 'evaluation_not_found', reason: 'rejected' });
  });

  it('acknowledges all N items of the snapshot with its evaluation identity', async () => {
    const flow = controller();
    flow.setLease(lease);
    await found(flow, full('op', 'node_fenced', { progress: evaluated('unproven', 'ev-a') }));
    // Only 3 of 140 items are shown; the consent still names the whole snapshot.
    expect(flow.state.status?.progress?.revocation?.items).toHaveLength(3);
    node(ok(full('op', 'installed', { progress: installed('not_started') })));
    node(ok(environment(binding(2, TARGET))));
    await flow.acknowledge(lease);
    const sent = posts().find((c) => c.url.pathname.endsWith('/acknowledge'))!;
    expect(sent.body).toEqual({
      digest: 'digest-ev-a',
      evaluationId: 'ev-a',
      clientId: 'client-a',
      generation: 7,
    });
  });

  it('shows the new evaluation after a digest change and never re-acknowledges', async () => {
    const flow = controller();
    flow.setLease(lease);
    await found(flow, full('op', 'node_fenced', { progress: evaluated('unproven', 'ev-a') }));
    node(page('ev-a', inheritedItems, 'c1'));
    await flow.loadMoreItems();
    node(fail(409, 'revocation_digest_changed'));
    node(
      ok(
        full('op', 'node_fenced', { progress: evaluated('unproven', 'ev-b', { itemsTotal: 141 }) }),
      ),
    );
    await flow.acknowledge(lease);
    expect(flow.state).toMatchObject({ phase: 'needs_acknowledgement', digestChanged: true });
    expect(flow.state.status?.progress?.revocation).toMatchObject({
      evaluationId: 'ev-b',
      itemsTotal: 141,
    });
    expect(flow.state.evaluation).toBeUndefined();
    expect(posts().filter((c) => c.url.pathname.endsWith('/acknowledge'))).toHaveLength(1);
  });
});

describe('C3 cancellation and readiness', () => {
  it('keeps polling a pending cancellation through its reasons and never offers install-side actions', async () => {
    const flow = controller({ poll: true });
    flow.setLease(lease);
    await found(
      flow,
      full('op', 'node_fenced', {
        progress: evaluated('unproven'),
        authority: authority('expired'),
      }),
    );
    const pending = (reason: string) =>
      ok(
        full('op', 'node_fenced', {
          progress: {
            ...evaluated('unproven'),
            cancellation: { requestedAt: 50, pendingReason: reason },
          },
          authority: authority('expired'),
          cancellation: { requestedAt: 50 },
        }),
      );
    node(pending('drain_active'));
    node(
      pending('drain_active'),
      pending('resources_unresolved'),
      pending('original_binding_invalid'),
    );
    node(ok(full('op', 'released', { cancellation: { requestedAt: 50 } })));
    await flow.cancel(lease);
    await settle();
    // The first reply is the pending cancellation itself.
    expect(changes.some((s) => s.phase === 'cancel_pending')).toBe(true);
    const seen = changes
      .filter((s) => s.phase === 'cancel_pending')
      .map((s) => s.status?.progress?.cancellation?.pendingReason);
    expect(seen).toContain('drain_active');
    expect(seen).toContain('resources_unresolved');
    expect(seen).toContain('original_binding_invalid');
    const pendingState = changes.find((s) => s.phase === 'cancel_pending')!;
    expect(allowedSwitchActions(pendingState, lease)).toEqual(['refresh']);
    expect(needsReauthorization(pendingState)).toBe(false);
    expect(flow.state).toMatchObject({ phase: 'cancelled', result: 'original_kept' });
    // A recorded cancellation polls through `advance` (the Gateway then only drains).
    expect(posts().map((c) => c.url.pathname.split('/').pop())).toEqual([
      'advance', // discovery
      'cancel',
      'advance',
      'advance',
      'advance',
      'advance',
    ]);
    for (const reason of ['drain_active', 'resources_unresolved', 'original_binding_invalid'])
      expect(CANCEL_PENDING_LABELS[reason]).toBeTruthy();
  });

  it('shows a pending cancellation to a device without control', async () => {
    const flow = controller();
    await found(
      flow,
      full('op', 'node_fenced', {
        progress: {
          ...evaluated('blocked'),
          cancellation: { requestedAt: 1, pendingReason: 'resources_unresolved' },
        },
        cancellation: { requestedAt: 1 },
      }),
    );
    expect(flow.state.phase).toBe('cancel_pending');
    expect(flow.state.status?.cancellation).toEqual({ requestedAt: 1 });
    expect(classifySwitchFailure(new ApiError('x', 409, 'transition_cancel_requested'))).toBe(
      'cancel_requested',
    );
  });

  it('reports readiness separately and refreshes it after installation', async () => {
    const flow = controller();
    flow.setLease(lease);
    await found(
      flow,
      full('op', 'installed', { progress: installed('not_started') }),
      { operationId: 'op', state: 'node_fenced' },
      ok(environment(binding(2, TARGET))),
    );
    expect(flow.state).toMatchObject({
      phase: 'switched',
      result: 'revocation_not_fully_confirmed',
    });
    expect(readinessOf(flow.state.status)).toBe('not_started');
    expect(flow.state.status?.progress?.installation).toMatchObject({
      bindingCommitted: true,
      policyValidated: true,
    });
    expect(allowedSwitchActions(flow.state, lease)).toEqual(['refresh', 'discard']);
    node(ok(full('op', 'installed', { progress: installed('failed') })));
    await flow.refresh(lease);
    expect(readinessOf(flow.state.status)).toBe('failed');
    expect(posts()[posts().length - 1]!.url.pathname).toMatch(/\/advance$/);
    node(ok(full('op', 'installed', { progress: installed('ready') })));
    await flow.refresh(lease);
    expect(readinessOf(flow.state.status)).toBe('ready');
    expect(allowedSwitchActions(flow.state, lease)).toEqual(['discard']);
    // The binding was adopted once, not on every refresh.
    expect(bindings).toEqual([binding(2, TARGET)]);
    for (const value of ['not_started', 'ready', 'failed', 'unknown'])
      expect(READINESS_LABELS[value]).toBeTruthy();
  });

  it('reads readiness without control through the receipt', async () => {
    const flow = controller();
    await found(
      flow,
      full('op', 'installed', { progress: installed('unknown') }),
      { operationId: 'op', state: 'node_fenced' },
      ok(environment(binding(2, TARGET))),
    );
    node(ok(full('op', 'installed', { progress: installed('ready') })));
    await flow.refresh();
    expect(readinessOf(flow.state.status)).toBe('ready');
    expect(posts()).toHaveLength(0);
  });
});

describe('F1 cancelling a switch whose Node outcome is unknown', () => {
  const cancelling = (state: 'pending' | 'voided', extra: Record<string, unknown> = {}) => ({
    ...status('op', state === 'voided' ? 'released' : 'outcome_unknown', extra),
    cancellation: {
      requestedAt: 5,
      void: { state, requestedAt: 5, answeredAt: state === 'voided' ? 9 : null, nodeId: 'node' },
    },
  });
  const unknown = (progress?: unknown) =>
    status('op', 'outcome_unknown', progress ? { progress } : {});

  it('offers Cancel for an unknown outcome, with control only', () => {
    const state: SwitchState = {
      phase: 'outcome_unknown',
      operationId: 'op',
      status: parseStatus(unknown())!,
    };
    expect(allowedSwitchActions(state, lease)).toContain('cancel');
    expect(allowedSwitchActions(state, undefined)).toEqual(['refresh']);
  });

  it('parses the void request and its receipt, and ignores a malformed one', () => {
    const pending = parseStatus(cancelling('pending'))!;
    expect(pending.cancellation).toEqual({
      requestedAt: 5,
      void: { state: 'pending', requestedAt: 5, answeredAt: null },
    });
    expect(transitionPhase(pending)).toBe('cancel_pending');
    const voided = parseStatus(cancelling('voided'))!;
    expect(voided.cancellation?.void).toEqual({ state: 'voided', requestedAt: 5, answeredAt: 9 });
    expect(transitionPhase(voided)).toBe('cancelled');
    expect(resultOf(voided)).toBe('cancelled_unchanged');
    const bad = parseStatus({
      ...cancelling('pending'),
      cancellation: { requestedAt: 5, void: { state: 'maybe', requestedAt: 5 } },
    })!;
    expect(bad.cancellation).toEqual({ requestedAt: 5 });
    // A release that did not come from a void is the ordinary result.
    expect(resultOf(parseStatus(status('op', 'released'))!)).toBe('original_kept');
    expect(
      resultOf(parseStatus({ ...status('op', 'released'), cancellation: { requestedAt: 5 } })!),
    ).toBe('original_kept');
  });

  it('shows the wait hints the Gateway records, as hints only', () => {
    const hinted = parseStatus(
      unknown({
        stage: 'outcome_unknown',
        waitReason: 'receipt_unavailable',
        safeActions: ['cancel'],
      }),
    )!;
    expect(hinted.progress?.waitReason).toBe('receipt_unavailable');
    expect(transitionPhase(hinted)).toBe('outcome_unknown');
  });

  it('cancels, waits for the Node while the void is pending, then reports nothing changed', async () => {
    const flow = controller();
    flow.setLease(lease);
    node(ok(environment(binding(1), { operationId: 'op', state: 'outcome_unknown' })));
    node(ok(unknown()));
    await flow.discover();
    expect(flow.state.phase).toBe('outcome_unknown');
    node(ok({ ...cancelling('pending'), reconciliationState: 'node_unavailable' }));
    node(ok(cancelling('voided')));
    expect(await flow.cancel(lease)).toBe(true);
    expect(posts()[posts().length - 1]!.url.pathname).toBe(
      '/api/sessions/s1/environment-transitions/op/cancel',
    );
    expect(flow.state.phase).toBe('cancel_pending');
    expect(flow.state.nodeUnavailable).toBe(true);
    // Nothing but a refresh while it waits; the conversation stays locked.
    expect(allowedSwitchActions(flow.state, lease)).toEqual(['refresh']);
    await flow.refresh(lease);
    expect(flow.state).toMatchObject({ phase: 'cancelled', result: 'cancelled_unchanged' });
    expect(bindings).toEqual([]);
  });

  it('tells the user a Node that cannot void must be upgraded, and lets them ask again', async () => {
    expect(PASSED_THROUGH).toContain('transition_void_unsupported');
    expect(classifySwitchFailure(new ApiError('x', 409, 'transition_void_unsupported'))).toBe(
      'void_unsupported',
    );
    const flow = controller();
    flow.setLease(lease);
    node(ok(environment(binding(1), { operationId: 'op', state: 'outcome_unknown' })));
    node(ok(unknown()));
    await flow.discover();
    node(fail(409, 'transition_void_unsupported'));
    node(ok(unknown())); // state unchanged
    expect(await flow.cancel(lease)).toBe(true);
    expect(flow.state).toMatchObject({
      phase: 'outcome_unknown',
      error: { code: 'transition_void_unsupported', reason: 'void_unsupported' },
      cancelRequested: false,
    });
    expect(allowedSwitchActions(flow.state, lease)).toContain('cancel');
    // After the Node is upgraded the same Cancel works.
    node(ok(cancelling('voided')));
    await flow.cancel(lease);
    expect(flow.state).toMatchObject({ phase: 'cancelled', result: 'cancelled_unchanged' });
  });
});
