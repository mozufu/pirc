// @vitest-environment jsdom
import { afterEach, it, expect, vi } from 'vitest';
import { mount, unmount } from 'svelte';
import { app } from '../app.svelte';
import FirstSendRecovery from './FirstSendRecovery.svelte';
let component: ReturnType<typeof mount> | undefined;
afterEach(() => {
  if (component) unmount(component);
  app.firstCapabilities = undefined;
  app.firstDraft = undefined;
  app.firstRecoveries = [];
  document.body.innerHTML = '';
  vi.restoreAllMocks();
});
function show(state: string) {
  const row = {
    scope: 'scope',
    ownerUser: 'alice',
    operationId: 'op',
    revision: 1,
    workspaceId: 'node:repo',
    message: 'Original private text',
    files: [],
    frozen: true,
    updatedAt: 1,
    preparation: {
      operationId: 'op',
      sessionId: 'session',
      workspaceId: 'node:repo',
      state,
      accepted: true,
      cleanupPending: false,
    },
  };
  app.firstDraft = row;
  app.firstRecoveries = [row];
  component = mount(FirstSendRecovery, { target: document.body });
}
it('an uncertain send exposes read-only checking and keeps its details collapsed', async () => {
  const check = vi.spyOn(app, 'checkFirst').mockResolvedValue();
  show('outcome_unknown');
  const buttons = [...document.querySelectorAll('button')];
  expect(buttons.some((b) => b.textContent?.trim() === 'Continue sending')).toBe(false);
  expect([...document.querySelectorAll('details')].every((d) => !d.open)).toBe(true);
  buttons.find((b) => b.textContent?.trim() === 'Check result')!.click();
  await Promise.resolve();
  expect(check).toHaveBeenCalledOnce();
});
it('known admission offers Open conversation, never another Send action', () => {
  show('admitted');
  const labels = [...document.querySelectorAll('button')].map((b) => b.textContent?.trim());
  expect(labels).toContain('Open conversation');
  expect(labels).not.toContain('Continue sending');
});

it('unmapped accepted input exposes only supported Stop, and stopping leaves query controls', async () => {
  app.firstCapabilities = {
    version: 1,
    ownerUser: 'alice',
    canSubmit: false,
    canStopBeforeAllocation: true,
  };
  const stop = vi.spyOn(app, 'stopFirst').mockResolvedValue();
  show('accepted');
  expect(
    [...document.querySelectorAll('button')].some(
      (b) => b.textContent?.trim() === 'Stop pending message',
    ),
  ).toBe(true);
  [...document.querySelectorAll('button')]
    .find((b) => b.textContent?.trim() === 'Stop pending message')!
    .click();
  await Promise.resolve();
  expect(stop).toHaveBeenCalledOnce();
});
it('confirmed unmapped Stop offers explicit Open and keeps originals collapsed', async () => {
  show('stopped');
  app.firstDraft = {
    ...app.firstDraft!,
    preparation: {
      ...app.firstDraft!.preparation!,
      nodeMapped: false,
      messageAdmission: { outcome: 'not_admitted', stopRequested: true, stopConfirmed: true },
    },
  };
  await new Promise((r) => setTimeout(r, 0));
  const labels = [...document.querySelectorAll('button')].map((b) => b.textContent?.trim());
  expect(labels).toContain('Open conversation');
  expect(labels).not.toContain('Take control');
  expect([...document.querySelectorAll('details')].every((d) => !d.open)).toBe(true);
});

it('a deleted operation with an earlier Stop never offers Open conversation', async () => {
  show('cancelled');
  app.firstDraft = {
    ...app.firstDraft!,
    preparation: {
      ...app.firstDraft!.preparation!,
      messageAdmission: { outcome: 'not_admitted', stopRequested: true, stopConfirmed: true },
    },
  };
  await new Promise((r) => setTimeout(r, 0));
  expect(
    [...document.querySelectorAll('button')].some(
      (b) => b.textContent?.trim() === 'Open conversation',
    ),
  ).toBe(false);
});

it('a confirmed rejection offers explicit Retry; uncertain local attempts hide it', async () => {
  const retry = vi.spyOn(app, 'retryFirst').mockResolvedValue();
  app.firstCapabilities = {
    version: 1,
    clientContract: 2,
    requiredClientContract: 2,
    ownerUser: 'alice',
    canSubmit: true,
    canFenceAccount: true,
    canStopBeforeAllocation: true,
    canRetryFirstMessage: true,
  };
  show('admission_failed');
  app.firstDraft = {
    ...app.firstDraft!,
    preparation: {
      ...app.firstDraft!.preparation!,
      messageAdmission: {
        commandId: 'cmd',
        attemptNumber: 0,
        outcome: 'not_admitted',
        retryEligible: true,
        stopRequested: false,
        stopConfirmed: false,
      },
    },
  };
  const { flushSync } = await import('svelte');
  flushSync();
  const button = [...document.querySelectorAll('button')].find(
    (b) => b.textContent?.trim() === 'Retry original message',
  )!;
  expect(button).toBeDefined();
  expect(button.disabled).toBe(false);
  button.click();
  await Promise.resolve();
  expect(retry).toHaveBeenCalledOnce();
  app.firstDraft = {
    ...app.firstDraft!,
    retryAttempt: { retryId: 'nonce', previousCommandId: 'cmd', previousAttemptNumber: 0 },
    uncertain: true,
  };
  flushSync();
  expect(
    [...document.querySelectorAll('button')].some(
      (b) => b.textContent?.trim() === 'Retry original message',
    ),
  ).toBe(false);
  expect(document.body.textContent).toContain('First message outcome is unknown');
});

it('interrupted recovery is separate from Retry, stays available while rollout is off, and honors capability and Stop', async () => {
  const recover = vi.spyOn(app, 'recoverFirstRetry').mockResolvedValue();
  const retry = vi.spyOn(app, 'retryFirst').mockResolvedValue();
  app.firstCapabilities = {
    version: 1,
    clientContract: 2,
    requiredClientContract: 2,
    ownerUser: 'alice',
    canSubmit: false,
    canFenceAccount: true,
    canStopBeforeAllocation: true,
    canRetireFirstMessageRetry: true,
  };
  show('admission_failed');
  app.firstDraft = {
    ...app.firstDraft!,
    uncertain: true,
    retryAttempt: { retryId: 'pending', previousCommandId: 'cmd', previousAttemptNumber: 0 },
    preparation: {
      ...app.firstDraft!.preparation!,
      messageAdmission: {
        commandId: 'cmd',
        attemptNumber: 0,
        outcome: 'not_admitted',
        retryEligible: true,
        stopRequested: false,
        stopConfirmed: false,
      },
    },
  };
  const { flushSync } = await import('svelte');
  flushSync();
  const buttons = () => [...document.querySelectorAll('button')];
  const recovery = () =>
    buttons().find((b) => b.textContent?.trim() === 'Recover interrupted retry');
  expect(recovery()?.disabled).toBe(false);
  expect(buttons().some((b) => b.textContent?.trim() === 'Retry original message')).toBe(false);
  recovery()!.click();
  await Promise.resolve();
  expect(recover).toHaveBeenCalledOnce();
  expect(retry).not.toHaveBeenCalled();
  app.firstCapabilities = { ...app.firstCapabilities!, canRetireFirstMessageRetry: false };
  flushSync();
  expect(recovery()?.disabled).toBe(true);
  app.firstDraft = { ...app.firstDraft!, stopCommandId: 'stop' };
  flushSync();
  expect(recovery()).toBeUndefined();
  // Damaged metadata must not throw while rendering the recovery panel.
  app.firstDraft = {
    ...app.firstDraft!,
    stopCommandId: undefined,
    preparation: {
      ...app.firstDraft!.preparation!,
      messageAdmission: { ...app.firstDraft!.preparation!.messageAdmission!, attemptNumber: -1 },
    },
  };
  flushSync();
  expect(recovery()).toBeUndefined();
});

it('an attempt the Node refused for good reads as not executed with an enabled Retry', async () => {
  app.firstCapabilities = {
    version: 1,
    clientContract: 2,
    requiredClientContract: 2,
    ownerUser: 'alice',
    canSubmit: true,
    canFenceAccount: true,
    canStopBeforeAllocation: true,
    canRetryFirstMessage: true,
  };
  show('admission_failed');
  app.firstDraft = {
    ...app.firstDraft!,
    preparation: {
      ...app.firstDraft!.preparation!,
      messageAdmission: {
        commandId: 'cmd',
        attemptNumber: 0,
        outcome: 'not_admitted',
        retryEligible: true,
        stopRequested: false,
        stopConfirmed: false,
        recovery: 'voided',
      },
    },
  };
  const { flushSync } = await import('svelte');
  flushSync();
  const text = document.body.textContent ?? '';
  expect(text).toContain('First message was not executed. You can retry.');
  expect(text).not.toContain('admitted');
  expect(text).not.toContain('outcome is unknown');
  const retry = [...document.querySelectorAll('button')].find(
    (b) => b.textContent?.trim() === 'Retry original message',
  )!;
  expect(retry.disabled).toBe(false);
  // The original text stays readable.
  expect(text).toContain('Original private text');
});

it('a Node that cannot recover an unknown outcome says it needs an upgrade and offers no Retry', async () => {
  show('outcome_unknown');
  app.firstDraft = {
    ...app.firstDraft!,
    preparation: {
      ...app.firstDraft!.preparation!,
      deliveryError: 'recovery_unsupported',
      messageAdmission: {
        commandId: 'cmd',
        attemptNumber: 0,
        outcome: 'outcome_unknown',
        retryEligible: false,
        stopRequested: false,
        stopConfirmed: false,
        recovery: 'recovery_unsupported',
      },
    },
  };
  const { flushSync } = await import('svelte');
  flushSync();
  const text = document.body.textContent ?? '';
  expect(text).toContain('First message outcome is unknown');
  expect(text).toContain('This Node must be upgraded before this message can be recovered');
  expect(
    [...document.querySelectorAll('button')].some(
      (b) => b.textContent?.trim() === 'Retry original message',
    ),
  ).toBe(false);
});
