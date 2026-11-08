// @vitest-environment jsdom
import { flushSync, mount, unmount } from 'svelte';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { app } from '../../app.svelte';
import { i18n } from '../../i18n.svelte';
import EnvironmentSwitchPanel from './EnvironmentSwitchPanel.svelte';

const binding = (generation: number, workspace: string) => ({
  version: 1,
  membership: { revision: generation, legacyWorkspaceId: workspace },
  execution: { generation, workspaceId: workspace, nodeId: 'node', modeId: 'research' },
});
const environment = (b: ReturnType<typeof binding>, activeTransition: unknown = null) => ({
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
const fenced = (progress: unknown, state = 'node_fenced', revocationConfirmed = false) => ({
  transition: {
    operationId: 'op',
    sessionId: 's1',
    state,
    createdAt: 1,
    revocationConfirmed,
    targetInstalled: state === 'installed',
  },
  canConfirm: false,
  progress,
});
const unproven = {
  state: 'supervisor_drained',
  errorCode: null,
  revocationConfirmed: false,
  targetInstalled: false,
  revocation: {
    status: 'unproven',
    digest: 'digest-1',
    itemsTotal: 2,
    confirmsContainment: false,
    items: [
      { kind: 'platform_containment', reason: 'descendants_not_contained', acknowledgeable: true },
      { kind: 'host_command', reason: 'host_effects_may_survive', acknowledgeable: true },
    ],
  },
  installation: null,
};

interface Call {
  method: string;
  path: string;
  body: any;
}
let calls: Call[];
let component: ReturnType<typeof mount> | undefined;
let target: HTMLDivElement;
function serve(respond: (call: Call) => unknown) {
  vi.stubGlobal(
    'fetch',
    vi.fn(async (input: string, init: RequestInit = {}) => {
      const call = {
        method: init.method ?? 'GET',
        path: new URL(input, 'http://pirc.test').pathname,
        body: init.body ? JSON.parse(init.body as string) : undefined,
      };
      calls.push(call);
      const reply = respond(call) as { status?: number; body: unknown } | undefined;
      if (!reply) throw new Error(`unscripted ${call.method} ${call.path}`);
      return new Response(JSON.stringify(reply.body), { status: reply.status ?? 200 });
    }),
  );
}
beforeEach(() => {
  calls = [];
  const values = new Map<string, string>([['relay.client-id', 'client-a']]);
  vi.stubGlobal('localStorage', {
    getItem: (key: string) => values.get(key) ?? null,
    setItem: (key: string, value: string) => values.set(key, value),
    removeItem: (key: string) => values.delete(key),
    clear: () => values.clear(),
  });
  app.workspaces = [
    { id: 'node:source', hostId: 'node', displayName: 'Source' },
    { id: 'node:target', hostId: 'node', displayName: 'Target' },
    { id: 'other:x', hostId: 'other', displayName: 'Elsewhere' },
  ] as never;
  app.sessionState = {
    session: { id: 's1', workspaceId: 'node:source', binding: binding(1, 'node:source') },
    control: { heldByCurrentClient: true, generation: 5 },
  } as never;
  target = document.createElement('div');
  document.body.append(target);
});
afterEach(async () => {
  if (component) await unmount(component);
  component = undefined;
  target.remove();
  app.sessionState = undefined;
  app.workspaces = [];
  i18n.setLanguage('en');
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
});
const settle = async () => {
  for (let i = 0; i < 8; i++) await new Promise((resolve) => setTimeout(resolve, 0));
  flushSync();
};
const button = (text: string) =>
  [...target.querySelectorAll('button')].find((b) => b.textContent?.trim() === text);

it('rediscovers an unproven switch, explains its items and acknowledges only on request', async () => {
  const refresh = vi.spyOn(app, 'refreshSnapshot').mockResolvedValue();
  serve((call) => {
    if (call.path === '/api/sessions/s1/environment')
      return calls.filter((c) => c.path === call.path).length === 1
        ? {
            body: environment(binding(1, 'node:source'), {
              operationId: 'op',
              state: 'node_fenced',
            }),
          }
        : { body: environment(binding(2, 'node:target')) };
    if (call.path.endsWith('/op/advance')) return { body: fenced(unproven) };
    if (call.path.endsWith('/op/acknowledge'))
      return { body: fenced({ ...unproven, revocation: null }, 'installed', false) };
    return undefined;
  });
  component = mount(EnvironmentSwitchPanel, { target, props: { sessionId: 's1' } });
  await settle();
  expect(target.textContent).toContain('These records cannot prove that access is gone:');
  expect(target.textContent).toContain(
    'Agent processes: this host cannot prove child processes stopped',
  );
  expect(target.textContent).toContain('Host-management command: detached host work may survive');
  expect(target.textContent).toContain('2 records in total');
  expect(calls.filter((c) => c.path.endsWith('/acknowledge'))).toHaveLength(0);
  button('Acknowledge and switch')!.click();
  await settle();
  expect(calls.find((c) => c.path.endsWith('/acknowledge'))!.body).toEqual({
    digest: 'digest-1',
    clientId: 'client-a',
    generation: 5,
  });
  expect(target.textContent).toContain('Switched; revocation not fully confirmed.');
  expect(refresh).toHaveBeenCalledTimes(1);
});

it('shows a disabled Gateway after a review in zh-TW', async () => {
  i18n.setLanguage('zh-TW');
  serve((call) => {
    if (call.path === '/api/sessions/s1/environment')
      return { body: environment(binding(1, 'node:source')) };
    if (call.path.endsWith('/previews') && call.method === 'POST')
      return {
        body: {
          preview: {
            operationId: call.body.operationId,
            targetWorkspaceId: call.body.targetWorkspaceId,
            planHash: 'p',
          },
          state: 'preview',
          canConfirm: false,
          blockedBy: ['coordinator_not_available'],
          nodeObservations: [],
          resourcePreflight: { status: 'observed', observationHash: 'h' },
        },
      };
    return undefined;
  });
  component = mount(EnvironmentSwitchPanel, { target, props: { sessionId: 's1' } });
  await settle();
  const select = target.querySelector('select')!;
  // Only another workspace on the same Node is offered.
  expect([...select.options].map((o) => o.value)).toEqual(['', 'node:target']);
  select.value = 'node:target';
  select.dispatchEvent(new Event('change'));
  flushSync();
  button('檢視切換')!.click();
  await settle();
  const preview = calls.find((c) => c.method === 'POST')!;
  expect(preview.body).toMatchObject({
    targetWorkspaceId: 'node:target',
    expectedBinding: binding(1, 'node:source'),
  });
  expect(target.textContent).toContain('此閘道已停用環境切換。');
  expect(button('確認切換')).toBeUndefined();
});

it('offers no acknowledgement for blocked evidence', async () => {
  serve((call) => {
    if (call.path === '/api/sessions/s1/environment')
      return {
        body: environment(binding(1, 'node:source'), { operationId: 'op', state: 'node_fenced' }),
      };
    if (call.path.endsWith('/op/advance'))
      return {
        body: fenced({
          ...unproven,
          revocation: {
            ...unproven.revocation,
            status: 'blocked',
            items: [{ kind: 'browser', reason: 'unresolved', acknowledgeable: false }],
            itemsTotal: 1,
          },
        }),
      };
    return undefined;
  });
  component = mount(EnvironmentSwitchPanel, { target, props: { sessionId: 's1' } });
  await settle();
  expect(target.textContent).toContain('Browser: still running or not yet confirmed stopped');
  expect(button('Acknowledge and switch')).toBeUndefined();
  expect(button('Cancel switch')).toBeDefined();
});

const withActive = (
  reply: unknown,
  active: unknown = { operationId: 'op', state: 'node_fenced' },
) =>
  serve((call) => {
    if (call.path === '/api/sessions/s1/environment')
      return { body: environment(binding(1, 'node:source'), active) };
    if (call.path.endsWith('/op/advance')) return { body: reply };
    return undefined;
  });

it('labels inherited items, both statuses and an all-N acknowledgement', async () => {
  withActive({
    ...fenced({
      ...unproven,
      revocation: {
        ...unproven.revocation,
        evaluationId: 'ev-a',
        itemsTotal: 140,
        currentGeneration: { status: 'confirmed', itemsTotal: 0 },
        items: [
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
        ],
      },
    }),
    authority: null,
    cancellation: null,
  });
  component = mount(EnvironmentSwitchPanel, { target, props: { sessionId: 's1' } });
  await settle();
  expect(target.textContent).toContain(
    'Host-management command: detached host work may survive (inherited from generation 1)',
  );
  expect(target.textContent).toContain('(inherited from earlier, unattributed history)');
  expect(target.textContent).toContain('All retained risks: unproven. This generation: confirmed.');
  expect(target.textContent).toContain('Acknowledging covers all 140 items, not only those shown.');
  expect(button('Show all items')).toBeDefined();
});

it('offers Reauthorize after expiry and shows a pending cancellation reason', async () => {
  const confirmed = {
    ...unproven,
    revocation: { ...unproven.revocation, status: 'confirmed', items: [], itemsTotal: 0 },
  };
  const expired = { revision: 1, deadlineAt: 1, state: 'expired', reauthorizationRequired: true };
  let cancelled = false;
  serve((call) => {
    if (call.path === '/api/sessions/s1/environment')
      return {
        body: environment(binding(1, 'node:source'), { operationId: 'op', state: 'node_fenced' }),
      };
    if (call.path.endsWith('/op/advance'))
      return {
        body: cancelled
          ? {
              ...fenced({
                ...confirmed,
                cancellation: { requestedAt: 5, pendingReason: 'resources_unresolved' },
              }),
              authority: expired,
              cancellation: { requestedAt: 5 },
            }
          : { ...fenced(confirmed), authority: expired, cancellation: null },
      };
    if (call.path.endsWith('/op/cancel')) {
      cancelled = true;
      return {
        body: {
          ...fenced({
            ...confirmed,
            cancellation: { requestedAt: 5, pendingReason: 'drain_active' },
          }),
          authority: expired,
          cancellation: { requestedAt: 5 },
        },
      };
    }
    return undefined;
  });
  component = mount(EnvironmentSwitchPanel, { target, props: { sessionId: 's1' } });
  await settle();
  expect(target.textContent).toContain('The permission to finish this switch lapsed.');
  expect(button('Reauthorize')).toBeDefined();
  button('Cancel switch')!.click();
  await settle();
  expect(target.textContent).toContain('Cancellation pending: work is still stopping.');
  expect(button('Reauthorize')).toBeUndefined();
  expect(button('Acknowledge and switch')).toBeUndefined();
  expect(button('Cancel switch')).toBeUndefined();
});

it('shows readiness after a switch and offers only reconcile for a bare fence', async () => {
  vi.spyOn(app, 'refreshSnapshot').mockResolvedValue();
  serve((call) => {
    if (call.path === '/api/sessions/s1/environment')
      return calls.filter((c) => c.path === call.path).length === 1
        ? {
            body: environment(binding(1, 'node:source'), {
              operationId: 'op',
              state: 'node_fenced',
            }),
          }
        : { body: environment(binding(2, 'node:target')) };
    if (call.path.endsWith('/op/advance'))
      return {
        body: {
          ...fenced(
            {
              ...unproven,
              revocation: null,
              installation: {
                revocation: 'unproven',
                environmentEvent: 'delivered',
                bindingCommitted: true,
                policyValidated: true,
                runtimeReady: 'failed',
              },
            },
            'installed',
          ),
          authority: null,
          cancellation: null,
        },
      };
    return undefined;
  });
  component = mount(EnvironmentSwitchPanel, { target, props: { sessionId: 's1' } });
  await settle();
  expect(target.textContent).toContain(
    'Switched; revocation not fully confirmed. Switched; execution failed to start.',
  );
  expect(button('Check again')).toBeDefined();
  await unmount(component);
  calls = [];
  serve((call) =>
    call.path === '/api/sessions/s1/environment'
      ? {
          body: environment(binding(1, 'node:source'), {
            operationId: 'bare',
            state: 'reconciliation_required',
            targetWorkspaceId: 'node:target',
            recoveryReason: 'no_gateway_acceptance',
            safeActions: ['reconcile'],
          }),
        }
      : undefined,
  );
  component = mount(EnvironmentSwitchPanel, { target, props: { sessionId: 's1' } });
  await settle();
  expect(target.textContent).toContain(
    'An environment change needs reconciliation (the Node holds a fence this Gateway never accepted).',
  );
  expect([...target.querySelectorAll('button')].map((b) => b.textContent?.trim())).toEqual([
    'Reconcile',
  ]);
});
