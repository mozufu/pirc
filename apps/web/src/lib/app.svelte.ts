import { tr } from './i18n.svelte';
import {
  FirstSend,
  DraftConflict,
  editsRecovered,
  sameDraftInput,
  firstContractCompatible,
  firstContractBlocked,
  firstTransport,
  draftScope,
  type FirstDraft,
  type FirstCapabilities,
} from './first-send';
import { BrowserDraftStore } from './first-send-storage';
/**
 * Session-wide client state: the gateway's workspaces, nodes and sessions, the
 * open session and its event stream, the draft and uploads, and every command
 * the UI sends. Components read it directly instead of receiving it as props.
 */
import { api, connectEvents, ApiError, type EventConnection } from './api';
import type { NewWorkspace } from './chats';
import { isReadOnly, modeOf, tabOf } from './modes';
import { memoryApi, type MemoryProposal } from './memory';
import {
  projectDeletionApi,
  type ProjectMemoryDecision,
  type ProjectProposalDecision,
} from './project-deletion';
import { schedulesApi, type Schedule, type ScheduleRun } from './schedules';
import {
  interactionFromUrl,
  isPushInteraction,
  targetFromUrl,
  type PushInteraction,
  type PushTarget,
} from './push';
import { syncControl } from './control';
import { conversationBinding } from './conversation-binding';
import { isBindingRefusal } from './environment-transitions';
import { errorMessage } from './errors';
import { GOAL_WIDGET, parseGoalWidget } from './goal';
import { PanelStateResource } from './panel-state.svelte';
import { fromSnapshot, reduceEvent } from './state';
import { uuid } from './id';
import {
  getClientId,
  loadDraft,
  loadLayout,
  pruneDrafts,
  removeDraft,
  saveDraft,
  saveLayout,
} from './storage';
import { needsInput } from './work';
import { parseTodoWidget, TODO_WIDGET } from './todo';
import type {
  ApprovalMode,
  Attachment,
  ClientSessionState,
  CommandKind,
  ConnectionState,
  InteractionAnswer,
  ModeInfo,
  ModelOption,
  NodeSummary,
  QueueItem,
  RelayedApproval,
  SessionSummary,
  SessionUpdateInput,
  ThinkingLevel,
  Workspace,
} from './types';
import { isRelayed, modelKey } from './types';

export type Upload = Attachment & { preview?: string; uploading?: boolean };

/**
 * The sidebar's two lists: the assistant's chats, or the agents' work. A
 * workspace's mode decides its list (`tabOf`).
 */
export type SidebarMode = 'chat' | 'work';
/** What the main column shows: a session, the schedules, or a project's or workspace's page. */
export type MainView = 'session' | 'schedules' | 'workspace' | 'pots';

/** Something waiting for you, shown under "Needs you". */
export type InboxItem =
  | { kind: 'session'; id: string; session: SessionSummary }
  | { kind: 'missed'; id: string; schedule: Schedule; run: ScheduleRun }
  | { kind: 'memory'; id: string; proposal: MemoryProposal };

/** Side-panel refresh signals: a `panel_changed` event, or the end of a run. */
export type PanelSignal = { type: 'changed'; sections: string[] } | { type: 'run-finished' };

/** The timeline registers itself so incoming events can keep the newest entry in view. */
export interface Scroller {
  /** Scroll to the newest entry and keep following new content. */
  toLatest(smooth?: boolean): Promise<void>;
}

type Demo = typeof import('./mock');

/**
 * A long transcript is rendered from the end: opening a session mounts only
 * the newest `MESSAGE_PAGE` entries (each one parses Markdown synchronously).
 */
export const MESSAGE_PAGE = 60;

/** Returning after this long in the background reloads the open session's snapshot. */
const RESUME_SNAPSHOT_AFTER = 15_000;

const DOCKED_WIDGETS = new Set([TODO_WIDGET, GOAL_WIDGET]);
/**
 * Status-line entries not already shown elsewhere: background tasks and team
 * members live in the jobs menu. Other extension widgets show their header.
 */
const SHOWN_ELSEWHERE = new Set(['background-task', 'agent-team']);

class AppState {
  workspaces = $state.raw<Workspace[]>([]);
  nodes = $state.raw<NodeSummary[]>([]);
  /** The gateway's workspace modes (empty from older gateways: the legacy `kind` decides). */
  modeCatalog = $state.raw<ModeInfo[]>([]);
  /** USER changes the assistant proposed that wait for your approval. */
  memoryPending = $state(0);
  /** Bumped whenever the gateway says your memory changed; open memory views reload. */
  memoryRevision = $state(0);
  /** Scheduled runs waiting for you: missed ones to allow, ones waiting for an answer. */
  scheduleAttention = $state(0);
  /** Bumped whenever the gateway says your schedules changed; open schedule views reload. */
  scheduleRevision = $state(0);
  /**
   * A place in Settings to show (the memory), asked for by a notification or
   * a `?open=` link (App opens Settings on it, then clears it).
   */
  requestedTarget = $state<Exclude<PushTarget, { sessionId: string }> | undefined>();
  /** The schedule a notification was about; the Schedules page opens it once. */
  scheduleFocus = $state<string | undefined>();
  /** A calendar reminder target is consumed by the Calendar page after it mounts. */
  calendarFocus = $state<
    | {
        eventId: string;
        occurrenceStart?: string;
        date?: string;
        startAt?: number;
      }
    | undefined
  >();
  /** Bumped whenever the user or a reminder explicitly navigates to Calendar. */
  calendarNavigationRevision = $state(0);
  sessions = $state.raw<SessionSummary[]>([]);
  /** Your schedules (the Schedules entry shows the next run). */
  schedules = $state.raw<Schedule[]>([]);
  /** Missed scheduled runs waiting for you to allow or dismiss them. */
  missedRuns = $state.raw<Array<{ schedule: Schedule; run: ScheduleRun }>>([]);
  /** USER memory changes the assistant proposed, waiting for your approval. */
  memoryProposals = $state.raw<MemoryProposal[]>([]);
  /** Chat or Work; remembered. */
  mode = $state<SidebarMode>(loadLayout('workMode', false) ? 'work' : 'chat');
  view = $state<MainView>('session');
  /** The project or workspace whose page is showing (view `workspace`). */
  workspaceViewId = $state<string>();
  models = $state.raw<ModelOption[]>([]);
  activeSessionId = $state<string>();
  connection = $state<ConnectionState>(navigator.onLine ? 'reconnecting' : 'offline');
  firstCapabilities = $state.raw<FirstCapabilities>();
  firstDraft = $state.raw<FirstDraft>();
  firstRecoveries = $state.raw<FirstDraft[]>([]);
  firstControlBusy = $state(false);
  #firstScope = '';
  #firstAccountRevision = 0;
  #firstOpenIntent = 0;
  #firstRevisions = new Map<string, number>();
  #firstWrites = Promise.resolve();
  #firstEditor?: { conflicted: boolean; recovery?: FirstDraft; serial: number; committed: number };
  readonly firstFlow = new FirstSend(new BrowserDraftStore(), firstTransport, (row, id, scope) => {
    const key = JSON.stringify([scope, id]);
    if (row) this.#firstRevisions.set(key, row.revision);
    else this.#firstRevisions.delete(key);
    if (scope !== this.#firstScope) return;
    this.firstRecoveries = [
      ...(row && (row.message || row.files.length || row.frozen) ? [row] : []),
      ...this.firstRecoveries.filter((item) => item.operationId !== id),
    ];
    if (this.firstDraft?.operationId !== id) return;
    this.firstDraft = row;
    if (row?.preparation?.accepted && this.sessionState) {
      this.activeSessionId = row.preparation.sessionId;
      this.sessionState = {
        ...this.sessionState,
        session: { ...this.sessionState.session, id: row.preparation.sessionId },
      };
      this.#address(`?session=${encodeURIComponent(row.preparation.sessionId)}`);
      void this.refreshSessions();
    }
  });
  get firstEnabled() {
    return !!(
      !this.demo &&
      this.firstCapabilities?.canSubmit &&
      firstContractCompatible(this.firstCapabilities) &&
      this.firstCapabilities.canFenceAccount &&
      this.firstCapabilities.ownerUser
    );
  }
  async initializeFirstSend() {
    const revision = ++this.#firstAccountRevision;
    try {
      let caps = await this.firstFlow.transport.capabilities();
      if (revision !== this.#firstAccountRevision) return;
      if (
        this.#firstScope &&
        (firstContractCompatible(this.firstCapabilities) ||
          firstContractBlocked(this.firstCapabilities) ||
          this.firstDraft?.scope === this.#firstScope) &&
        !firstContractCompatible(caps)
      ) {
        // A bound modern operation cannot downgrade to a legacy replacement,
        // even when an older server successfully returns its gated capabilities.
        caps = {
          ...caps,
          canSubmit: false,
          clientContract: caps.clientContract ?? 0,
          requiredClientContract: caps.requiredClientContract ?? 2,
        };
      }
      const scope =
        caps.ownerUser && caps.canFenceAccount ? draftScope(location.origin, caps.ownerUser) : '';
      if (this.#firstScope && scope !== this.#firstScope) {
        this.discardDraftSession();
        this.#events?.close();
        this.#events = undefined;
        this.sessionState = undefined;
        this.activeSessionId = undefined;
        this.draft = '';
        this.uploads = [];
        this.firstRecoveries = [];
      }
      this.#firstScope = scope;
      this.firstCapabilities = caps;
      if (scope) {
        const records = await this.firstFlow.store.list(scope);
        if (scope === this.#firstScope)
          this.firstRecoveries = records.filter((r) => r.message || r.files.length || r.frozen);
      }
    } catch (error) {
      if (revision !== this.#firstAccountRevision) return;
      if (error instanceof ApiError && (error.status === 404 || error.status === 501)) {
        // Cold legacy support never restores unauthenticated private drafts.
        // An already-bound window keeps its input, but cannot switch that
        // operation to legacy creation after a server rollback.
        this.firstCapabilities = this.#firstScope
          ? {
              ...this.firstCapabilities!,
              canSubmit: false,
              clientContract: 0,
              requiredClientContract: 2,
            }
          : { version: 0, canSubmit: false };
      }
      if (error instanceof ApiError && (error.status === 401 || error.status === 403)) {
        this.discardDraftSession();
        this.#events?.close();
        this.#events = undefined;
        this.firstCapabilities = undefined;
        this.firstRecoveries = [];
        this.#firstScope = '';
        this.sessionState = undefined;
        this.activeSessionId = undefined;
        this.draft = '';
        this.uploads = [];
      }
      // A transient offline check keeps existing local content; an authenticated
      // capability response is needed before restoring private drafts cold.
    }
  }

  #firstValue() {
    const model = this.selectedModelOption;
    return {
      workspaceId: this.draftWorkspaceId!,
      message: this.draft,
      model: model ? { provider: model.provider, id: model.id } : undefined,
      thinking: this.thinking,
      files: this.uploads.map((item) => {
        const blob = this.#draftFiles.get(item.id);
        if (!blob) throw new Error(tr('The original attachment is missing from local storage.'));
        return {
          id: item.id,
          name: item.name,
          mimeType: blob.type || 'application/octet-stream',
          byteSize: blob.size,
          blob,
        };
      }),
    };
  }
  #saveFirstDraft() {
    const draft = this.firstDraft;
    if (!draft || draft.frozen || draft.scope !== this.#firstScope) return this.#firstWrites;
    let value: Pick<FirstDraft, 'workspaceId' | 'message' | 'model' | 'thinking' | 'files'>;
    try {
      value = this.#firstValue();
    } catch (error) {
      return Promise.reject(error);
    }
    const editor = (this.#firstEditor ??= { conflicted: false, serial: 0, committed: 0 });
    const serial = ++editor.serial;
    const write = this.#firstWrites.then(async () => {
      if (!editor.conflicted) {
        try {
          const revision =
            this.#firstRevisions.get(JSON.stringify([draft.scope, draft.operationId])) ??
            (draft.revision || undefined);
          await this.firstFlow.save(
            draft.scope,
            draft.ownerUser,
            draft.operationId,
            value,
            revision,
          );
          editor.committed = serial;
          return;
        } catch (error) {
          if (!(error instanceof DraftConflict)) throw error;
          const latest = await this.firstFlow.store.get(draft.scope, draft.operationId);
          if (latest && sameDraftInput(value, latest)) {
            editor.committed = serial;
            if (this.#firstEditor === editor && this.firstDraft?.operationId === draft.operationId)
              this.firstDraft = latest;
            return;
          }
          editor.conflicted = true;
        }
      }
      editor.recovery = await this.firstFlow.recoverEdits(draft, value, editor.recovery);
      editor.committed = serial;
      if (this.#firstEditor === editor && this.firstDraft?.operationId === draft.operationId) {
        // Refresh shared facts only after the unsent private input is durable.
        const latest = await this.firstFlow.store.get(draft.scope, draft.operationId);
        if (this.#firstEditor === editor && latest) this.firstDraft = latest;
        this.pageError = tr(editsRecovered);
      }
    });
    this.#firstWrites = write.catch((error) => {
      if (this.firstDraft?.operationId === draft.operationId)
        this.pageError = errorMessage(error, tr('Local draft save failed. Your message is kept.'));
    });
    return write;
  }
  async #saveBeforeFirstNavigation() {
    if (!this.firstDraft) return true;
    const selection = this.#openSeq,
      editor = this.#firstEditor;
    try {
      if (!this.firstDraft.frozen) await this.#saveFirstDraft();
      await this.#firstWrites;
      if (editor && editor.serial !== editor.committed)
        throw new Error(tr('Local draft save failed. Your message is kept.'));
      return selection === this.#openSeq;
    } catch (error) {
      if (selection === this.#openSeq) this.#firstError(error);
      return false;
    }
  }
  async resumeFirst(row: FirstDraft) {
    if (row.scope !== this.#firstScope) return;
    if (this.firstDraft && !(await this.#saveBeforeFirstNavigation())) return;
    const selection = this.#openSeq;
    const current = await this.firstFlow.store.get(row.scope, row.operationId);
    if (!current || current.scope !== this.#firstScope || selection !== this.#openSeq) return;
    if (current.preparation?.state === 'admitted') {
      await this.firstFlow.forget(current.scope, current.operationId);
      await this.openSession(current.preparation.sessionId, { skipFirst: true });
      return;
    }
    await this.createSession(current.workspaceId, current);
  }
  async #finishFirst(row: FirstDraft, selection: number) {
    if (
      row.scope !== this.#firstScope ||
      this.firstDraft?.operationId !== row.operationId ||
      selection !== this.#openSeq
    )
      return;
    if (row.preparation?.state === 'admitted') {
      await this.#firstWrites;
      if (this.#firstEditor && this.#firstEditor.serial !== this.#firstEditor.committed)
        throw new Error(tr('Local draft save failed. Your message is kept.'));
      if (row.scope !== this.#firstScope || selection !== this.#openSeq) return;
      const id = row.preparation.sessionId;
      await this.firstFlow.forget(row.scope, row.operationId);
      if (row.scope !== this.#firstScope || selection !== this.#openSeq) return;
      this.draftWorkspaceId = undefined;
      this.firstDraft = undefined;
      this.#draftFiles.clear();
      this.uploads = [];
      this.draft = '';
      await this.openSession(id, { skipFirst: true });
    }
  }
  #firstError(error: unknown) {
    this.pageError = errorMessage(
      error,
      tr('The first message is saved. Check its result before continuing.'),
    );
    if (error instanceof ApiError && error.code === 'account_changed') {
      this.discardDraftSession();
      this.sessionState = undefined;
      this.activeSessionId = undefined;
      this.firstCapabilities = undefined;
      this.firstRecoveries = [];
      this.#firstScope = '';
      void this.bootstrap();
    }
  }
  async continueFirst() {
    const draft = this.firstDraft,
      selection = this.#openSeq;
    if (!draft || !this.firstEnabled || this.commandBusy) return;
    this.commandBusy = true;
    this.pageError = '';
    try {
      if (!draft.frozen) await this.#saveFirstDraft();
      if (this.#firstEditor?.conflicted) {
        this.pageError = tr(editsRecovered);
        return;
      }
      const row = draft.cancelRequested
        ? await this.firstFlow.discard(draft.scope, draft.operationId)
        : await this.firstFlow.run(draft.scope, draft.operationId, this.firstDraft?.revision);
      if (row) await this.#finishFirst(row, selection);
    } catch (error) {
      if (draft.scope === this.#firstScope && selection === this.#openSeq) this.#firstError(error);
    } finally {
      this.commandBusy = false;
    }
  }
  async retryFirst() {
    const draft = this.firstDraft,
      selection = this.#openSeq;
    if (!draft || this.firstControlBusy || this.commandBusy) return;
    this.firstControlBusy = true;
    try {
      await this.#finishFirst(
        await this.firstFlow.retry(draft.scope, draft.operationId),
        selection,
      );
    } catch (error) {
      if (draft.scope === this.#firstScope && selection === this.#openSeq) this.#firstError(error);
    } finally {
      this.firstControlBusy = false;
    }
  }
  async recoverFirstRetry() {
    const draft = this.firstDraft,
      selection = this.#openSeq;
    if (!draft || this.firstControlBusy || this.commandBusy) return;
    this.firstControlBusy = true;
    try {
      await this.firstFlow.recoverRetry(draft.scope, draft.operationId);
    } catch (error) {
      if (draft.scope === this.#firstScope && selection === this.#openSeq) this.#firstError(error);
    } finally {
      this.firstControlBusy = false;
    }
  }
  async checkFirst() {
    const draft = this.firstDraft,
      selection = this.#openSeq;
    if (!draft || this.firstControlBusy) return;
    this.firstControlBusy = true;
    try {
      await this.firstFlow.check(draft.scope, draft.operationId);
    } catch (error) {
      if (draft.scope === this.#firstScope && selection === this.#openSeq) this.#firstError(error);
    } finally {
      this.firstControlBusy = false;
    }
  }
  async takeFirstControl() {
    const row = this.firstDraft,
      selection = this.#openSeq;
    if (!row || this.firstControlBusy) return;
    this.firstControlBusy = true;
    try {
      await this.firstFlow.takeControl(row.scope, row.operationId);
    } catch (error) {
      if (row.scope === this.#firstScope && selection === this.#openSeq) this.#firstError(error);
    } finally {
      this.firstControlBusy = false;
    }
  }
  async stopFirst() {
    const draft = this.firstDraft,
      selection = this.#openSeq;
    if (!draft || this.firstControlBusy) return;
    this.firstControlBusy = true;
    try {
      await this.#finishFirst(await this.firstFlow.stop(draft.scope, draft.operationId), selection);
    } catch (error) {
      if (draft.scope === this.#firstScope && selection === this.#openSeq) this.#firstError(error);
    } finally {
      this.firstControlBusy = false;
    }
  }
  async openStoppedFirst() {
    const row = this.firstDraft,
      selection = this.#openSeq;
    if (!row || this.firstControlBusy) return;
    if (row.preparation?.state === 'admitted') {
      await this.#finishFirst(row, selection);
      return;
    }
    if (!row.preparation?.messageAdmission?.stopConfirmed) return;
    this.firstControlBusy = true;
    try {
      const result = await this.firstFlow.release(row.scope, row.operationId);
      if (
        row.scope !== this.#firstScope ||
        selection !== this.#openSeq ||
        this.firstDraft?.operationId !== row.operationId
      )
        return;
      if (!(await this.#saveBeforeFirstNavigation())) return;
      this.discardDraftSession();
      await this.openSession(result.preparation!.sessionId, { skipFirst: true });
    } catch (error) {
      if (row.scope === this.#firstScope && selection === this.#openSeq) this.#firstError(error);
    } finally {
      this.firstControlBusy = false;
    }
  }
  async dismissFirst(row: FirstDraft) {
    const current = this.firstDraft?.operationId === row.operationId,
      selection = this.#openSeq;
    await this.firstFlow.forget(row.scope, row.operationId);
    if (current && selection === this.#openSeq && row.scope === this.#firstScope)
      this.discardDraftSession();
  }
  async discardFirst(row = this.firstDraft) {
    if (!row || row.scope !== this.#firstScope) return;
    const current = this.firstDraft?.operationId === row.operationId,
      selection = this.#openSeq;
    const result = await this.firstFlow.discard(row.scope, row.operationId);
    if (
      !result ||
      (result.preparation?.state === 'cancelled' && !result.preparation.cleanupPending)
    )
      await this.firstFlow.forget(row.scope, row.operationId);
    if (current && selection === this.#openSeq && row.scope === this.#firstScope)
      this.discardDraftSession();
  }
  draft = $state('');
  /** Local conversation; the negotiated first-send flow also persists its private draft. */
  draftWorkspaceId = $state<string>();
  #draftFiles = new Map<string, File>();
  get isDraftSession() {
    return this.draftWorkspaceId !== undefined;
  }

  discardDraftSession() {
    if (!this.isDraftSession) return;
    const pendingFirst = this.firstDraft;
    this.firstDraft = undefined;
    this.#firstEditor = undefined;
    if (
      pendingFirst &&
      !pendingFirst.frozen &&
      !pendingFirst.message &&
      !pendingFirst.files.length
    ) {
      void this.#firstWrites
        .then(() => this.firstFlow.pruneEmpty(pendingFirst.scope, pendingFirst.operationId))
        .catch(() => undefined);
    }
    this.draftWorkspaceId = undefined;
    this.#draftFiles.clear();
    this.uploads.forEach((item) => item.preview && URL.revokeObjectURL(item.preview));
    this.uploads = [];
    this.draft = '';
    this.activeSessionId = undefined;
    this.sessionState = undefined;
    ++this.#openSeq;
  }
  uploads = $state.raw<Upload[]>([]);
  loading = $state(true);
  commandBusy = $state(false);
  pageError = $state('');
  interactionNotice = $state('');
  answeringInteractionIds = $state.raw<string[]>([]);
  /** Offline demo data (dev builds without a gateway). */
  demo = $state.raw<Demo>();
  /** Earliest transcript entries not yet mounted. */
  hiddenMessages = $state(0);
  clientId = '';
  /** `/panel/state` of the open session (jobs menu, Memory and Tasks tabs). */
  readonly panel = new PanelStateResource();

  #sessionState = $state.raw<ClientSessionState>();
  #events: EventConnection | undefined;
  #controlSyncing: { id: string; promise: Promise<void> } | undefined;
  /** Bumped per openSession; a slower, superseded open must not apply its result. */
  #openSeq = 0;
  /** Local list changes invalidate session lists fetched before them. */
  #sessionsVersion = 0;
  #sessionsRequest = 0;
  /** Snapshot requests coalesce per open session, so old requests cannot block a new one. */
  #snapshotLoading = new Set<number>();
  #draftTimer: ReturnType<typeof setTimeout> | undefined;
  #draftPending: { sessionId: string; value: string } | undefined;
  #snapshotAgain = new Set<number>();
  #panelListeners = new Set<(signal: PanelSignal) => void>();
  /** The start could not reach the gateway (e.g. an offline cold start from the cached shell). */
  #bootstrapFailed = false;
  scroller: Scroller | undefined;

  get usingDemo() {
    return !!this.demo;
  }

  get sessionState() {
    return this.#sessionState;
  }
  set sessionState(next: ClientSessionState | undefined) {
    const before = this.#sessionState;
    this.#sessionState = next;
    // A finished run may have changed the working tree and memory.
    if (
      before &&
      next &&
      before.session.id === next.session.id &&
      before.run?.status === 'running' &&
      next.run?.status !== 'running'
    )
      this.#emitPanel({ type: 'run-finished' });
  }

  activeWorkspace = $derived(
    this.workspaces.find((workspace) => workspace.id === this.#sessionState?.session.workspaceId),
  );
  runStatus = $derived(this.#sessionState?.run?.status);
  hasControl = $derived(this.#sessionState?.control.heldByCurrentClient ?? false);
  generation = $derived(this.#sessionState?.control.generation);
  selectedModelOption = $derived(
    this.models.find(
      (model) =>
        model.id === this.#sessionState?.selectedModelId &&
        (!this.#sessionState?.selectedModelProvider ||
          model.provider === this.#sessionState.selectedModelProvider),
    ) ?? this.models[0],
  );
  selectedModel = $derived(this.selectedModelOption ? modelKey(this.selectedModelOption) : '');
  thinking = $derived<ThinkingLevel>(this.#sessionState?.thinkingLevel ?? 'medium');
  /** The session's approval mode as its node last reported it (undefined: unknown). */
  approvalMode = $derived<ApprovalMode | undefined>(this.#sessionState?.approvalMode);
  defaultApprovalMode = $derived<ApprovalMode | undefined>(this.#sessionState?.defaultApprovalMode);
  todo = $derived(parseTodoWidget(this.#sessionState?.widgets?.[TODO_WIDGET]));
  goal = $derived(parseGoalWidget(this.#sessionState?.widgets?.[GOAL_WIDGET]));
  statusLine = $derived([
    ...Object.entries(this.#sessionState?.widgets ?? {})
      .filter(([key, lines]) => !DOCKED_WIDGETS.has(key) && lines.length)
      .map(([, lines]) => lines[0]!),
    ...Object.entries(this.#sessionState?.statuses ?? {})
      .filter(([key, text]) => !SHOWN_ELSEWHERE.has(key) && text)
      .map(([, text]) => text),
  ]);
  pendingInteractions = $derived(
    this.#sessionState?.interactions.filter((item) => item.status === 'pending') ?? [],
  );
  /** Delegations the open chat started that still run or wait for you. */
  delegations = $derived(this.#sessionState?.delegations ?? []);
  /** Commands need a live connection and the control lease. */
  canCommand = $derived(this.hasControl && this.connection === 'connected');
  #historyRevision = 0;
  #historyNeedsRefresh = $state<string>();
  canChangeBranch = $derived(
    this.#historyNeedsRefresh !== this.activeSessionId &&
      this.canCommand &&
      !this.demo &&
      !this.commandBusy &&
      !this.#sessionState?.partialMessage &&
      !['queued', 'running', 'waiting_input', 'stopping'].includes(this.runStatus ?? '') &&
      this.#sessionState?.runnerStatus !== 'starting',
  );

  /** Everything waiting for you: questions, missed runs, memory proposals. */
  inbox = $derived<InboxItem[]>([
    ...this.sessions
      .filter(
        (session) =>
          needsInput(session) ||
          // Its confirm waits in the chat that delegated it.
          (session.origin?.kind === 'delegation' && !!session.origin.approval),
      )
      .map((session) => ({ kind: 'session' as const, id: `session:${session.id}`, session })),
    ...this.missedRuns.map(({ schedule, run }) => ({
      kind: 'missed' as const,
      id: `run:${run.id}`,
      schedule,
      run,
    })),
    ...this.memoryProposals.map((proposal) => ({
      kind: 'memory' as const,
      id: `memory:${proposal.id}`,
      proposal,
    })),
  ]);
  /** The soonest run of an active schedule. */
  nextSchedule = $derived(
    this.schedules
      .filter((schedule) => schedule.status === 'active' && schedule.nextRunAt)
      .sort((a, b) => a.nextRunAt! - b.nextRunAt!)[0],
  );

  setMode(mode: SidebarMode) {
    this.mode = mode;
    saveLayout('workMode', mode === 'work');
  }

  /** Open the owner-scoped pots inbox; viewing never starts work or takes control. */
  async showPots() {
    const intent = ++this.#firstOpenIntent;
    if (
      this.firstDraft &&
      (!(await this.#saveBeforeFirstNavigation()) || intent !== this.#firstOpenIntent)
    )
      return;
    this.discardDraftSession();
    this.view = 'pots';
    this.#address('?open=pots');
  }

  /** Show the schedules in the main column, optionally opening one. */
  async showSchedules(scheduleId?: string) {
    const intent = ++this.#firstOpenIntent;
    if (
      this.firstDraft &&
      (!(await this.#saveBeforeFirstNavigation()) || intent !== this.#firstOpenIntent)
    )
      return;
    this.discardDraftSession();
    this.calendarFocus = undefined;
    if (scheduleId) this.scheduleFocus = scheduleId;
    this.view = 'schedules';
  }

  /** Show the Calendar, optionally at the occurrence named by a reminder. */
  async showCalendar(eventId?: string, occurrenceStart?: string, date?: string, startAt?: number) {
    const intent = ++this.#firstOpenIntent;
    if (
      this.firstDraft &&
      (!(await this.#saveBeforeFirstNavigation()) || intent !== this.#firstOpenIntent)
    )
      return;
    this.discardDraftSession();
    this.scheduleFocus = undefined;
    this.calendarNavigationRevision++;
    this.calendarFocus = eventId
      ? {
          eventId,
          ...(occurrenceStart ? { occurrenceStart } : {}),
          ...(date ? { date } : {}),
          ...(startAt !== undefined ? { startAt } : {}),
        }
      : undefined;
    this.view = 'schedules';
    if (eventId) {
      const query = new URLSearchParams({ open: 'calendar', event: eventId });
      if (occurrenceStart) query.set('occurrence', occurrenceStart);
      if (date) query.set('date', date);
      if (startAt !== undefined) query.set('startAt', String(startAt));
      this.#address(`?${query.toString()}`);
    } else {
      const query = new URLSearchParams(location.search);
      for (const key of [
        'event',
        'occurrence',
        'startAt',
        'item',
        'manage',
        'schedule',
        'newSchedule',
        'session',
        'interactionId',
        'interactionEpoch',
      ])
        query.delete(key);
      query.set('open', 'calendar');
      this.#address(`?${query.toString()}`);
    }
  }

  /**
   * Show a project's or workspace's page: its sessions and its settings. The
   * open session stays connected behind it, so going back is instant.
   */
  async showWorkspace(workspaceId: string) {
    const intent = ++this.#firstOpenIntent;
    if (
      this.firstDraft &&
      (!(await this.#saveBeforeFirstNavigation()) || intent !== this.#firstOpenIntent)
    )
      return;
    this.discardDraftSession();
    const workspace = this.workspaces.find((item) => item.id === workspaceId);
    if (!workspace) return;
    // The sidebar shows the list the page belongs to.
    this.setMode(tabOf(workspace, this.modeCatalog));
    this.workspaceViewId = workspaceId;
    this.view = 'workspace';
    this.#address(`?workspace=${encodeURIComponent(workspaceId)}`);
  }

  /** The address names what is on screen: a reload or a shared link comes back to it. */
  #address(search: string) {
    if (!this.demo && typeof history !== 'undefined')
      history.replaceState(history.state, '', search);
  }

  /**
   * Clear the open session's unread mark (on every device) while you are
   * looking at it: the page is visible and the session is on screen.
   */
  markActiveRead() {
    const id = this.activeSessionId;
    if (!id || this.view !== 'session') return;
    if (typeof document !== 'undefined' && document.visibilityState === 'hidden') return;
    const session = this.sessions.find((item) => item.id === id);
    if (!session?.unread) return;
    this.sessions = this.sessions.map((item) =>
      item.id === id ? { ...item, unread: false } : item,
    );
    this.#sessionsVersion++;
    if (!this.demo) void api.markRead(id).catch(() => undefined);
  }

  /** Listen for side-panel refresh signals. Returns the unsubscribe function. */
  onPanel(listener: (signal: PanelSignal) => void): () => void {
    this.#panelListeners.add(listener);
    return () => this.#panelListeners.delete(listener);
  }
  #emitPanel(signal: PanelSignal) {
    for (const listener of this.#panelListeners) listener(signal);
  }

  /** Start up: load the gateway's lists and open the most recent session. */
  async bootstrap() {
    this.clientId = getClientId();
    await this.initializeFirstSend();
    this.loading = true;
    this.#bootstrapFailed = false;
    this.pageError = '';
    let linkedTarget: PushTarget | undefined;
    let linkedInteraction: PushInteraction | undefined;
    try {
      [this.workspaces, this.sessions, this.models, this.nodes, this.modeCatalog] =
        await Promise.all([
          api.workspaces(),
          api.sessions(),
          api.models(),
          api.nodes(),
          this.#loadModes(),
        ]);
      this.#sessionsVersion++;
      this.activeSessionId = this.sessions[0]?.id;
      // A notification or a shared link names what to open.
      const bootstrapUrl = new URL(location.href);
      linkedTarget = targetFromUrl(bootstrapUrl);
      linkedInteraction = interactionFromUrl(bootstrapUrl);
      if (linkedTarget && 'sessionId' in linkedTarget) {
        const linkedSessionId = linkedTarget.sessionId;
        if (this.sessions.some((session) => session.id === linkedSessionId))
          this.activeSessionId = linkedSessionId;
      } else if (linkedTarget) this.#request(linkedTarget);
      pruneDrafts(this.sessions.map((session) => session.id));
      void this.refreshMemory();
      void this.refreshSchedules();
    } catch (error) {
      if (import.meta.env.DEV) {
        const demo = await import('./mock');
        this.demo = demo;
        this.connection = navigator.onLine ? 'connected' : 'offline';
        this.workspaces = demo.demoWorkspaces;
        this.nodes = demo.demoNodes;
        this.modeCatalog = demo.demoModes;
        this.sessions = demo.demoSessions;
        this.#sessionsVersion++;
        this.models = demo.demoModels;
        this.activeSessionId = demo.demoSnapshot.session.id;
      } else {
        this.#bootstrapFailed = true;
        this.pageError = errorMessage(error, tr('Unable to connect to the gateway.'));
      }
    }
    // A project or workspace page the address names stays in front of the session behind it.
    if (new URL(location.href).searchParams.get('open') === 'pots') this.view = 'pots';
    const page = new URL(location.href).searchParams.get('workspace');
    const pageWorkspace = page ? this.workspaces.find((item) => item.id === page) : undefined;
    if (pageWorkspace) {
      this.setMode(tabOf(pageWorkspace, this.modeCatalog));
      this.workspaceViewId = pageWorkspace.id;
      this.view = 'workspace';
    }
    if (this.activeSessionId) {
      await this.openSession(this.activeSessionId, { show: this.view === 'session' });
      if (
        linkedInteraction &&
        linkedTarget &&
        'sessionId' in linkedTarget &&
        linkedInteraction.sessionId === linkedTarget.sessionId &&
        linkedInteraction.sessionId === this.activeSessionId
      )
        await this.verifyNotificationInteraction(linkedInteraction);
    }
    this.loading = false;
  }

  #nodesRequest = 0;
  /** Refresh the node and workspace lists (they change as devices come and go). */
  async refreshNodes() {
    if (this.demo) return;
    const request = ++this.#nodesRequest;
    try {
      const [online, available, modes] = await Promise.all([
        api.nodes(),
        api.workspaces(),
        this.#loadModes(),
      ]);
      if (request !== this.#nodesRequest) return;
      for (const workspace of this.workspaces) {
        if (!available.some((item) => item.id === workspace.id)) this.hideWorkspace(workspace.id);
      }
      this.nodes = online;
      this.workspaces = available;
      this.modeCatalog = modes;
    } catch {
      /* keep the last lists */
    }
  }

  /** Sessions can appear without this client creating them (a delegated task's session). */
  async refreshSessions() {
    if (this.demo) return;
    const version = this.#sessionsVersion;
    const request = ++this.#sessionsRequest;
    try {
      const sessions = await api.sessions();
      // A selection or local session change means this response may predate a
      // session we already know is valid. It must not remove that session or its draft.
      if (version !== this.#sessionsVersion || request !== this.#sessionsRequest) return;
      this.sessions = sessions;
      if (
        !this.isDraftSession &&
        this.activeSessionId &&
        !this.sessions.some((s) => s.id === this.activeSessionId)
      )
        this.removeSession(this.activeSessionId);
      this.markActiveRead();
    } catch {
      /* keep the last list */
    }
  }

  /** USER proposals waiting for you ("Needs you"). */
  async refreshMemory() {
    if (this.demo) return;
    try {
      const { proposals } = await memoryApi.view();
      this.memoryProposals = proposals.filter((proposal) => proposal.status === 'pending');
      this.memoryPending = this.memoryProposals.length;
    } catch {
      /* keep the last list */
    }
  }

  #sessionsTimer: ReturnType<typeof setTimeout> | undefined;
  /** Runs start and end in bursts: one reload per burst. */
  #sessionsChanged() {
    this.#sessionsTimer ??= setTimeout(() => {
      this.#sessionsTimer = undefined;
      void this.refreshSessions();
    }, 250);
  }

  /** Answer a memory proposal from "Needs you". */
  async decideProposal(proposal: MemoryProposal, approve: boolean) {
    if (this.demo) return;
    try {
      const view = approve
        ? await memoryApi.approve(proposal.id, proposal.target?.revision)
        : await memoryApi.reject(proposal.id);
      this.memoryProposals = view.proposals.filter((item) => item.status === 'pending');
      this.memoryPending = this.memoryProposals.length;
      this.memoryRevision++;
    } catch (error) {
      this.pageError = errorMessage(error, tr('The memory change could not be answered.'));
      void this.refreshMemory();
    }
  }

  /** Allow (run now) or dismiss a missed scheduled run. */
  async decideMissed(scheduleId: string, runId: string, allow: boolean) {
    if (this.demo) return;
    try {
      if (allow) await schedulesApi.run(scheduleId, runId);
      else await schedulesApi.dismiss(scheduleId, runId);
      this.missedRuns = this.missedRuns.filter((item) => item.run.id !== runId);
    } catch (error) {
      this.pageError = errorMessage(
        error,
        allow ? tr('The run could not be started.') : tr('The run could not be dismissed.'),
      );
    }
    this.scheduleRevision++;
    void this.refreshSchedules();
  }

  /** Show what a notification points at. */
  async openTarget(target: PushTarget | undefined) {
    if (!target) return;
    if ('sessionId' in target) {
      // A session a scheduled run just started may be new to this list.
      if (!this.sessions.some((session) => session.id === target.sessionId))
        await this.refreshSessions();
      if (this.sessions.some((session) => session.id === target.sessionId))
        await this.openSession(target.sessionId);
      return;
    }
    this.#request(target);
  }

  /** Open an exact-question notification and check its status against a fresh snapshot. */
  async openNotificationTarget(target: PushTarget | undefined, interaction: unknown) {
    await this.openTarget(target);
    if (
      !interaction ||
      !isPushInteraction(interaction) ||
      !target ||
      !('sessionId' in target) ||
      target.sessionId !== interaction.sessionId
    )
      return;
    await this.verifyNotificationInteraction(interaction);
  }

  /** A clicked notification may outlive its question; never answer on click. */
  async verifyNotificationInteraction(identity: PushInteraction, showPendingNotice = false) {
    const sessionId = identity.sessionId;
    if (this.activeSessionId !== sessionId || this.demo) return;
    try {
      const snapshot = await api.snapshot(sessionId);
      const current = this.sessionState;
      if (this.activeSessionId !== sessionId || current?.session.id !== sessionId) {
        if (this.activeSessionId === sessionId)
          this.interactionNotice = tr(
            'We couldn’t verify whether this request was handled. Check the session before submitting an answer.',
          );
        return;
      }
      const question = snapshot.interactions.find(
        (item) =>
          item.id === identity.interactionId && item.runnerEpoch === identity.interactionEpoch,
      );
      if (question?.status === 'pending') {
        if (showPendingNotice) {
          this.interactionNotice = tr(
            'This request is still waiting. Refresh the session before answering.',
          );
        }
        return;
      }
      this.sessionState = {
        ...current,
        interactions: current.interactions.filter(
          (item) =>
            item.id !== identity.interactionId || item.runnerEpoch !== identity.interactionEpoch,
        ),
      };
      this.interactionNotice = tr('This request has already been handled.');
    } catch {
      this.interactionNotice = tr(
        'We couldn’t verify whether this request was handled. Check the session before submitting an answer.',
      );
    }
  }

  #request(target: Exclude<PushTarget, { sessionId: string }>) {
    // Schedules have their own page; memory still lives in Settings.
    if ('schedules' in target) this.showSchedules(target.scheduleId);
    else if ('calendar' in target)
      this.showCalendar(target.eventId, target.occurrenceStart, target.date, target.startAt);
    else this.requestedTarget = target;
  }

  /** Your schedules, and their missed runs ("Needs you"). */
  async refreshSchedules() {
    if (this.demo) return;
    try {
      const { schedules } = await schedulesApi.list();
      this.schedules = schedules;
      this.scheduleAttention = schedules.reduce((sum, item) => sum + item.attention, 0);
      // Runs waiting for an answer show as their session; missed ones have no session.
      const details = await Promise.all(
        schedules
          .filter((schedule) => schedule.attention > 0)
          .map((schedule) => schedulesApi.get(schedule.id).catch(() => undefined)),
      );
      this.missedRuns = details.flatMap((detail) =>
        detail
          ? detail.runs
              .filter((run) => run.status === 'missed')
              .map((run) => ({ schedule: detail.schedule, run }))
          : [],
      );
    } catch {
      /* keep the last lists */
    }
  }

  /** Start again if the first start could not reach the gateway. Returns whether it did. */
  retryBootstrap(): boolean {
    if (!this.#bootstrapFailed || this.loading) return false;
    void this.bootstrap();
    return true;
  }

  /**
   * Back in the foreground after `hiddenFor` ms: reconnect the event stream at
   * once, renew control, and reload what a suspended page may have missed.
   */
  resume(hiddenFor: number) {
    if (this.retryBootstrap()) return;
    void this.initializeFirstSend().then(() =>
      this.firstDraft?.frozen ? this.checkFirst() : undefined,
    );
    this.#events?.reconnectNow();
    void this.refreshControl();
    void this.refreshNodes();
    void this.refreshSessions();
    void this.refreshMemory();
    void this.refreshSchedules();
    // A short switch away is covered by the stream's cursor replay.
    if (hiddenFor >= RESUME_SNAPSHOT_AFTER) void this.refreshSnapshot();
  }

  /** `show: false` connects the session behind the page on screen (a project page, the schedules). */
  async openSession(
    id: string,
    {
      show = true,
      keepComposer = false,
      skipFirst = false,
    }: { show?: boolean; keepComposer?: boolean; skipFirst?: boolean } = {},
  ) {
    const firstIntent = ++this.#firstOpenIntent;
    if (
      !keepComposer &&
      this.firstDraft &&
      (!(await this.#saveBeforeFirstNavigation()) || firstIntent !== this.#firstOpenIntent)
    )
      return;
    if (!skipFirst && this.firstEnabled && !this.demo) {
      const seq = this.#openSeq,
        scope = this.#firstScope,
        owner = this.firstCapabilities!.ownerUser!;
      let pending = this.firstRecoveries.find(
        (r) => r.operationId === id || r.preparation?.sessionId === id,
      );
      if (!pending) {
        try {
          pending = await this.firstFlow.adopt(
            scope,
            owner,
            await this.firstFlow.transport.find(owner, id),
          );
        } catch (error) {
          if (!(error instanceof ApiError && error.status === 404) && scope === this.#firstScope)
            this.#firstError(error);
        }
      }
      if (
        seq !== this.#openSeq ||
        scope !== this.#firstScope ||
        firstIntent !== this.#firstOpenIntent
      )
        return;
      if (pending && !pending.released && pending.preparation?.state !== 'admitted') {
        await this.resumeFirst(pending);
        return;
      }
    }
    if (id === this.activeSessionId && this.isDraftSession) {
      this.view = 'session';
      return;
    }
    if (!keepComposer) this.discardDraftSession();
    if (show) {
      this.view = 'session';
      // The address names the open session: a reload or a shared link comes back
      // to it, and the service worker skips notifications about what is on screen.
      this.#address(`?session=${encodeURIComponent(id)}`);
    }
    // Back from a page to the session still connected behind it.
    if (id === this.activeSessionId && this.sessionState?.session.id === id && this.#events) {
      this.markActiveRead();
      return;
    }
    this.#sessionsVersion++;
    this.flushDraft();
    const seq = ++this.#openSeq;
    this.activeSessionId = id;
    this.markActiveRead();
    this.#events?.close();
    this.#events = undefined;
    if (!keepComposer) {
      this.sessionState = undefined;
      this.draft = loadDraft(id);
      this.#draftFiles.clear();
      this.uploads.forEach((item) => item.preview && URL.revokeObjectURL(item.preview));
      this.uploads = [];
    }
    this.pageError = '';
    const demo = this.demo;
    this.panel.reset(id, demo?.demoPanelState);
    try {
      const snapshot = demo
        ? {
            ...demo.demoSnapshot,
            session: this.sessions.find((item) => item.id === id) ?? demo.demoSnapshot.session,
          }
        : await api.snapshot(id);
      // Switched to another session while this snapshot was loading.
      if (seq !== this.#openSeq) return;
      this.sessionState = fromSnapshot(snapshot);
      if (this.#historyNeedsRefresh === id) this.#historyNeedsRefresh = undefined;
      this.hiddenMessages = Math.max(0, this.sessionState.messages.length - MESSAGE_PAGE);
      if (!demo) {
        void this.loadModels(id);
        void this.refreshControl();
        let reconnecting = false;
        this.#events = connectEvents({
          sessionId: id,
          cursor: snapshot.cursor,
          onState: (state) => {
            if (seq !== this.#openSeq) return;
            this.connection = state;
            if (state !== 'connected') {
              reconnecting = true;
              return;
            }
            void this.refreshControl();
            // Node changes while disconnected were not pushed.
            if (reconnecting) void this.refreshNodes();
          },
          onDirectory: () => {
            if (seq !== this.#openSeq) return;
            void this.refreshNodes();
            void this.refreshSessions();
          },
          onMemory: () => {
            if (seq !== this.#openSeq) return;
            this.memoryRevision++;
            void this.refreshMemory();
          },
          onSchedules: () => {
            if (seq !== this.#openSeq) return;
            this.scheduleRevision++;
            void this.refreshSchedules();
          },
          onSessions: () => {
            if (seq !== this.#openSeq) return;
            this.#sessionsChanged();
          },
          onEvent: (event) => {
            if (seq === this.#openSeq && event.event.type === 'session_deleted') {
              this.removeSession(id);
              void this.refreshMemory();
              return;
            }
            const current = this.sessionState;
            if (seq !== this.#openSeq || current?.session.id !== id) return;
            this.sessionState = reduceEvent(current, event);
            if (event.checkpointInvalidation)
              this.#emitPanel({ type: 'changed', sections: ['checkpoints'] });
            if (event.event.type === 'panel_changed')
              this.#emitPanel({ type: 'changed', sections: event.event.sections });
            if (event.event.type === 'checkpoints_changed')
              this.#emitPanel({ type: 'changed', sections: ['checkpoints'] });
            if (event.event.type === 'session_renamed') {
              const name = event.event.name;
              this.sessions = this.sessions.map((item) =>
                item.id === id ? { ...item, name } : item,
              );
              this.#sessionsVersion++;
            }
            if (this.sessionState.needsSnapshot) void this.refreshSnapshot();
          },
        });
      }
      await this.scroller?.toLatest(false);
    } catch (error) {
      if (seq === this.#openSeq)
        this.pageError = errorMessage(error, tr('Unable to load this session.'));
    }
  }

  async loadModels(id = this.activeSessionId) {
    try {
      const list = await api.models(this.isDraftSession ? undefined : id);
      if (this.activeSessionId === id) this.models = list;
    } catch {
      /* keep the previous list; the runner may still be starting */
    }
  }

  /** Reload the open session. Bursts coalesce into one request plus one follow-up. */
  async refreshSnapshot() {
    const id = this.activeSessionId;
    if (!id || this.demo || this.isDraftSession) return;
    const seq = this.#openSeq;
    if (this.#snapshotLoading.has(seq)) {
      this.#snapshotAgain.add(seq);
      return;
    }
    this.#snapshotLoading.add(seq);
    const historyRevision = this.#historyRevision;
    try {
      const snapshot = await api.snapshot(id);
      if (
        seq !== this.#openSeq ||
        id !== this.activeSessionId ||
        this.#snapshotAgain.has(seq) ||
        historyRevision !== this.#historyRevision
      )
        return;
      this.sessionState = fromSnapshot(snapshot);
      if (this.#historyNeedsRefresh === id) this.#historyNeedsRefresh = undefined;
      this.hiddenMessages = Math.min(
        this.hiddenMessages,
        Math.max(0, snapshot.messages.length - 1),
      );
      const { id: snapshotSessionId, name } = this.sessionState.session;
      if (this.sessions.some((item) => item.id === snapshotSessionId && item.name !== name)) {
        this.sessions = this.sessions.map((item) =>
          item.id === snapshotSessionId ? { ...item, name } : item,
        );
        this.#sessionsVersion++;
      }
    } catch (error) {
      if (seq === this.#openSeq && !this.#snapshotAgain.has(seq))
        this.pageError = errorMessage(error, tr('Could not refresh the session.'));
    } finally {
      this.#snapshotLoading.delete(seq);
      if (this.#snapshotAgain.delete(seq) && seq === this.#openSeq) void this.refreshSnapshot();
    }
  }

  private removeSession(id: string) {
    const session =
      this.sessions.find((s) => s.id === id) ??
      (this.sessionState?.session.id === id ? this.sessionState.session : undefined);
    this.sessions = this.sessions.filter((s) => s.id !== id);
    this.#sessionsVersion++;
    if (id === this.activeSessionId) {
      ++this.#openSeq;
      this.#events?.close();
      this.#events = undefined;
      this.sessionState = undefined;
      this.activeSessionId = undefined;
      this.#draftPending = undefined;
      clearTimeout(this.#draftTimer);
      this.draft = '';
      this.uploads = [];
      this.panel.reset('');
      if (session) this.showWorkspace(session.workspaceId);
    }
    removeDraft(id);
  }

  async deleteSession(id: string) {
    const first = this.firstRecoveries.find((row) => row.preparation?.sessionId === id);
    if (first) await this.discardFirst(first);
    else if (!this.demo) await api.deleteSession(id);
    this.removeSession(id);
    this.memoryRevision++;
    await this.refreshMemory();
  }

  /**
   * Delete a chat project with its chats (docs/guides/chat-projects.md). The
   * page it was on goes back to the open session, or the one behind it.
   */
  async deleteProject(
    workspaceId: string,
    decisions: ProjectMemoryDecision[],
    proposalDecisions: ProjectProposalDecision[] = [],
  ) {
    if (!this.demo) await projectDeletionApi.delete(workspaceId, decisions, proposalDecisions);
    if (this.draftWorkspaceId === workspaceId) this.discardDraftSession();
    for (const session of this.sessions.filter((item) => item.workspaceId === workspaceId))
      this.removeSession(session.id);
    this.workspaces = this.workspaces.filter((item) => item.id !== workspaceId);
    if (this.workspaceViewId === workspaceId) {
      this.workspaceViewId = undefined;
      this.view = 'session';
      this.#address(
        this.activeSessionId ? `?session=${encodeURIComponent(this.activeSessionId)}` : '?',
      );
    }
    this.memoryRevision++;
    this.scheduleRevision++;
    // Each keeps its last list on failure: the deletion itself is done.
    void Promise.all([this.refreshNodes(), this.refreshMemory(), this.refreshSchedules()]);
  }

  /** Clear local navigation too when another client removes this workspace. */
  private hideWorkspace(workspaceId: string) {
    this.#sessionsVersion++;
    if (this.draftWorkspaceId === workspaceId) this.discardDraftSession();
    for (const session of this.sessions.filter((item) => item.workspaceId === workspaceId))
      this.removeSession(session.id);
    this.workspaces = this.workspaces.filter((item) => item.id !== workspaceId);
    if (this.workspaceViewId === workspaceId) {
      this.workspaceViewId = undefined;
      this.view = 'session';
      this.#address(
        this.activeSessionId ? `?session=${encodeURIComponent(this.activeSessionId)}` : '?',
      );
    }
  }

  /** Unregister without deleting the workspace's files, sessions or memories. */
  async removeWorkspace(workspaceId: string) {
    if (this.demo) return;
    await api.removeWorkspace(workspaceId);
    ++this.#nodesRequest;
    this.hideWorkspace(workspaceId);
    this.scheduleRevision++;
    void Promise.all([this.refreshNodes(), this.refreshSchedules()]);
  }

  /** Rename, pin or settle from the sidebar. Applied at once and rolled back on failure. */
  async updateSession(id: string, input: SessionUpdateInput) {
    const previous = this.sessions.find((item) => item.id === id);
    if (!previous) return;
    const apply = (patch: Partial<SessionSummary>) => {
      this.sessions = this.sessions.map((item) => (item.id === id ? { ...item, ...patch } : item));
      this.#sessionsVersion++;
      const state = this.sessionState;
      if (state?.session.id === id && patch.name !== undefined)
        this.sessionState = { ...state, session: { ...state.session, name: patch.name } };
    };
    apply(input);
    if (this.demo) return;
    try {
      const updated = await api.updateSession(id, input);
      apply({ name: updated.name, pinned: updated.pinned, settled: updated.settled });
      // A settled session's unsent draft is dropped (unless it is open right now).
      if (updated.settled && id !== this.activeSessionId) removeDraft(id);
    } catch (error) {
      apply({ name: previous.name, pinned: previous.pinned, settled: previous.settled });
      this.pageError = errorMessage(error, tr('Could not update the session.'));
    }
  }

  /**
   * localStorage writes are synchronous; persist the draft after typing pauses
   * (and on session switch / page hide via {@link flushDraft}), not per key.
   */
  setDraft(value: string) {
    if (this.firstDraft?.frozen) return;
    this.draft = value;
    if (this.firstDraft) {
      void this.#saveFirstDraft().catch(() => undefined);
      return;
    }
    if (!this.activeSessionId || this.isDraftSession) return;
    this.#draftPending = { sessionId: this.activeSessionId, value };
    clearTimeout(this.#draftTimer);
    // Cleared drafts (sent messages) are removed at once.
    if (!value) this.flushDraft();
    else this.#draftTimer = setTimeout(() => this.flushDraft(), 250);
  }

  flushDraft() {
    if (this.firstDraft && !this.firstDraft.frozen)
      void this.#saveFirstDraft().catch(() => undefined);
    clearTimeout(this.#draftTimer);
    this.#draftTimer = undefined;
    const pending = this.#draftPending;
    this.#draftPending = undefined;
    if (pending) saveDraft(pending.sessionId, pending.value);
  }

  async sendCommand(kind: CommandKind, content = this.draft) {
    if (this.commandBusy) return;
    if (this.firstDraft) {
      if (kind === 'prompt' && !this.firstDraft.frozen && (content.trim() || this.uploads.length)) {
        this.setDraft(content);
        await this.continueFirst();
      }
      return;
    }
    if (this.isDraftSession) {
      if (kind !== 'prompt' || !content.trim()) return;
      this.commandBusy = true;
      try {
        if (!(await this.#persistNewSession())) return;
      } catch (error) {
        this.pageError = errorMessage(
          error,
          tr('Could not start the conversation. Your message is still here.'),
        );
        return;
      } finally {
        this.commandBusy = false;
      }
    }
    const state = this.sessionState;
    const sessionId = this.activeSessionId;
    if (!state || !sessionId || !state.control.generation || this.connection !== 'connected')
      return;
    const expectedBinding = conversationBinding(state.session.binding, state.session.workspaceId);
    this.commandBusy = true;
    this.pageError = '';
    try {
      if (!this.demo) {
        for (const item of this.uploads) {
          const file = this.#draftFiles.get(item.id);
          if (!file) continue;
          const uploaded = await api.upload(sessionId, file);
          if (this.activeSessionId !== sessionId) return;
          this.#draftFiles.delete(item.id);
          this.uploads = this.uploads.map((current) =>
            current.id === item.id ? { ...uploaded, preview: item.preview } : current,
          );
        }
        await api.command(sessionId, {
          commandId: uuid(),
          kind,
          controlGeneration: state.control.generation,
          expectedBinding,
          content: content || undefined,
          modelId: this.selectedModelOption?.id,
          provider: this.selectedModelOption?.provider,
          thinkingLevel: this.thinking,
          attachmentIds: this.uploads.length
            ? this.uploads.filter((item) => !item.uploading).map((item) => item.id)
            : undefined,
        });
      } else if (kind === 'follow_up') {
        this.sessionState = {
          ...state,
          queue: [
            ...state.queue,
            {
              id: uuid(),
              kind,
              index: state.queue.filter((item) => item.kind === kind).length,
              content,
              createdAt: new Date().toISOString(),
            },
          ],
        };
      } else if (kind === 'prompt' || kind === 'steer') {
        this.sessionState = {
          ...state,
          messages: [
            ...state.messages,
            {
              id: uuid(),
              role: 'user',
              content,
              createdAt: new Date().toISOString(),
              attachments: this.uploads,
            },
          ],
        };
      }
      if (kind === 'prompt' || kind === 'steer' || kind === 'follow_up') {
        this.setDraft('');
        this.uploads = [];
        await this.scroller?.toLatest();
      }
    } catch (error) {
      this.pageError = errorMessage(error, tr('The command was not accepted.'));
      // A switched environment: refresh the binding; the draft stays for the user to resend.
      if (isBindingRefusal(error)) void this.refreshSnapshot();
    } finally {
      this.commandBusy = false;
    }
  }

  /** Change only the conversation tree; tool effects in the workspace are not rolled back. */
  async changeBranch(kind: 'edit_message' | 'switch_branch', entryId: string, content?: string) {
    const state = this.sessionState;
    const sessionId = this.activeSessionId;
    if (!this.canChangeBranch || !state?.control.generation || !sessionId) return false;
    const selection = this.#openSeq;
    const message = state.messages.find((item) => item.role === 'user' && item.entryId === entryId);
    const isVariant = state.messages.some((item) =>
      item.branches?.some((branch) => branch.entryId === entryId),
    );
    if (kind === 'edit_message' ? !message || !content?.trim() : !isVariant) return false;
    this.commandBusy = true;
    this.pageError = '';
    try {
      const receipt = await api.command(sessionId, {
        commandId: uuid(),
        kind,
        entryId,
        content,
        controlGeneration: state.control.generation,
        expectedBinding: state.session.binding,
        ...(kind === 'edit_message'
          ? {
              modelId: this.selectedModelOption?.id,
              provider: this.selectedModelOption?.provider,
              thinkingLevel: this.thinking,
            }
          : {}),
      });
      if (receipt.status !== 'accepted')
        throw new Error(receipt.message ?? tr('The branch change was not accepted.'));
      // A coalesced lifecycle refresh may still be reading the old tree. Invalidate
      // it and fetch our own authoritative snapshot before enabling another edit.
      if (this.activeSessionId !== sessionId || selection !== this.#openSeq) return true;
      const revision = ++this.#historyRevision;
      this.#historyNeedsRefresh = sessionId;
      try {
        const snapshot = await api.snapshot(sessionId);
        if (
          this.activeSessionId === sessionId &&
          selection === this.#openSeq &&
          revision === this.#historyRevision
        ) {
          this.sessionState = fromSnapshot(snapshot);
          this.hiddenMessages = Math.max(0, snapshot.messages.length - MESSAGE_PAGE);
          this.#historyNeedsRefresh = undefined;
        }
      } catch (error) {
        if (this.activeSessionId === sessionId)
          this.pageError = errorMessage(
            error,
            tr('Message updated, but refreshing failed. Reload the session before editing again.'),
          );
      }
      // The mutation was accepted even when refreshing failed. Never offer to
      // resubmit an already committed edit; keep history controls gated instead.
      return true;
    } catch (error) {
      if (this.activeSessionId === sessionId)
        this.pageError = errorMessage(error, tr('The branch change was not accepted.'));
      return false;
    } finally {
      this.commandBusy = false;
    }
  }

  /**
   * Goal dock buttons send `/goal pause|resume`. As a steer it works both idle
   * and mid-run, and it does not open a run record the way a prompt does.
   */
  async goalAction(action: 'pause' | 'resume') {
    const state = this.sessionState;
    const sessionId = this.activeSessionId;
    if (
      this.demo ||
      !state ||
      !sessionId ||
      !state.control.generation ||
      this.connection !== 'connected'
    )
      return;
    this.commandBusy = true;
    this.pageError = '';
    try {
      await api.command(sessionId, {
        commandId: uuid(),
        kind: 'steer',
        controlGeneration: state.control.generation,
        expectedBinding: state.session.binding,
        content: `/goal ${action}`,
      });
    } catch (error) {
      this.pageError = errorMessage(error, tr('The command was not accepted.'));
    } finally {
      this.commandBusy = false;
    }
  }

  /** Renew this client's lease, or pick control back up if nobody holds a live one. */
  async refreshControl() {
    const id = this.activeSessionId;
    const state = this.sessionState;
    if (this.demo || this.isDraftSession || !id || !state) return;
    if (this.#controlSyncing?.id === id) return this.#controlSyncing.promise;
    const pending = { id, promise: Promise.resolve() };
    pending.promise = (async () => {
      try {
        const control = await syncControl(api, id, state.control, {
          mayAcquire: document.visibilityState === 'visible',
        });
        const current = this.sessionState;
        if (control && current && this.activeSessionId === id)
          this.sessionState = { ...current, control };
      } finally {
        if (this.#controlSyncing === pending) this.#controlSyncing = undefined;
      }
    })();
    this.#controlSyncing = pending;
    return pending.promise;
  }

  async stopRun() {
    await this.sendCommand('stop', '');
  }

  /** Deliver a queued message immediately, interrupting the current model call or tool. */
  async sendQueuedNow(item: QueueItem) {
    const state = this.sessionState;
    const sessionId = this.activeSessionId;
    if (!state || !sessionId || !state.control.generation || this.connection !== 'connected')
      return;
    if (this.demo) {
      this.sessionState = { ...state, queue: state.queue.filter((queued) => queued !== item) };
      return;
    }
    this.commandBusy = true;
    this.pageError = '';
    try {
      await api.command(sessionId, {
        commandId: uuid(),
        kind: 'send_now',
        controlGeneration: state.control.generation,
        expectedBinding: state.session.binding,
        content: item.content,
        queued: { kind: item.kind, index: item.index },
      });
    } catch (error) {
      const text = errorMessage(error, tr('The message could not be sent now.'));
      // The run delivered or cleared it meanwhile; the next queue update shows that.
      if (!/no longer queued/.test(text)) this.pageError = text;
    } finally {
      this.commandBusy = false;
    }
  }

  async clearQueue() {
    await this.sendCommand('clear_queue', '');
    if (this.demo && this.sessionState) this.sessionState = { ...this.sessionState, queue: [] };
  }

  async takeControl() {
    const state = this.sessionState;
    if (!this.activeSessionId || !state) return;
    try {
      const control = this.demo
        ? {
            heldByCurrentClient: true,
            holderName: tr('This browser'),
            generation: (state.control.generation ?? 0) + 1,
          }
        : await api.takeControl(this.activeSessionId, this.clientId);
      if (this.sessionState) this.sessionState = { ...this.sessionState, control };
    } catch (error) {
      this.pageError = errorMessage(error, tr('Control could not be transferred.'));
    }
  }

  async answerInteraction(
    interactionId: string,
    answer: InteractionAnswer,
    expectedRunnerEpoch?: string,
  ) {
    const state = this.sessionState;
    const sessionId = this.activeSessionId;
    if (!sessionId) return;
    if (this.answeringInteractionIds.includes(interactionId)) {
      this.interactionNotice = tr('This request is already being processed.');
      return;
    }
    const interaction = state?.interactions.find(
      (item) =>
        item.id === interactionId &&
        (expectedRunnerEpoch === undefined || item.runnerEpoch === expectedRunnerEpoch),
    );
    if (!interaction) {
      if (expectedRunnerEpoch !== undefined && !this.demo)
        await this.verifyNotificationInteraction(
          {
            sessionId,
            interactionId,
            interactionEpoch: expectedRunnerEpoch,
          },
          true,
        );
      return;
    }
    // A delegated session's relayed confirm needs no control lease: answer it
    // from any device that sees the chat.
    const relayed = isRelayed(interactionId);
    if (!relayed && !state?.control.generation) return;
    const runnerEpoch = interaction.runnerEpoch;
    this.answeringInteractionIds = [...this.answeringInteractionIds, interactionId];
    this.interactionNotice = '';
    try {
      if (!this.demo)
        await api.answerInteraction(
          sessionId,
          interactionId,
          answer,
          relayed ? undefined : state?.control.generation,
        );
      const current = this.sessionState;
      if (current?.session.id === sessionId)
        this.sessionState = {
          ...current,
          interactions: current.interactions.filter(
            (item) => item.id !== interactionId || item.runnerEpoch !== runnerEpoch,
          ),
        };
    } catch (error) {
      if (
        !this.demo &&
        error instanceof ApiError &&
        error.status === 409 &&
        (error.code === 'stale_interaction' || error.code === 'lost_control')
      ) {
        try {
          const snapshot = await api.snapshot(sessionId);
          if (this.activeSessionId !== sessionId || this.sessionState?.session.id !== sessionId)
            return;
          const snapshotQuestion = snapshot.interactions.find(
            (item) => item.id === interactionId && item.runnerEpoch === runnerEpoch,
          );
          const resolved = !snapshotQuestion || snapshotQuestion.status !== 'pending';
          if (resolved) {
            const current = this.sessionState;
            if (current?.session.id === sessionId)
              this.sessionState = {
                ...current,
                interactions: current.interactions.filter(
                  (item) => item.id !== interactionId || item.runnerEpoch !== runnerEpoch,
                ),
              };
            this.interactionNotice = tr('This request has already been handled.');
          } else {
            this.interactionNotice =
              error.code === 'lost_control'
                ? tr('This request is still waiting. Take control to answer it.')
                : tr('This request is still waiting. Your answer was not accepted.');
          }
          if (error.code === 'lost_control') void this.refreshControl();
        } catch {
          this.interactionNotice = tr(
            'We couldn’t verify whether this request was handled. Check the session before submitting another answer.',
          );
        }
        return;
      }
      this.pageError = errorMessage(error, tr('Your answer was not accepted.'));
    } finally {
      this.answeringInteractionIds = this.answeringInteractionIds.filter(
        (id) => id !== interactionId,
      );
    }
  }

  /**
   * Allow or deny a delegated session's confirm from "Needs you": it is
   * relayed to the chat that started the delegation, so it is answered
   * there, without that chat's control lease.
   */
  async answerApproval(approval: RelayedApproval, confirmed: boolean) {
    if (this.demo || this.answeringInteractionIds.includes(approval.interactionId)) return;
    this.answeringInteractionIds = [...this.answeringInteractionIds, approval.interactionId];
    try {
      await api.answerRelayed(approval.sessionId, approval.interactionId, confirmed);
      const current = this.sessionState;
      if (current?.session.id === approval.sessionId)
        this.sessionState = {
          ...current,
          interactions: current.interactions.filter((item) => item.id !== approval.interactionId),
        };
    } catch (error) {
      this.pageError = errorMessage(
        error,
        confirmed
          ? tr('The request could not be allowed.')
          : tr('The request could not be denied.'),
      );
    } finally {
      this.answeringInteractionIds = this.answeringInteractionIds.filter(
        (id) => id !== approval.interactionId,
      );
    }
    void this.refreshSessions();
  }

  /** Stop a delegation the open chat started; resolves to the error to show, if any. */
  async stopDelegation(delegationId: string): Promise<string | undefined> {
    if (this.demo) return undefined;
    try {
      await api.stopDelegation(delegationId);
      return undefined;
    } catch (error) {
      return errorMessage(error, tr('The delegation could not be stopped.'));
    }
  }

  async uploadFiles(files: ArrayLike<File>) {
    // Stored on the node that runs the session's agent: images ride in the
    // model's context, other files are copied into the workspace for tools.
    const sessionId = this.activeSessionId;
    if (!sessionId || this.firstDraft?.frozen) return;
    for (const file of Array.from(files)) {
      const isImage = file.type.startsWith('image/');
      const localId = `local-${uuid()}`;
      const preview = isImage ? URL.createObjectURL(file) : undefined;
      this.uploads = [
        ...this.uploads,
        {
          id: localId,
          name: file.name,
          mimeType: file.type,
          size: file.size,
          preview,
          uploading: true,
        },
      ];
      if (this.firstDraft) {
        this.#draftFiles.set(localId, file);
        try {
          await this.#saveFirstDraft();
        } catch {
          return;
        }
      }
      try {
        const attachment = this.demo
          ? {
              id: localId,
              name: file.name,
              mimeType: file.type,
              size: file.size,
              kind: (isImage ? 'image' : 'file') as 'image' | 'file',
            }
          : this.isDraftSession
            ? (this.#draftFiles.set(localId, file),
              {
                id: localId,
                name: file.name,
                mimeType: file.type,
                size: file.size,
                kind: (isImage ? 'image' : 'file') as 'image' | 'file',
              })
            : await api.upload(sessionId, file);
        if (this.activeSessionId !== sessionId) {
          if (preview) URL.revokeObjectURL(preview);
          this.#draftFiles.delete(localId);
          return;
        }
        this.uploads = this.uploads.map((item) =>
          item.id === localId ? { ...attachment, preview } : item,
        );
        if (this.firstDraft) await this.#saveFirstDraft();
      } catch (error) {
        this.uploads = this.uploads.filter((item) => item.id !== localId);
        if (preview) URL.revokeObjectURL(preview);
        this.pageError = errorMessage(error, tr('Could not upload {0}.', [file.name]));
      }
    }
  }
  /** @deprecated use {@link uploadFiles}; kept as an alias for callers that only ever sent images. */
  uploadImages(files: ArrayLike<File>) {
    return this.uploadFiles(files);
  }

  removeUpload(id: string) {
    if (this.firstDraft?.frozen) return;
    this.#draftFiles.delete(id);
    const upload = this.uploads.find((item) => item.id === id);
    if (upload?.preview) URL.revokeObjectURL(upload.preview);
    this.uploads = this.uploads.filter((item) => item.id !== id);
    if (this.firstDraft) void this.#saveFirstDraft().catch(() => undefined);
  }

  async changeModel(key: string) {
    if (this.firstDraft?.frozen) return;
    const model = this.models.find((item) => modelKey(item) === key);
    const state = this.sessionState;
    if (!state || !model) return;
    this.sessionState = {
      ...state,
      selectedModelId: model.id,
      selectedModelProvider: model.provider,
    };
    if (this.firstDraft) void this.#saveFirstDraft().catch(() => undefined);
    // Without the lease the command would be refused; the choice rides with the next prompt.
    if (
      !this.demo &&
      !this.isDraftSession &&
      this.activeSessionId &&
      this.hasControl &&
      state.control.generation
    ) {
      try {
        await api.command(this.activeSessionId, {
          commandId: uuid(),
          kind: 'set_model',
          controlGeneration: state.control.generation,
          expectedBinding: state.session.binding,
          provider: model.provider,
          modelId: model.id,
        });
      } catch (error) {
        this.pageError = errorMessage(error, tr('Model could not be changed.'));
      }
    }
  }

  async changeThinking(level: ThinkingLevel) {
    if (this.firstDraft?.frozen) return;
    const state = this.sessionState;
    if (!state) return;
    this.sessionState = { ...state, thinkingLevel: level };
    if (this.firstDraft) void this.#saveFirstDraft().catch(() => undefined);
    // Without the lease the command would be refused; the choice rides with the next prompt.
    if (
      !this.demo &&
      !this.isDraftSession &&
      this.activeSessionId &&
      this.hasControl &&
      state.control.generation
    ) {
      try {
        await api.command(this.activeSessionId, {
          commandId: uuid(),
          kind: 'set_thinking',
          controlGeneration: state.control.generation,
          expectedBinding: state.session.binding,
          thinkingLevel: level,
        });
      } catch (error) {
        this.pageError = errorMessage(error, tr('Thinking level could not be changed.'));
      }
    }
  }

  /**
   * Switch this session's approval mode. Unlike the model it is not kept for
   * the next prompt: the mode shown is always the one in effect, so it needs
   * this browser's control. The caller confirms `full-access` first.
   */
  async changeApprovalMode(mode: ApprovalMode) {
    const state = this.sessionState;
    if (!state || state.approvalMode === mode) return;
    if (this.demo || this.isDraftSession) {
      this.sessionState = { ...state, approvalMode: mode };
      return;
    }
    if (!this.activeSessionId || !this.hasControl || !state.control.generation) {
      this.pageError = tr('Take control of this session to change its approval mode.');
      return;
    }
    const sessionId = this.activeSessionId;
    try {
      const receipt = await api.command(sessionId, {
        commandId: uuid(),
        kind: 'set_approval_mode',
        controlGeneration: state.control.generation,
        expectedBinding: state.session.binding,
        approvalMode: mode,
      });
      if (receipt.status !== 'accepted')
        throw new Error(receipt.message ?? tr('The agent did not accept the approval mode.'));
      const current = this.sessionState;
      if (current && this.activeSessionId === sessionId)
        this.sessionState = { ...current, approvalMode: mode };
    } catch (error) {
      this.pageError = errorMessage(error, tr('Approval mode could not be changed.'));
    }
  }

  /** The catalog without a failed refresh's gap: an error keeps the last one. */
  #loadModes() {
    return api.modes().catch(() => this.modeCatalog);
  }

  /** What a workspace can do: its mode's capabilities (or its legacy kind's). */
  modeOf(workspace: Workspace): ModeInfo;
  modeOf(workspace: Workspace | undefined): ModeInfo | undefined;
  modeOf(workspace: Workspace | undefined) {
    return modeOf(workspace, this.modeCatalog);
  }

  /** Whether a workspace's device is reachable (local workspaces always are). */
  workspaceOnline(workspace: Workspace | undefined) {
    return (
      !!workspace &&
      (!workspace.id.includes(':') || this.nodes.some((node) => node.id === workspace.hostId))
    );
  }

  /** Whether a new session can start there: online, and its mode still in the catalog. */
  acceptsSessions(workspace: Workspace | undefined) {
    return this.workspaceOnline(workspace) && !isReadOnly(workspace);
  }

  /** Add a workspace on a device. Throws with a displayable message on failure. */
  async createWorkspace(input: NewWorkspace) {
    const workspace = await api.createWorkspace(input);
    ++this.#nodesRequest;
    this.workspaces = [...this.workspaces.filter((item) => item.id !== workspace.id), workspace];
    this.nodes = await api.nodes();
    // Adding the same directory may restore a removed workspace and its sessions.
    await this.refreshSessions();
    return workspace;
  }

  /** Open immediately; negotiated durable drafts are local until first Send is accepted. */
  async createSession(workspaceId: string, recovered?: FirstDraft): Promise<boolean> {
    if (
      !recovered &&
      !this.demo &&
      (!this.firstCapabilities || firstContractBlocked(this.firstCapabilities))
    ) {
      this.pageError = tr(
        'Connect to the Gateway to confirm first-send support before creating a conversation.',
      );
      return false;
    }
    const workspace = this.workspaces.find((item) => item.id === workspaceId);
    if (
      !recovered &&
      (!workspace ||
        isReadOnly(workspace) ||
        (!this.firstEnabled && !this.workspaceOnline(workspace)))
    ) {
      this.pageError = tr('This workspace is unavailable.');
      return false;
    }
    const intent = ++this.#firstOpenIntent,
      previousSelection = this.#openSeq;
    if (this.firstDraft && !(await this.#saveBeforeFirstNavigation())) return false;
    if (intent !== this.#firstOpenIntent || previousSelection !== this.#openSeq) return false;
    this.flushDraft();
    this.discardDraftSession();
    const selection = ++this.#openSeq;
    this.#firstEditor = { conflicted: false, serial: 0, committed: 0 };
    this.#events?.close();
    this.#events = undefined;
    this.draftWorkspaceId = workspaceId;
    this.view = 'session';
    if (workspace) this.setMode(tabOf(workspace, this.modeCatalog));
    this.activeSessionId =
      recovered?.preparation?.sessionId ?? recovered?.operationId ?? `draft-${uuid()}`;
    this.#address(`?new=${encodeURIComponent(workspaceId)}`);
    this.draft = '';
    this.uploads = [];
    this.pageError = '';
    this.connection = navigator.onLine ? 'connected' : 'offline';
    this.hiddenMessages = 0;
    this.panel.reset('');
    this.sessionState = fromSnapshot({
      session: {
        id: this.activeSessionId,
        workspaceId,
        name: 'New session',
        lastActivityAt: new Date().toISOString(),
        runnerStatus: 'stopped',
      },
      runnerStatus: 'stopped',
      run: null,
      messages: [],
      interactions: [],
      queue: [],
      control: { heldByCurrentClient: true },
      cursor: '',
      runnerEpoch: '',
      thinkingLevel: recovered?.thinking ?? workspace?.defaults?.thinkingLevel ?? 'medium',
      selectedModelId: recovered?.model?.id ?? workspace?.defaults?.modelId,
      selectedModelProvider: recovered?.model?.provider,
    });
    if (recovered) {
      this.firstDraft = recovered;
      this.draft = recovered.message;
      this.uploads = recovered.files.map((file) => {
        if (file.blob)
          this.#draftFiles.set(file.id, new File([file.blob], file.name, { type: file.mimeType }));
        return {
          id: file.id,
          name: file.name,
          mimeType: file.mimeType,
          size: file.byteSize,
          kind: file.mimeType.startsWith('image/') ? ('image' as const) : ('file' as const),
        };
      });
    } else if (this.firstEnabled) {
      // Reserve the client route before awaiting storage. A failed or slow
      // first write must never expose the legacy create-and-send path.
      this.firstDraft = {
        ...this.#firstValue(),
        scope: this.#firstScope,
        ownerUser: this.firstCapabilities!.ownerUser!,
        operationId: this.activeSessionId!,
        frozen: false,
        prepareAttempted: false,
        revision: 0,
        updatedAt: Date.now(),
      };
      try {
        await this.#saveFirstDraft();
      } catch (error) {
        if (selection === this.#openSeq)
          this.pageError = errorMessage(
            error,
            tr('Local draft storage is unavailable. Your message has not been sent.'),
          );
        return false;
      }
      if (selection !== this.#openSeq || intent !== this.#firstOpenIntent) return false;
    }
    if (!this.demo) void this.loadModels();
    return true;
  }

  async #persistNewSession(): Promise<boolean> {
    const workspaceId = this.draftWorkspaceId;
    const before = this.sessionState;
    if (!workspaceId || !before) return false;
    const seq = this.#openSeq,
      content = this.draft;
    const model = this.selectedModelOption,
      thinking = this.thinking;
    const created = this.demo
      ? { ...before.session, id: uuid() }
      : await api.createSession({ workspaceId });
    if (!this.workspaces.some((workspace) => workspace.id === workspaceId)) return false;
    this.sessions = [created, ...this.sessions];
    ++this.#sessionsVersion;
    if (seq !== this.#openSeq) {
      saveDraft(created.id, content);
      return false;
    }
    this.draftWorkspaceId = undefined;
    if (this.demo) {
      this.activeSessionId = created.id;
      this.sessionState = {
        ...before,
        session: created,
        control: { heldByCurrentClient: true, generation: 1 },
      };
    } else {
      await this.openSession(created.id, { keepComposer: true });
      if (this.activeSessionId !== created.id) return false;
      await this.refreshControl();
      if (this.activeSessionId !== created.id) return false;
      if (!this.hasControl || !this.sessionState)
        throw new Error(tr('Could not obtain control. Please retry sending.'));
      this.sessionState = {
        ...this.sessionState,
        selectedModelId: model?.id,
        selectedModelProvider: model?.provider,
        thinkingLevel: thinking,
      };
    }
    this.setDraft(content);
    return true;
  }

  /** Release resources held for the page (event socket, upload previews). */
  dispose() {
    this.flushDraft();
    this.#events?.close();
    this.uploads.forEach((upload) => upload.preview && URL.revokeObjectURL(upload.preview));
  }
}

export const app = new AppState();
