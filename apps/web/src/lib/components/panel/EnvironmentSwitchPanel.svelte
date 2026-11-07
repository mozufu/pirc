<script lang="ts">
  /** Throwaway wiring of the environment-switch interface; the new UI replaces it. */
  import { onDestroy } from 'svelte';
  import { app } from '../../app.svelte';
  import {
    allowedSwitchActions,
    BLOCKER_LABELS,
    EnvironmentSwitch,
    ITEM_KIND_LABELS,
    ITEM_REASON_LABELS,
    type SwitchAction,
    type SwitchState,
    type TransitionLease,
  } from '../../environment-transitions';
  import { tr } from '../../i18n.svelte';
  import { getClientId } from '../../storage';
  import { watch } from '../../watch.svelte';

  let { sessionId }: { sessionId: string } = $props();

  let view: SwitchState = $state({ phase: 'idle' });
  let target = $state('');
  let busy = $state(false);
  let flow: EnvironmentSwitch | undefined;

  const lease = (): TransitionLease | undefined =>
    app.hasControl && app.generation !== undefined
      ? { sessionId, clientId: getClientId(), generation: app.generation }
      : undefined;
  const session = $derived(app.sessionState?.session);
  const targets = $derived(
    app.workspaces.filter(
      (w) =>
        w.id !== session?.workspaceId &&
        w.hostId === app.workspaces.find((s) => s.id === session?.workspaceId)?.hostId,
    ),
  );

  watch(
    () => sessionId,
    () => {
      flow?.dispose();
      view = { phase: 'idle' };
      flow = new EnvironmentSwitch({
        sessionId,
        onchange: (next) => (view = next),
        // Later commands carry the snapshot's binding as `expectedBinding`.
        onbinding: () => void app.refreshSnapshot(),
      });
      flow.setLease(lease());
      void flow.discover();
    },
    { immediate: true },
  );
  watch(
    () => [app.hasControl, app.generation],
    () => flow?.setLease(lease()),
  );
  onDestroy(() => flow?.dispose());

  async function act(action: SwitchAction) {
    const current = lease();
    busy = true;
    try {
      if (action === 'preview' || action === 'review_again') {
        if (target && session?.binding) await flow?.preview(target, session.binding);
      } else if (action === 'refresh') await flow?.refresh(current);
      else if (action === 'resend') await flow?.resend(current);
      else if (action === 'discard') flow?.discard();
      else if (current && action === 'confirm') await flow?.confirm(current);
      else if (current && action === 'acknowledge') await flow?.acknowledge(current);
      else if (current && action === 'cancel') await flow?.cancel(current);
    } finally {
      busy = false;
    }
  }

  function describe(s: SwitchState) {
    switch (s.phase) {
      case 'idle':
        return '';
      case 'previewing':
      case 'confirming':
        return tr('Working…');
      case 'preview_unknown':
      case 'confirm_unknown':
        return tr('The Gateway did not answer. Check again to see whether the request arrived.');
      case 'preview_missing':
        return tr('The review was not stored. You can send the same review again.');
      case 'confirm_missing':
        return tr('The switch was not accepted. You can send the same confirmation again.');
      case 'review':
        return tr("Ready to switch. Confirming stops the conversation's current work first.");
      case 'review_blocked':
        return tr('This switch is blocked:');
      case 'review_stale':
        return tr('The environment changed since this review. Review again.');
      case 'switching_disabled':
        return tr('Environment switching is disabled on this Gateway.');
      case 'awaiting_dispatch':
        return tr('Accepted; the Node has not been asked yet.');
      case 'outcome_unknown':
        return tr('Checking whether the Node fenced the conversation…');
      case 'draining':
        return tr("Stopping the conversation's current work…");
      case 'blocked':
        return tr('Some work could not be confirmed stopped. It cannot be acknowledged:');
      case 'needs_acknowledgement':
        return tr('These records cannot prove that access is gone:');
      case 'installing':
        return tr('Installing the new environment…');
      case 'switched':
        return s.result === 'revocation_confirmed'
          ? tr('Switched; revocation confirmed.')
          : tr('Switched; revocation not fully confirmed.');
      case 'cancelled':
        return tr('Cancelled; original workspace kept.');
      case 'deleted':
        return tr('The conversation was deleted.');
      case 'legacy_fence':
        return tr('An earlier environment change still fences this conversation.');
      case 'unknown_state':
        return tr('Unknown transition state ({0}).', [s.status?.transition.state ?? '—']);
      case 'rejected':
        return s.error?.message ?? tr('Request failed ({0})', [s.error?.status ?? 0]);
    }
  }

  const label = (action: SwitchAction) =>
    ({
      preview: tr('Review switch'),
      confirm: tr('Confirm switch'),
      refresh: tr('Check again'),
      resend: tr('Send again'),
      review_again: tr('Review again'),
      acknowledge: tr('Acknowledge and switch'),
      cancel: tr('Cancel switch'),
      discard: tr('Dismiss'),
    })[action];
  const revocation = $derived(view.status?.progress?.revocation);
</script>

<section class="environment-switch">
  <h3>{tr('Switch environment')}</h3>
  {#if view.phase === 'idle' || view.phase === 'review_stale'}
    <label
      >{tr('Target workspace')}
      <select bind:value={target}>
        <option value=""></option>
        {#each targets as workspace (workspace.id)}
          <option value={workspace.id}>{workspace.displayName}</option>
        {/each}
      </select>
    </label>
  {/if}
  {#if describe(view)}<p data-phase={view.phase}>{describe(view)}</p>{/if}
  {#if view.phase === 'review_blocked'}
    <ul>
      {#each view.preview?.blockedBy ?? [] as reason (reason)}
        <li>{BLOCKER_LABELS[reason] ? tr(BLOCKER_LABELS[reason]) : reason}</li>
      {/each}
    </ul>
  {/if}
  {#if revocation && (view.phase === 'needs_acknowledgement' || view.phase === 'blocked')}
    {#if view.digestChanged}<p>
        {tr('The items changed since you looked. Review them again.')}
      </p>{/if}
    <p>{tr('{0} records in total', [revocation.itemsTotal])}</p>
    <ul class="items">
      {#each revocation.items as item, index (index)}
        <li>
          {tr('{0}: {1}', [
            ITEM_KIND_LABELS[item.kind] ? tr(ITEM_KIND_LABELS[item.kind]) : item.kind,
            ITEM_REASON_LABELS[item.reason] ? tr(ITEM_REASON_LABELS[item.reason]) : item.reason,
          ])}
        </li>
      {/each}
    </ul>
  {/if}
  {#if view.nodeUnavailable}<p>{tr('The Node is unavailable; the switch stays pending.')}</p>{/if}
  {#if view.error && view.phase !== 'rejected'}<p class="muted">{view.error.message}</p>{/if}
  {#if !lease()}<p class="muted">
      {tr('Take control of the session to switch its environment.')}
    </p>{/if}
  {#each allowedSwitchActions(view, lease()) as action (action)}
    <button
      class="button small"
      type="button"
      disabled={busy || ((action === 'preview' || action === 'review_again') && !target)}
      onclick={() => act(action)}>{label(action)}</button
    >
  {/each}
</section>

<style>
  .environment-switch {
    margin: 0 0 12px;
    font-size: 12px;
  }
  .environment-switch p,
  .environment-switch ul {
    margin: 0 0 6px;
  }
</style>
