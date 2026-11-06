<script lang="ts">
  import { tr } from '../../i18n.svelte';
  import { onDestroy } from 'svelte';

  import { Plus, SquareTerminal, X } from '@lucide/svelte';
  import { rovingFocus } from '../../a11y';
  import { errorMessage } from '../../errors';
  import { Loader } from '../../loader.svelte';
  import { panelApi, type TerminalInfo } from '../../panel-api';
  import { getClientId } from '../../storage';
  import {
    allowedActions,
    canDiscover,
    recordOf,
    terminalOffer,
    terminalRequestApi,
    TerminalRequests,
    type RequestAction,
    type TerminalIntent,
    type TerminalOffer,
    type TrackedRequest,
  } from '../../terminal-requests';
  import { watch } from '../../watch.svelte';
  import TerminalView from './TerminalView.svelte';

  interface Props {
    sessionId: string;
    generation: number | undefined;
    hasControl: boolean;
    active?: boolean;
  }

  let { sessionId, generation, hasControl, active = false }: Props = $props();

  let terminals: TerminalInfo[] = $state([]);
  let current: string | undefined = $state();
  let error = $state('');
  let busy = $state(false);
  /** `undefined` until the capability query answers. */
  let offer: TerminalOffer | undefined = $state();
  let requests: TrackedRequest[] = $state([]);
  let flow: TerminalRequests | undefined;

  const listLoader = new Loader();

  /** The lease and size a terminal request is bound to; none without control. */
  const intent = (): TerminalIntent | undefined =>
    hasControl && generation !== undefined
      ? { sessionId, clientId: getClientId(), generation, cols: 80, rows: 24 }
      : undefined;

  function attach(terminal: TerminalInfo) {
    terminals = [...terminals.filter((t) => t.id !== terminal.id && !t.exited), terminal];
    current = terminal.id;
  }

  /** Capabilities, then unresolved requests left by a reload, reconnect or another device. */
  async function discover() {
    const id = sessionId;
    const requestFlow = flow;
    try {
      const caps = await terminalRequestApi.capabilities(id);
      if (id !== sessionId) return;
      offer = terminalOffer(caps);
      if (canDiscover(caps)) await requestFlow?.recover();
    } catch (cause) {
      if (id === sessionId)
        error = errorMessage(cause, tr('Unable to read pending terminal requests.'));
    }
  }

  async function load() {
    const id = sessionId;
    const result = await listLoader.run(
      (signal) => panelApi.terminals(id, signal),
      tr('Terminals are unavailable.'),
    );
    if (!result || id !== sessionId) return;
    terminals = result.terminals;
    if (!current || !terminals.some((t) => t.id === current))
      current = terminals[terminals.length - 1]?.id;
  }

  /** The ordinary New terminal action: isolated work only, never the host path. */
  async function create() {
    const lease = intent();
    if (!lease) {
      error = tr('Take control of the session to open a terminal.');
      return;
    }
    if (offer?.kind !== 'isolated') {
      error = offerNotice(offer) || tr('Unable to open a terminal.');
      return;
    }
    await run(() => flow?.openWork(lease));
  }

  /** The separate, explicit host-management action: a review first. */
  async function reviewHost() {
    const lease = intent();
    if (!lease) {
      error = tr('Take control of the session to open a terminal.');
      return;
    }
    await run(() => flow?.reviewHost(lease));
  }

  async function act(request: TrackedRequest, action: RequestAction) {
    const lease = intent();
    if (action === 'new_terminal') return create();
    if (action === 'host_review') return reviewHost();
    if (action === 'dismiss') return flow?.dismiss(request.requestId, request.kind);
    if (action === 'refresh') return run(() => flow?.refresh(request.requestId, request.kind));
    if (!lease) return;
    if (action === 'confirm') return run(() => flow?.confirmHost(request.requestId, lease));
    if (action === 'resubmit')
      return run(() => flow?.resubmit(request.requestId, lease, request.kind));
  }

  async function run(step: () => Promise<unknown> | undefined) {
    busy = true;
    error = '';
    try {
      await step();
    } finally {
      busy = false;
    }
  }

  function offerNotice(value: TerminalOffer | undefined) {
    if (value?.kind === 'update_node')
      return tr('Update the Node to open terminals from this client.');
    if (value?.kind === 'disabled') return tr('New terminals are disabled on this Node.');
    if (value?.kind === 'isolation_unavailable')
      return tr('Isolated terminals are unavailable on this Node.');
    return '';
  }

  function describe(request: TrackedRequest) {
    const record = request.result && recordOf(request.result);
    switch (request.phase) {
      case 'review':
        return tr('Review the host management terminal');
      case 'review_unusable':
        return tr('This review can no longer be confirmed. Start a new review.');
      case 'preparing':
        return tr('Preparing the isolated terminal…');
      case 'live':
        return '';
      case 'not_started':
        return tr('The terminal did not start ({0}).', [record?.errorCode ?? '—']);
      case 'start_unconfirmed':
        return tr(
          'Start not confirmed. It is not retried automatically, and workspace switching may stay blocked.',
        );
      case 'closed':
        return tr('Terminal closed.');
      case 'closed_unconfirmed':
        return tr(
          'Terminal closed, but its cleanup is not confirmed. Workspace switching may stay blocked.',
        );
      case 'unknown_state':
        return tr('Unknown terminal request state ({0}).', [record?.state ?? '—']);
      case 'submitting':
        return tr('Sending the terminal request…');
      case 'checking':
        return tr('Checking whether the terminal request arrived…');
      case 'unknown_delivery':
        return tr('The Node did not answer. Check again to see whether the request arrived.');
      case 'not_admitted':
        return tr('The request did not reach the Node.');
      case 'rejected':
        return request.error?.message ?? tr('Unable to open a terminal.');
    }
  }

  const actionLabel = (action: RequestAction) =>
    ({
      confirm: tr('Confirm and open'),
      attach: tr('Open terminal'),
      refresh: tr('Check again'),
      resubmit: tr('Send again'),
      new_terminal: tr('New terminal'),
      host_review: tr('Host management terminal…'),
      dismiss: tr('Dismiss'),
    })[action];

  const pathLabel = (terminal: TerminalInfo) =>
    terminal.executionPath === 'isolated_work'
      ? tr('Isolated')
      : terminal.executionPath === 'host_management'
        ? tr('Host management')
        : '';

  async function close(terminal: TerminalInfo) {
    if (!terminal.exited) {
      if (!hasControl || generation === undefined) {
        error = tr('Take control of the session to close a terminal.');
        return;
      }
      try {
        await panelApi.closeTerminal(sessionId, terminal.id, generation);
      } catch (cause) {
        if (!(cause instanceof Error && /not found/i.test(cause.message))) {
          error = errorMessage(cause, tr('Unable to close the terminal.'));
          return;
        }
      }
    }
    terminals = terminals.filter((t) => t.id !== terminal.id);
    if (current === terminal.id) current = terminals[terminals.length - 1]?.id;
  }

  function exited(id: string, exitCode: number | null) {
    terminals = terminals.map((t) => (t.id === id ? { ...t, exited: true, exitCode } : t));
  }

  watch(
    () => sessionId,
    () => {
      listLoader.abort();
      flow?.dispose();
      error = '';
      terminals = [];
      current = undefined;
      offer = undefined;
      requests = [];
      // Pending request IDs stay in memory; a reload rediscovers them.
      flow = new TerminalRequests({
        sessionId,
        onchange: (list) => (requests = list),
        onterminal: attach,
      });
      void load();
      void discover();
    },
    { immediate: true },
  );
  onDestroy(() => flow?.dispose());
</script>

<div class="terminal-tab">
  <div
    class="terminal-strip"
    role="tablist"
    aria-label={tr('Terminals')}
    use:rovingFocus={{ selector: '[role="tab"]', activate: true }}
  >
    {#each terminals as terminal, index (terminal.id)}
      <div
        class="terminal-chip"
        class:active={terminal.id === current}
        class:exited={terminal.exited}
      >
        <button
          type="button"
          role="tab"
          id="terminal-tab-{terminal.id}"
          aria-controls="terminal-panel-{terminal.id}"
          aria-selected={terminal.id === current}
          tabindex={terminal.id === current ? 0 : -1}
          title={tr('Delete closes this terminal')}
          onclick={() => (current = terminal.id)}
          onkeydown={(event) => {
            if (event.key === 'Delete') {
              event.preventDefault();
              void close(terminal);
            }
          }}
        >
          <SquareTerminal size={13} />{terminal.title}
          {index + 1}
          {#if pathLabel(terminal)}<span class="path-label">{pathLabel(terminal)}</span>{/if}
        </button>
        <button
          type="button"
          class="chip-close"
          tabindex="-1"
          aria-label={tr('Close terminal {0}', [index + 1])}
          onclick={() => close(terminal)}><X size={12} /></button
        >
      </div>
    {/each}
    <button
      class="icon-button small"
      type="button"
      aria-label={tr('New terminal')}
      disabled={busy || !hasControl || offer?.kind !== 'isolated'}
      title={hasControl ? tr('New terminal') : tr('Take control to open a terminal')}
      onclick={create}><Plus size={15} /></button
    >
    {#if offer?.kind === 'isolation_unavailable' && offer.hostManagement}
      <button class="button small" type="button" disabled={busy || !hasControl} onclick={reviewHost}
        >{tr('Host management terminal…')}</button
      >
    {/if}
  </div>
  {#if error || listLoader.error}<p class="panel-error">{error || listLoader.error}</p>{/if}
  {#if offerNotice(offer)}<p class="muted terminal-notice">{offerNotice(offer)}</p>{/if}
  {#each requests.filter((request) => request.phase !== 'live') as request (request.kind + request.requestId)}
    {@const host =
      request.result && 'hostManagement' in request.result ? request.result.hostManagement : null}
    <div class="terminal-request" data-phase={request.phase}>
      <p>{describe(request)}</p>
      {#if request.conflict}<p class="muted">
          {tr(
            'This request ID belonged to another terminal request; its original result is shown.',
          )}
        </p>{/if}
      {#if request.error && request.phase !== 'rejected'}<p class="muted">
          {request.error.message}
        </p>{/if}
      {#if host && request.phase === 'review'}
        <p>{tr('Shell: {0}', [host.review.shell])}</p>
        <p>{tr('Directory: {0}', [host.review.cwd])}</p>
        <p>{tr('Size: {0} × {1}', [host.review.cols, host.review.rows])}</p>
        <p class="warning">{host.review.warning}</p>
      {/if}
      {#each allowedActions( request, { intent: intent(), offer: offer ?? { kind: 'update_node' } }, ).filter((action) => action !== 'attach') as action (action)}
        <button
          class="button small"
          type="button"
          disabled={busy && action !== 'dismiss'}
          onclick={() => act(request, action)}>{actionLabel(action)}</button
        >
      {/each}
    </div>
  {/each}
  {#if !terminals.length}
    <div class="terminal-empty">
      <SquareTerminal size={22} />
      <p>
        {tr(
          'Run commands in this workspace. The shell runs as the gateway’s account, just like the agent’s own tools.',
        )}
      </p>
      <button
        class="button primary"
        type="button"
        disabled={busy || !hasControl || offer?.kind !== 'isolated'}
        onclick={create}>{tr('Open terminal')}</button
      >
      {#if !hasControl}<p class="muted">{tr('Take control of the session to open one.')}</p>{/if}
    </div>
  {/if}
  {#each terminals as terminal (terminal.id)}
    <TerminalView
      {sessionId}
      {terminal}
      {generation}
      {hasControl}
      visible={active && terminal.id === current}
      onexit={(code) => exited(terminal.id, code)}
    />
  {/each}
</div>

<style>
  /* Terminal */
  .terminal-tab {
    height: 100%;
    display: flex;
    flex-direction: column;
    min-height: 0;
  }
  .terminal-tab > .panel-error {
    margin: 8px 12px 0;
  }
  .terminal-strip {
    flex: none;
    display: flex;
    align-items: center;
    gap: 4px;
    padding: 6px 8px;
    overflow-x: auto;
    border-bottom: 1px solid var(--line);
    scrollbar-width: none;
  }
  .terminal-chip {
    flex: none;
    display: inline-flex;
    align-items: center;
    border-radius: var(--radius-sm);
    color: var(--text-2);
  }
  .terminal-chip.active {
    color: var(--ink);
    background: var(--bg-active);
  }
  .terminal-chip.exited {
    opacity: 0.6;
  }
  .terminal-chip > button {
    height: 26px;
    display: inline-flex;
    align-items: center;
    gap: 5px;
    padding: 0 4px 0 8px;
    border: 0;
    color: inherit;
    background: transparent;
    font-size: 12px;
  }
  .terminal-chip .chip-close {
    padding: 0 6px 0 2px;
    color: var(--muted);
  }
  .terminal-chip .chip-close:hover {
    color: var(--danger);
  }
  @media (hover: none) {
    .terminal-chip > button {
      height: 40px;
    }
    .terminal-chip .chip-close {
      padding: 0 12px 0 8px;
    }
  }
  .terminal-empty {
    display: grid;
    justify-items: center;
    gap: 10px;
    margin: auto;
    padding: 24px;
    color: var(--muted);
    font-size: 13px;
    line-height: 1.5;
    text-align: center;
  }
  .path-label {
    color: var(--muted);
    font-size: 11px;
  }
  .terminal-notice,
  .terminal-request {
    margin: 8px 12px 0;
    font-size: 12px;
  }
  .terminal-request p {
    margin: 0 0 4px;
  }
  .terminal-empty p {
    max-width: 300px;
    margin: 0;
  }
</style>
