<script lang="ts">
  /** Throwaway wiring of the environment-switch interface; the new UI replaces it. */
  import { onDestroy } from 'svelte';
  import { app } from '../../app.svelte';
  import {
    allowedSwitchActions,
    BLOCKER_LABELS,
    CANCEL_PENDING_LABELS,
    needsReauthorization,
    READINESS_LABELS,
    readinessOf,
    WAIT_REASON_LABELS,
    EnvironmentSwitch,
    ITEM_KIND_LABELS,
    ITEM_REASON_LABELS,
    type RevocationItem,
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
      else if (current && action === 'reauthorize') await flow?.reauthorize(current);
      else if (action === 'reconcile') await flow?.reconcile();
      else if (action === 'more_items') await flow?.loadMoreItems();
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
      case 'review_required':
        return tr('This switch can no longer be sent as reviewed ({0}). Cancel it.', [
          reasonLabel(s.status?.progress?.waitReason),
        ]);
      case 'authority_required':
        return tr('The permission to finish this switch lapsed. Reauthorize or cancel.');
      case 'cancel_pending': {
        // The Node outcome was unknown when the user cancelled: nothing is proven
        // until the Node answers, so the conversation stays locked meanwhile.
        if (s.status?.cancellation?.void?.state === 'pending')
          return tr(
            'Cancelling: waiting for the Node to confirm this switch never started. The conversation stays locked until then ({0}).',
            [reasonLabel(s.status.progress?.waitReason ?? 'node_unavailable')],
          );
        const reason = s.status?.progress?.cancellation?.pendingReason;
        return reason
          ? tr('Cancellation pending: {0}.', [
              CANCEL_PENDING_LABELS[reason] ? tr(CANCEL_PENDING_LABELS[reason]) : reason,
            ])
          : tr('Cancellation requested; waiting for the Node.');
      }
      case 'review_blocked':
        return tr('This switch is blocked:');
      case 'review_stale':
        return tr('The environment changed since this review. Review again.');
      case 'switching_disabled':
        return tr('Environment switching is disabled on this Gateway.');
      case 'awaiting_dispatch':
        return tr('Accepted; the Node has not been asked yet.');
      case 'outcome_unknown':
        // A hint, never a verdict: the Node may still receive the request. Cancel
        // is offered, and only the user's cancel ends it.
        return s.status?.progress?.waitReason
          ? tr('The Node has not confirmed this switch ({0}). You can cancel it.', [
              reasonLabel(s.status.progress.waitReason),
            ])
          : tr('Checking whether the Node fenced the conversation…');
      case 'draining':
        return tr("Stopping the conversation's current work…");
      case 'blocked':
        return tr('Some work could not be confirmed stopped. It cannot be acknowledged:');
      case 'needs_acknowledgement':
        return tr('These records cannot prove that access is gone:');
      case 'installing':
        return tr('Installing the new environment…');
      case 'switched': {
        const revocationText =
          s.result === 'revocation_confirmed'
            ? tr('Switched; revocation confirmed.')
            : tr('Switched; revocation not fully confirmed.');
        const ready = readinessOf(s.status);
        // Until the runtime is ready, say so; a failed start keeps the new binding.
        return ready && ready !== 'ready' && READINESS_LABELS[ready]
          ? `${revocationText} ${tr(READINESS_LABELS[ready])}`
          : revocationText;
      }
      case 'cancelled':
        return s.result === 'cancelled_unchanged'
          ? tr('Switch cancelled — nothing was changed on the Node.')
          : tr('Cancelled; original workspace kept.');
      case 'deleted':
        return tr('The conversation was deleted.');
      case 'reconciliation_required':
        return tr('An environment change needs reconciliation ({0}).', [
          reasonLabel(s.recoveryReason),
        ]);
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
      reauthorize: tr('Reauthorize'),
      reconcile: tr('Reconcile'),
      more_items: tr('Show all items'),
      discard: tr('Dismiss'),
    })[action];
  const reasonLabel = (code: string | null | undefined) =>
    code ? (WAIT_REASON_LABELS[code] ? tr(WAIT_REASON_LABELS[code]) : code) : '—';
  const itemText = (item: RevocationItem) => {
    const base = tr('{0}: {1}', [
      ITEM_KIND_LABELS[item.kind] ? tr(ITEM_KIND_LABELS[item.kind]) : item.kind,
      ITEM_REASON_LABELS[item.reason] ? tr(ITEM_REASON_LABELS[item.reason]) : item.reason,
    ]);
    if (!item.inherited) return base;
    return item.generation === null
      ? tr('{0} (inherited from earlier, unattributed history)', [base])
      : tr('{0} (inherited from generation {1})', [base, item.generation]);
  };
  const shown = $derived(
    view.evaluation && view.evaluation.evaluationId === revocationOf(view)?.evaluationId
      ? view.evaluation.items
      : (revocationOf(view)?.items ?? []),
  );
  function revocationOf(s: SwitchState) {
    return s.status?.progress?.revocation;
  }
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
  {#if view.phase === 'review' && view.preview}
    <p>
      {view.preview.operationAuthority.available
        ? tr('If no device holds control, the Gateway may finish this switch for {0} seconds.', [
            view.preview.operationAuthority.durationSeconds ?? 0,
          ])
        : tr('The switch continues only while a device holds control.')}
    </p>
  {/if}
  {#if view.status?.authority && needsReauthorization(view)}<p>
      {tr('Operation authority {0} (revision {1}).', [
        view.status.authority.state,
        view.status.authority.revision,
      ])}
    </p>{/if}
  {#if view.error?.reason === 'void_unsupported'}<p>
      {tr('The Node must be upgraded before a switch whose outcome is unknown can be cancelled.')}
    </p>{/if}
  {#if view.error?.reason === 'plan_changed'}<p>
      {tr('The reviewed environment changed; a new transition is needed.')}
    </p>{/if}
  {#if view.reconciliation}<p class="muted">
      {tr('Last reconciliation: {0}', [view.reconciliation])}
    </p>{/if}
  {#if view.lastFinished && view.phase === 'idle'}<p class="muted">
      {view.lastFinished.state === 'installed'
        ? tr('Last switch: installed.')
        : tr('Last switch: cancelled.')}
    </p>{/if}
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
    <p>
      {tr('All retained risks: {0}. This generation: {1}.', [
        revocation.status,
        revocation.currentGeneration?.status ?? '—',
      ])}
    </p>
    <ul class="items">
      {#each shown as item, index (index)}
        <li>{itemText(item)}</li>
      {/each}
    </ul>
    {#if view.phase === 'needs_acknowledgement'}<p>
        {tr('Acknowledging covers all {0} items, not only those shown.', [revocation.itemsTotal])}
      </p>{/if}
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
