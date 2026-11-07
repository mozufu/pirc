<script lang="ts">
  import { tr } from '../../i18n.svelte';

  import { onDestroy } from 'svelte';
  import { app } from '../../app.svelte';
  import { Loader } from '../../loader.svelte';
  import { panelApi, type ContextPanel } from '../../panel-api';
  import { watch } from '../../watch.svelte';
  import EnvironmentSwitchPanel from './EnvironmentSwitchPanel.svelte';
  let {
    sessionId,
    active = true,
    onopenfile = () => {},
  }: { sessionId: string; active?: boolean; onopenfile?: (path: string) => void } = $props();
  let value = $state.raw<ContextPanel>();
  let copied = $state('');
  const loader = new Loader();
  let timer: ReturnType<typeof setTimeout> | undefined;
  async function load() {
    const id = sessionId;
    const next = await loader.run(
      (signal) => panelApi.context(id, signal),
      tr('Unable to load context.'),
    );
    if (id === sessionId && next) value = next;
  }
  watch(
    () => sessionId,
    () => {
      loader.abort();
      value = undefined;
      copied = '';
      clearTimeout(timer);
      if (active) void load();
    },
    { immediate: true },
  );
  watch(
    () => active,
    (shown) => {
      if (shown) void load();
      else {
        loader.abort();
        clearTimeout(timer);
      }
    },
  );
  watch(
    () => app.sessionState?.runnerStatus,
    () => {
      if (active) void load();
    },
  );
  onDestroy(
    app.onPanel((signal) => {
      if (!active || (signal.type !== 'run-finished' && !signal.sections.includes('context')))
        return;
      clearTimeout(timer);
      timer = setTimeout(() => void load(), 150);
    }),
  );
  onDestroy(() => {
    loader.abort();
    clearTimeout(timer);
  });
  const snapshot = $derived(value?.snapshot);
  const segments = $derived(
    snapshot
      ? [
          ...Object.entries(snapshot.usage.buckets).map(([name, estimate]) => ({
            name,
            tokens: estimate * snapshot.usage.scale,
          })),
          { name: 'free', tokens: snapshot.usage.remaining ?? 0 },
        ]
      : [],
  );
  const total = $derived(segments.reduce((sum, item) => sum + item.tokens, 0));
  const tokens = (n: number) => Math.round(n).toLocaleString();
  async function copy() {
    if (!snapshot) return;
    try {
      await navigator.clipboard.writeText(
        snapshot.sections
          .map((s) => s.text)
          .filter(Boolean)
          .join('\n\n'),
      );
      copied = tr('Copied system prompt.');
    } catch {
      copied = tr('Unable to copy. Select the expanded section text instead.');
    }
  }
</script>

<div class="context-tab">
  {#if active}<EnvironmentSwitchPanel {sessionId} />{/if}
  <div class="actions">
    <h3>{tr('Context')}</h3>
    <button class="button ghost" type="button" disabled={loader.loading} onclick={load}
      >{tr('Refresh')}</button
    >
  </div>
  {#if loader.error}<p role="alert">{loader.error}</p>{/if}
  {#if loader.loading && !snapshot}<p role="status">{tr('Loading context…')}</p>{/if}
  {#if snapshot && value}
    {#if !value.agentRunning || value.source === 'snapshot'}<p class="stale" role="status">
        {tr('Saved snapshot{0}. This is the last request, not current configuration.', [
          !value.agentRunning ? tr(' — agent stopped') : '',
        ])}
      </p>{/if}
    <p class="meta">
      {snapshot.model.provider} / {snapshot.model.id}<br /><time
        datetime={new Date(snapshot.takenAt).toISOString()}
        >{new Date(snapshot.takenAt).toLocaleString()}</time
      >
    </p>
    <div
      class="usage-bar"
      role="img"
      aria-label={tr('Context usage: {0}', [
        segments.map((s) => s.name + ' ' + tokens(s.tokens)).join(', '),
      ])}
    >
      {#each segments as segment}<span
          class={segment.name}
          style:width="{total ? (segment.tokens / total) * 100 : 0}%"
          title="{segment.name}: {tokens(segment.tokens)}"
        ></span>{/each}
    </div>
    <ul class="legend">
      {#each segments as segment}<li>
          <i class={segment.name}></i>{segment.name}: {tokens(segment.tokens)}
        </li>{/each}
    </ul>
    <p class="meta">
      {tr('Estimated input: {0} · Reported input: {1}', [
        tokens(snapshot.usage.estimatedInput),
        snapshot.usage.reportedInput === undefined
          ? tr('not available')
          : tokens(snapshot.usage.reportedInput),
      ])}<br />{tr('Context window: {0}', [
        snapshot.model.contextWindow ? tokens(snapshot.model.contextWindow) : tr('unknown'),
      ])}
    </p>
    <p class="meta">
      {tr(
        'Bucket sizes are estimates{0}. Memory is observations/reflections within messages, not an extra copy. System memory stays in system.',
        [
          snapshot.usage.reportedInput === undefined
            ? ''
            : tr(' scaled to reported input (including cache)'),
        ],
      )}
    </p>
    <div class="actions">
      <h4>{tr('System sections')}</h4>
      <button type="button" class="button ghost" onclick={copy}>{tr('Copy all')}</button>
    </div>
    <p role="status">{copied}</p>
    {#each snapshot.sections as section, index (`${index}:${section.id}`)}
      <details>
        <summary
          >{section.title}
          <span class="meta">{tr('~{0} tokens', [tokens(section.estimatedTokens)])}</span
          >{#if section.frozen}<span class="badge">{tr('Frozen')}</span>{/if}</summary
        >
        <p class="source">
          {#if section.filePath !== undefined}<button
              type="button"
              class="link"
              onclick={() => onopenfile(section.filePath!)}>{section.source}</button
            >{:else}{section.source}{/if}
        </p>
        <pre>{section.text}</pre>
      </details>
    {/each}
    <h4>{tr('Model tools ({0})', [snapshot.tools.length])}</h4>
    {#each snapshot.tools as tool (tool.name)}
      <details>
        <summary
          >{tool.name}
          <span class="meta">{tr('~{0} tokens', [tokens(tool.estimatedTokens)])}</span></summary
        >
        <pre>{tool.description}</pre>
        <pre>{JSON.stringify(tool.parameters, null, 2)}</pre>
      </details>
    {/each}
    {#if snapshot.capabilities}
      <h4>{tr('Capabilities ({0})', [snapshot.capabilities.length])}</h4>
      <p class="meta">
        {tr(
          'Called from ptc scripts; the core ones are also tools above. The others are only named in the system prompt, and ptc_docs returns their schemas on request.',
        )}
      </p>
      <ul class="capabilities">
        {#each snapshot.capabilities as capability (capability.name)}
          <li>
            <code>{capability.name}</code>
            <span class="meta"
              >{capability.category} · {capability.effects.join(', ')}{capability.approval !==
              'none'
                ? ` · ${capability.approval}`
                : ''}</span
            >
          </li>
        {/each}
      </ul>
    {/if}
  {/if}
</div>

<style>
  .capabilities {
    display: grid;
    gap: 2px;
    margin: 0;
    padding: 0;
    list-style: none;
  }
  .capabilities li {
    display: flex;
    flex-wrap: wrap;
    align-items: baseline;
    gap: 8px;
  }
  .actions {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
  }
  .meta,
  .source {
    font-size: 12px;
    color: var(--text-2);
    overflow-wrap: anywhere;
  }
  .stale {
    padding: 8px;
    background: var(--bg-hover);
    border-radius: 6px;
  }
  .usage-bar {
    display: flex;
    height: 14px;
    border-radius: 4px;
    overflow: hidden;
    background: var(--line);
  }
  .system {
    background: #6f8de0;
  }
  .tools {
    background: #a37bcd;
  }
  .messages {
    background: #49a18d;
  }
  .memory {
    background: #cf9c50;
  }
  .free {
    background: var(--line);
  }
  .legend {
    display: flex;
    flex-wrap: wrap;
    gap: 6px 12px;
    padding: 0;
    list-style: none;
    font-size: 12px;
  }
  .legend i {
    display: inline-block;
    width: 8px;
    height: 8px;
    margin-right: 4px;
  }
  details {
    padding: 8px 0;
    border-bottom: 1px solid var(--line);
  }
  summary {
    cursor: pointer;
    overflow-wrap: anywhere;
  }
  pre {
    white-space: pre-wrap;
    overflow-wrap: anywhere;
    font-size: 12px;
    line-height: 1.5;
  }
  .badge {
    margin-left: 6px;
    font-size: 10px;
    padding: 2px 5px;
    border: 1px solid var(--line);
    border-radius: 4px;
  }
  .link {
    font: inherit;
    color: var(--accent);
    text-align: left;
    overflow-wrap: anywhere;
    background: none;
    border: 0;
    padding: 0;
    cursor: pointer;
  }
  [role='alert'] {
    color: var(--danger);
  }
</style>
