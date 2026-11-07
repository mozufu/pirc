// @vitest-environment jsdom
import { afterEach, expect, it, vi } from 'vitest';
import { mount, tick, unmount } from 'svelte';
import { app } from '../../app.svelte';
import ContextTab from './ContextTab.svelte';
let component: ReturnType<typeof mount> | undefined;
let target: HTMLDivElement;
const snapshot = {
  version: 1,
  id: 'r1',
  takenAt: 1,
  model: { provider: 'p', id: 'm', contextWindow: 1000 },
  sections: [
    {
      id: 'base',
      title: 'Instructions',
      source: '/work/AGENTS.md',
      filePath: 'AGENTS.md',
      text: 'captured prompt',
      frozen: true,
      estimatedTokens: 4,
    },
  ],
  tools: [
    {
      name: 'read',
      description: 'Read files',
      parameters: { type: 'object' },
      estimatedTokens: 10,
    },
  ],
  capabilities: [
    {
      name: 'bash',
      category: 'shell',
      uiLabel: 'Bash',
      effects: ['process', 'write'],
      approval: 'operation-policy',
    },
  ],
  usage: {
    estimatedInput: 20,
    reportedInput: 40,
    scale: 2,
    remaining: 960,
    buckets: { system: 4, tools: 10, messages: 6, memory: 0 },
  },
};
async function flush() {
  for (let i = 0; i < 15; i++) {
    await Promise.resolve();
    await tick();
  }
}
afterEach(async () => {
  if (component) await unmount(component);
  component = undefined;
  target?.remove();
  vi.unstubAllGlobals();
  app.sessionState = undefined;
});
it('shows saved sections, tool schemas, scaled usage, source links and copy-all', async () => {
  vi.stubGlobal(
    'fetch',
    vi.fn(
      async () =>
        new Response(JSON.stringify({ snapshot, agentRunning: false, source: 'snapshot' })),
    ),
  );
  const writeText = vi.fn(async () => {});
  Object.defineProperty(navigator, 'clipboard', { value: { writeText }, configurable: true });
  target = document.createElement('div');
  document.body.append(target);
  const open = vi.fn();
  component = mount(ContextTab, { target, props: { sessionId: 'session', onopenfile: open } });
  await flush();
  expect(target.textContent).toContain('agent stopped');
  expect(target.textContent).toContain('Frozen');
  expect(target.textContent).toContain('Read files');
  // Provider tools and the capabilities scripts call are listed apart.
  expect(target.textContent).toContain('Model tools (1)');
  expect(target.textContent).toContain('Capabilities (1)');
  expect(target.querySelector('.capabilities')?.textContent).toContain(
    'bash shell · process, write · operation-policy',
  );
  expect(target.querySelector('[role="img"]')?.getAttribute('aria-label')).toContain('system 8');
  [...target.querySelectorAll('button')]
    .find((b) => b.textContent?.includes('/work/AGENTS.md'))!
    .click();
  expect(open).toHaveBeenCalledWith('AGENTS.md');
  [...target.querySelectorAll('button')].find((b) => b.textContent?.includes('Copy all'))!.click();
  await flush();
  expect(writeText).toHaveBeenCalledWith('captured prompt');
});
it('shows the send-first error without fabricating an empty snapshot', async () => {
  vi.stubGlobal(
    'fetch',
    vi.fn(
      async () =>
        new Response(
          JSON.stringify({ error: { code: 'no_context', message: 'Send a message first' } }),
          { status: 404 },
        ),
    ),
  );
  target = document.createElement('div');
  document.body.append(target);
  component = mount(ContextTab, { target, props: { sessionId: 'new' } });
  await flush();
  expect(target.querySelector('[role="alert"]')?.textContent).toContain('Send a message first');
  expect(target.querySelector('details')).toBeNull();
});

it('refreshes when an idle runner stops while the inspector stays open', async () => {
  app.sessionState = {
    session: { id: 's' },
    control: { heldByCurrentClient: false },
    runnerStatus: 'ready',
  } as never;
  vi.stubGlobal(
    'fetch',
    vi.fn(
      async () => new Response(JSON.stringify({ snapshot, agentRunning: true, source: 'live' })),
    ),
  );
  target = document.createElement('div');
  document.body.append(target);
  component = mount(ContextTab, { target, props: { sessionId: 's' } });
  await flush();
  expect(target.textContent).not.toContain('agent stopped');
  vi.mocked(fetch).mockResolvedValueOnce(
    new Response(JSON.stringify({ snapshot, agentRunning: false, source: 'snapshot' })),
  );
  app.sessionState = {
    session: { id: 's' },
    control: { heldByCurrentClient: false },
    runnerStatus: 'stopped',
  } as never;
  await flush();
  expect(target.textContent).toContain('agent stopped');
});
