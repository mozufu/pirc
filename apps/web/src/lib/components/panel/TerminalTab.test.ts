// @vitest-environment jsdom
import { flushSync, mount, unmount } from 'svelte';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { i18n } from '../../i18n.svelte';
import TerminalTab from './TerminalTab.svelte';

const WARNING = 'Runs with the Node account’s host permissions. Kept verbatim.';
interface Call {
  method: string;
  url: URL;
  body: Record<string, any> | undefined;
}
let calls: Call[];
let component: ReturnType<typeof mount> | undefined;
let target: HTMLDivElement;

function serve(
  caps: Record<string, unknown>,
  respond: (call: Call) => { status: number; body: unknown } | undefined,
  pending: unknown[] = [],
) {
  vi.stubGlobal(
    'fetch',
    vi.fn(async (input: string, init: RequestInit = {}) => {
      const call: Call = {
        method: init.method ?? 'GET',
        url: new URL(input, 'http://pirc.test'),
        body: init.body ? JSON.parse(init.body as string) : undefined,
      };
      calls.push(call);
      const params = call.url.searchParams;
      let reply: { status: number; body: unknown } | undefined;
      if (call.method === 'GET' && params.get('capabilities'))
        reply = { status: 200, body: { terminalCapabilities: caps } };
      else if (call.method === 'GET' && params.get('unresolvedRequests'))
        reply = {
          status: 200,
          body: { terminalRequests: { version: 1, items: pending, next: null } },
        };
      else if (call.method === 'GET' && !call.url.search)
        reply = { status: 200, body: { terminals: [] } };
      else reply = respond(call);
      if (!reply) throw new Error(`unscripted ${call.method} ${call.url.search}`);
      return new Response(JSON.stringify(reply.body), { status: reply.status });
    }),
  );
}
const review = (requestId: string, state = 'review') => ({
  hostManagement: {
    version: 1,
    requestId,
    id: `host_terminal_${requestId}`,
    reviewHash: `hash-${requestId}`,
    review: {
      version: 1,
      executionPath: 'host_management',
      workspaceId: 'w1',
      cwd: '/srv/work',
      shell: '/bin/zsh',
      cols: 80,
      rows: 24,
      runnerEpoch: 1,
      warning: WARNING,
    },
    expiresAt: 1,
    state,
    errorCode: null,
    terminalId: null,
  },
  terminal: null,
});

beforeEach(() => {
  calls = [];
  const values = new Map<string, string>([['relay.client-id', 'client-a']]);
  vi.stubGlobal('localStorage', {
    getItem: (key: string) => values.get(key) ?? null,
    setItem: (key: string, value: string) => values.set(key, value),
    removeItem: (key: string) => values.delete(key),
    clear: () => values.clear(),
  });
  target = document.createElement('div');
  document.body.append(target);
});
afterEach(async () => {
  if (component) await unmount(component);
  component = undefined;
  target.remove();
  i18n.setLanguage('en');
  vi.unstubAllGlobals();
});

const settle = async () => {
  for (let i = 0; i < 5; i++) await new Promise((resolve) => setTimeout(resolve, 0));
  flushSync();
};
const button = (text: string) =>
  [...target.querySelectorAll('button')].find((b) => b.textContent?.trim() === text);

it('offers only the explicit host review when isolation is unavailable', async () => {
  serve(
    {
      enabled: true,
      isolatedTerminalVersion: 0,
      hostTerminalReviewVersion: 1,
      workTerminalRequestVersion: 2,
    },
    (call) => {
      if (call.method === 'POST' && call.body?.action === 'review')
        return { status: 200, body: review(call.body.requestId) };
      return undefined;
    },
  );
  component = mount(TerminalTab, {
    target,
    props: { sessionId: 's1', generation: 4, hasControl: true },
  });
  await settle();
  expect(target.textContent).toContain('Isolated terminals are unavailable on this Node.');
  expect(button('Open terminal')?.disabled).toBe(true);
  expect(target.querySelector<HTMLButtonElement>('[aria-label="New terminal"]')?.disabled).toBe(
    true,
  );
  expect(calls.filter((call) => call.method === 'POST')).toHaveLength(0);

  button('Host management terminal…')!.click();
  await settle();
  const posts = calls.filter((call) => call.method === 'POST');
  expect(posts).toHaveLength(1);
  expect(posts[0]!.body).toMatchObject({
    executionPath: 'host_management',
    action: 'review',
    clientId: 'client-a',
    generation: 4,
  });
  expect(target.textContent).toContain('Shell: /bin/zsh');
  expect(target.textContent).toContain('Directory: /srv/work');
  expect(target.textContent).toContain('Size: 80 × 24');
  expect(target.querySelector('.warning')?.textContent).toBe(WARNING);
  expect(button('Confirm and open')).toBeDefined();
});

it('opens isolated work from the ordinary action and shows a known no-start', async () => {
  i18n.setLanguage('zh-TW');
  serve(
    {
      enabled: true,
      isolatedTerminalVersion: 1,
      hostTerminalReviewVersion: 1,
      workTerminalRequestVersion: 2,
    },
    (call) =>
      call.method === 'POST'
        ? {
            status: 201,
            body: {
              workRequest: {
                version: 1,
                requestId: call.body!.requestId,
                state: 'not_started',
                errorCode: 'runner_unavailable',
                terminalId: null,
              },
              terminal: null,
            },
          }
        : undefined,
  );
  component = mount(TerminalTab, {
    target,
    props: { sessionId: 's1', generation: 4, hasControl: true },
  });
  await settle();
  expect(calls.map((call) => call.url.search)).toEqual(
    expect.arrayContaining(['?capabilities=1', '?unresolvedRequests=1']),
  );
  button('開啟終端機')!.click();
  await settle();
  const posts = calls.filter((call) => call.method === 'POST');
  expect(posts).toHaveLength(1);
  expect(posts[0]!.body).toMatchObject({ executionPath: 'isolated_work', cols: 80, rows: 24 });
  expect(target.textContent).toContain('終端機未啟動（runner_unavailable）。');
});

it('asks to update a Node without the capability query and sends nothing', async () => {
  serve({}, () => undefined);
  vi.stubGlobal(
    'fetch',
    vi.fn(async (input: string) => {
      calls.push({ method: 'GET', url: new URL(input, 'http://pirc.test'), body: undefined });
      return new Response(JSON.stringify({ terminals: [] }), { status: 200 });
    }),
  );
  component = mount(TerminalTab, {
    target,
    props: { sessionId: 's1', generation: 4, hasControl: true },
  });
  await settle();
  expect(target.textContent).toContain('Update the Node to open terminals from this client.');
  expect(button('Open terminal')?.disabled).toBe(true);
  // No discovery on an old Node either.
  expect(calls.some((call) => call.url.searchParams.has('unresolvedRequests'))).toBe(false);
});

const unknownWork = (acknowledgedAt: number | null = null) => ({
  workRequest: {
    version: 1,
    requestId: 'u1',
    state: 'outcome_unknown',
    errorCode: 'terminal_start_unconfirmed',
    terminalId: null,
    acknowledgedAt,
  },
  terminal: null,
});
const caps = (workTerminalRequestVersion: number) => ({
  enabled: true,
  isolatedTerminalVersion: 1,
  hostTerminalReviewVersion: 1,
  workTerminalRequestVersion,
});

it('acknowledges a recovered unconfirmed start on a v3 Node and stops showing it', async () => {
  serve(
    caps(3),
    (call) =>
      call.method === 'POST' && call.body?.action === 'acknowledge'
        ? { status: 200, body: unknownWork(42) }
        : undefined,
    [unknownWork()],
  );
  component = mount(TerminalTab, {
    target,
    props: { sessionId: 's1', generation: 4, hasControl: true },
  });
  await settle();
  expect(target.textContent).toContain('Start not confirmed.');
  expect(target.textContent).toContain('Acknowledging only stops listing this request as pending.');
  button('Acknowledge')!.click();
  await settle();
  const posts = calls.filter((call) => call.method === 'POST');
  expect(posts.map((call) => call.body)).toEqual([
    { action: 'acknowledge', clientId: 'client-a', generation: 4, workRequestId: 'u1' },
  ]);
  expect(target.textContent).not.toContain('Start not confirmed.');
  expect(target.textContent).not.toContain('Terminal closed');
});

it('offers no acknowledgement on a v2 Node or without control', async () => {
  serve(caps(2), () => undefined, [unknownWork()]);
  component = mount(TerminalTab, {
    target,
    props: { sessionId: 's1', generation: 4, hasControl: true },
  });
  await settle();
  expect(target.textContent).toContain('Start not confirmed.');
  expect(button('Acknowledge')).toBeUndefined();
  await unmount(component);
  serve(caps(3), () => undefined, [unknownWork()]);
  component = mount(TerminalTab, {
    target,
    props: { sessionId: 's1', generation: undefined, hasControl: false },
  });
  await settle();
  expect(button('Acknowledge')).toBeUndefined();
});

it('says too many terminals on a capacity refusal', async () => {
  i18n.setLanguage('zh-TW');
  serve(caps(3), (call) =>
    call.method === 'POST'
      ? {
          status: 409,
          body: {
            error: { code: 'terminal_capacity', message: 'At most 8 terminals per session' },
          },
        }
      : undefined,
  );
  component = mount(TerminalTab, {
    target,
    props: { sessionId: 's1', generation: 4, hasControl: true },
  });
  await settle();
  button('開啟終端機')!.click();
  await settle();
  expect(target.textContent).toContain('開啟或準備中的終端機過多。請先關閉一個。');
});
