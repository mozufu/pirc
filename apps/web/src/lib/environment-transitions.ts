/**
 * Client side of conversation environment switching (plans/transition-installation.md,
 * slices T3a/T3b): preview → confirm → advance (drain, revocation review,
 * install) with an explicit acknowledgement of unproven revocation, explicit
 * cancel until installation, and recovery through `activeTransition`.
 *
 * - Every user action that starts a review gets a fresh `operationId`; a lost
 *   reply is resolved by GET, and only an absent record allows re-sending the
 *   **same** identity and input. Nothing is acknowledged, cancelled or resent
 *   automatically.
 * - `advance` only continues steps the user already authorized (the confirmed
 *   switch); it is the polling read while the Node drains.
 * - No local persistence: after a reload the operation is rediscovered through
 *   `GET /api/sessions/{id}/environment`, so IndexedDB stays at format 3.
 */
import { conversationEnvironment, type ConversationEnvironment } from './conversation-environment';
import { ApiError, isAbort, requestWithStatus } from './http';
import { uuid } from './id';
import type { ConversationBinding } from './types';

// ---- wire shapes ----------------------------------------------------------------

/** `activeTransition` from the environment read; `fenced` is a fence with no acceptance. */
export interface ActiveTransition {
  operationId: string;
  state: string;
}
export interface PreviewView {
  operationId: string;
  targetWorkspaceId: string;
  planHash: string;
  /** `preview`, or `stale` once the reviewed plan no longer matches. */
  state: string;
  canConfirm: boolean;
  blockedBy: string[];
  resourcePreflightStatus: string;
  /** Present only for an observed resource preflight. */
  observationHash?: string;
  nodeObservations: Array<Record<string, unknown>>;
}
export interface RevocationItem {
  kind: string;
  reason: string;
  acknowledgeable: boolean;
}
export interface Revocation {
  /** `pending`, `blocked`, `unproven` or `confirmed`. */
  status: string;
  /** Kept internally; an acknowledgement binds to exactly this value. */
  digest: string | null;
  itemsTotal: number;
  confirmsContainment: boolean;
  items: RevocationItem[];
}
export interface Progress {
  state: string | null;
  errorCode: string | null;
  revocationConfirmed: boolean;
  targetInstalled: boolean;
  revocation: Revocation | null;
  installation: { revocation: unknown; environmentEvent: unknown } | null;
}
export interface TransitionStatus {
  transition: {
    operationId: string;
    sessionId: string;
    /** `accepted`, `outcome_unknown`, `node_fenced`, `installed`, `released`, `deleted`. */
    state: string;
    revocationConfirmed: boolean;
    targetInstalled: boolean;
  };
  /** `undefined` when the read carries no progress (the receipt GET); `null` when none yet. */
  progress: Progress | null | undefined;
  /** e.g. `node_unavailable` when the Node could not be reached. */
  reconciliationState?: string;
}

const text = (v: unknown): v is string => typeof v === 'string' && v.length > 0;
const strings = (v: unknown) => (Array.isArray(v) ? v.filter(text) : []);

export function parseActiveTransition(raw: unknown): ActiveTransition | null {
  const value = raw as Record<string, unknown> | null | undefined;
  if (!value || typeof value !== 'object' || !text(value.operationId) || !text(value.state))
    return null;
  return { operationId: value.operationId, state: value.state };
}

export function parsePreview(raw: any): PreviewView {
  const preview = raw?.preview;
  if (!text(preview?.operationId) || !text(preview?.planHash) || !text(raw?.state))
    throw new Error('Unsupported environment transition preview');
  const preflight = raw.resourcePreflight ?? {};
  return {
    operationId: preview.operationId,
    targetWorkspaceId: String(preview.targetWorkspaceId ?? ''),
    planHash: preview.planHash,
    state: raw.state,
    canConfirm: raw.canConfirm === true,
    blockedBy: strings(raw.blockedBy),
    resourcePreflightStatus: text(preflight.status) ? preflight.status : 'unavailable',
    ...(preflight.status === 'observed' && text(preflight.observationHash)
      ? { observationHash: preflight.observationHash }
      : {}),
    nodeObservations: Array.isArray(raw.nodeObservations) ? raw.nodeObservations : [],
  };
}

function parseRevocation(raw: any): Revocation | null {
  if (!raw || typeof raw !== 'object' || !text(raw.status)) return null;
  const items: RevocationItem[] = Array.isArray(raw.items)
    ? raw.items.map((item: any) => ({
        kind: String(item?.kind ?? 'unknown'),
        reason: String(item?.reason ?? 'unknown'),
        acknowledgeable: item?.acknowledgeable === true,
      }))
    : [];
  return {
    status: raw.status,
    digest: text(raw.digest) ? raw.digest : null,
    itemsTotal:
      typeof raw.itemsTotal === 'number' && Number.isSafeInteger(raw.itemsTotal)
        ? raw.itemsTotal
        : items.length,
    confirmsContainment: raw.confirmsContainment === true,
    items,
  };
}

export function parseStatus(raw: any): TransitionStatus {
  const t = raw?.transition;
  if (!text(t?.operationId) || !text(t?.state))
    throw new Error('Unsupported environment transition status');
  const p = raw.progress;
  const progress: Progress | null | undefined =
    !('progress' in raw) || p === undefined
      ? undefined
      : p && typeof p === 'object'
        ? {
            state: text(p.state) ? p.state : null,
            errorCode: text(p.errorCode) ? p.errorCode : null,
            revocationConfirmed: p.revocationConfirmed === true,
            targetInstalled: p.targetInstalled === true,
            revocation: parseRevocation(p.revocation),
            installation:
              p.installation && typeof p.installation === 'object'
                ? {
                    revocation: p.installation.revocation,
                    environmentEvent: p.installation.environmentEvent,
                  }
                : null,
          }
        : null;
  return {
    transition: {
      operationId: t.operationId,
      sessionId: String(t.sessionId ?? ''),
      state: t.state,
      // Only an installed transition can report confirmed revocation.
      revocationConfirmed: t.state === 'installed' && t.revocationConfirmed === true,
      targetInstalled: t.state === 'installed' && t.targetInstalled === true,
    },
    progress,
    ...(text(raw.reconciliationState) ? { reconciliationState: raw.reconciliationState } : {}),
  };
}

// ---- API --------------------------------------------------------------------------

export interface TransitionLease {
  sessionId: string;
  clientId: string;
  generation: number;
}
export interface PreviewInput {
  operationId: string;
  targetWorkspaceId: string;
  expectedBinding: ConversationBinding;
}
export interface ConfirmInput {
  planHash: string;
  observationHash: string;
  clientId: string;
  generation: number;
}

const session = (id: string) => `/api/sessions/${encodeURIComponent(id)}`;
const transitions = (id: string) => `${session(id)}/environment-transitions`;
const op = (value: string) => encodeURIComponent(value);
const post = async (path: string, body: unknown) =>
  (await requestWithStatus<unknown>(path, { method: 'POST', body: JSON.stringify(body) })).body;
const get = async (path: string, signal?: AbortSignal) =>
  (await requestWithStatus<unknown>(path, { signal })).body;
const lease = (l: TransitionLease) => ({ clientId: l.clientId, generation: l.generation });

export const environmentTransitionApi = {
  /** The current binding and any in-progress transition (another device may own it). */
  environment: async (sessionId: string, signal?: AbortSignal) => {
    const raw = (await get(`${session(sessionId)}/environment`, signal)) as any;
    return {
      environment: conversationEnvironment(raw, sessionId) as ConversationEnvironment,
      activeTransition: parseActiveTransition(raw?.activeTransition),
    };
  },
  preview: async (sessionId: string, input: PreviewInput) =>
    parsePreview(await post(`${transitions(sessionId)}/previews`, input)),
  previewStatus: async (sessionId: string, operationId: string, signal?: AbortSignal) =>
    parsePreview(await get(`${transitions(sessionId)}/previews/${op(operationId)}`, signal)),
  confirm: async (sessionId: string, operationId: string, input: ConfirmInput) =>
    parseStatus(await post(`${transitions(sessionId)}/previews/${op(operationId)}/confirm`, input)),
  /** Read-only state of an accepted transition (no `progress`, no lease needed). */
  status: async (sessionId: string, operationId: string, signal?: AbortSignal) =>
    parseStatus(await get(`${transitions(sessionId)}/receipts/${op(operationId)}`, signal)),
  /** Continues already-authorized steps and returns the status with `progress`. */
  advance: async (l: TransitionLease, operationId: string) =>
    parseStatus(await post(`${transitions(l.sessionId)}/${op(operationId)}/advance`, lease(l))),
  acknowledge: async (l: TransitionLease, operationId: string, digest: string) =>
    parseStatus(
      await post(`${transitions(l.sessionId)}/${op(operationId)}/acknowledge`, {
        digest,
        ...lease(l),
      }),
    ),
  cancel: async (l: TransitionLease, operationId: string) =>
    parseStatus(await post(`${transitions(l.sessionId)}/${op(operationId)}/cancel`, lease(l))),
};

// ---- failures ---------------------------------------------------------------------

/** Error codes the Gateway passes through from Node steps, plus its own. */
export const PASSED_THROUGH = [
  'revocation_unconfirmed',
  'revocation_digest_changed',
  'transition_not_unproven',
  'transition_not_drained',
  'transition_draining',
  'transition_installed',
  'transition_released',
  'transition_target_unreviewed',
  'stale_transition_target',
  'lost_control',
  'transition_outcome_unknown',
  'transition_step_failed',
  'invalid_transition_receipt',
] as const;

/**
 * `ambiguous`: network loss or any 5xx (including `transition_step_failed` and
 * `invalid_transition_receipt`); resolved by GET or `advance`, never by a
 * mutation with a new identity. `not_found`: the record does not exist (the
 * Gateway's 404s are generic). `disabled`: switching is off on this Gateway.
 * `stale`: review again. Every other code is a definite refusal.
 */
export type SwitchFailure =
  | 'ambiguous'
  | 'not_found'
  | 'disabled'
  | 'stale'
  | 'digest_changed'
  | 'installed'
  | 'released'
  | 'lost_control'
  | 'rejected';
export function classifySwitchFailure(error: unknown): SwitchFailure {
  if (!(error instanceof ApiError)) return 'ambiguous';
  if (error.status >= 500) return 'ambiguous';
  if (error.status === 404) return 'not_found';
  switch (error.code) {
    case 'transition_coordinator_unavailable':
      return 'disabled';
    case 'transition_review_changed':
    case 'stale_environment':
      return 'stale';
    case 'revocation_digest_changed':
      return 'digest_changed';
    case 'transition_installed':
      return 'installed';
    case 'transition_released':
      return 'released';
    case 'lost_control':
      return 'lost_control';
    default:
      return 'rejected';
  }
}

/** A command refused because the binding it carried is no longer current. */
export const isBindingRefusal = (error: unknown) =>
  error instanceof ApiError &&
  error.status === 409 &&
  (error.code === 'stale_environment' || error.code === 'environment_required');

// ---- phases -----------------------------------------------------------------------

export type SwitchPhase =
  | 'idle'
  | 'previewing' // preview POST in flight
  | 'preview_unknown' // ambiguous preview POST; GET did not answer
  | 'preview_missing' // GET 404: not stored; the same identity may be re-sent
  | 'review' // canConfirm
  | 'review_blocked' // blockedBy reasons
  | 'review_stale' // stale preview, changed observation or binding: review again
  | 'switching_disabled' // coordinator_not_available / transition_coordinator_unavailable
  | 'confirming'
  | 'confirm_unknown' // ambiguous confirm; status did not answer
  | 'confirm_missing' // status 404: not accepted; the same input may be re-sent
  | 'awaiting_dispatch' // `accepted`
  | 'outcome_unknown' // `outcome_unknown`: the Node fence is being reconciled
  | 'draining' // `node_fenced` without progress, or revocation `pending`
  | 'blocked' // revocation `blocked`: shown, never acknowledgeable
  | 'needs_acknowledgement' // revocation `unproven`
  | 'installing' // revocation `confirmed`, not installed yet
  | 'switched' // `installed`
  | 'cancelled' // `released`
  | 'deleted' // `deleted`
  | 'legacy_fence' // an active Node fence without an acceptance
  | 'unknown_state'
  | 'rejected'; // definite refusal of a preview or confirm

export type SwitchAction =
  | 'preview'
  | 'confirm'
  | 'refresh'
  | 'resend'
  | 'review_again'
  | 'acknowledge'
  | 'cancel'
  | 'discard';

export type SwitchResult =
  | 'revocation_confirmed' // "switched; revocation confirmed"
  | 'revocation_not_fully_confirmed' // "switched; revocation not fully confirmed"
  | 'original_kept'; // "cancelled; original workspace kept"

/** Maps an accepted transition's state and progress to a client phase. */
export function transitionPhase(status: TransitionStatus): SwitchPhase {
  switch (status.transition.state) {
    case 'accepted':
      return 'awaiting_dispatch';
    case 'outcome_unknown':
      return 'outcome_unknown';
    case 'node_fenced':
      switch (status.progress?.revocation?.status) {
        case undefined:
        case 'pending':
          return 'draining';
        case 'blocked':
          return 'blocked';
        case 'unproven':
          return 'needs_acknowledgement';
        case 'confirmed':
          return 'installing';
        default:
          return 'unknown_state';
      }
    case 'installed':
      return 'switched';
    case 'released':
      return 'cancelled';
    case 'deleted':
      return 'deleted';
    case 'fenced':
      return 'legacy_fence';
    default:
      return 'unknown_state';
  }
}

export function resultOf(status: TransitionStatus | undefined): SwitchResult | undefined {
  if (status?.transition.state === 'installed')
    return status.transition.revocationConfirmed
      ? 'revocation_confirmed'
      : 'revocation_not_fully_confirmed';
  if (status?.transition.state === 'released') return 'original_kept';
  return undefined;
}

/** Phases read again automatically (with backoff) while the Node works. */
export const pollable = (phase: SwitchPhase) =>
  phase === 'draining' || phase === 'outcome_unknown' || phase === 'installing';

const PREVIEW_PHASES: SwitchPhase[] = [
  'previewing',
  'preview_unknown',
  'preview_missing',
  'review',
  'review_blocked',
  'review_stale',
  'switching_disabled',
  'confirming',
  'confirm_unknown',
  'confirm_missing',
  'rejected',
];

export interface SwitchState {
  phase: SwitchPhase;
  operationId?: string;
  targetWorkspaceId?: string;
  /** The binding the preview was made against. */
  expectedBinding?: ConversationBinding;
  preview?: PreviewView;
  /** Kept to re-send the same confirmation after an absent record. */
  confirmation?: ConfirmInput;
  status?: TransitionStatus;
  result?: SwitchResult;
  /** The binding read after installation, for later commands' `expectedBinding`. */
  binding?: ConversationBinding;
  error?: { status?: number; code?: string; message: string; reason: SwitchFailure };
  /** The Node could not be reached on the last read. */
  nodeUnavailable?: boolean;
  /** The shown items changed under an acknowledgement; review them again. */
  digestChanged?: boolean;
  /** A cancel was asked; reads stay read-only so nothing advances past it. */
  cancelRequested?: boolean;
  /** Automatic reads stopped after a definite failure; `refresh` resumes. */
  stalled?: boolean;
}

/** What the user may do now. No automatic acknowledgement, cancel or resend. */
export function allowedSwitchActions(
  state: SwitchState,
  current: TransitionLease | undefined,
): SwitchAction[] {
  const control = !!current;
  switch (state.phase) {
    case 'idle':
      return ['preview'];
    case 'previewing':
    case 'confirming':
      return [];
    case 'preview_unknown':
    case 'confirm_unknown':
      return ['refresh'];
    case 'preview_missing':
      return ['resend', 'discard'];
    case 'confirm_missing':
      return state.confirmation &&
        current &&
        current.clientId === state.confirmation.clientId &&
        current.generation === state.confirmation.generation
        ? ['resend', 'discard']
        : ['discard'];
    case 'review':
      return state.preview?.canConfirm && state.preview.observationHash && control
        ? ['confirm', 'refresh', 'discard']
        : ['refresh', 'discard'];
    case 'review_blocked':
      return ['refresh', 'discard'];
    case 'review_stale':
      return ['review_again', 'discard'];
    case 'switching_disabled':
    case 'rejected':
      return ['discard'];
    case 'awaiting_dispatch':
    case 'outcome_unknown':
    case 'draining':
    case 'blocked':
    case 'installing':
      return control ? ['refresh', 'cancel'] : ['refresh'];
    case 'needs_acknowledgement':
      return control && state.status?.progress?.revocation?.digest
        ? ['acknowledge', 'refresh', 'cancel']
        : ['refresh'];
    case 'switched':
    case 'cancelled':
    case 'deleted':
      return ['discard'];
    case 'legacy_fence':
    case 'unknown_state':
      return ['refresh'];
  }
}

// ---- revocation items in plain language -------------------------------------------

/** English source strings (translated by the UI) for item kinds. */
export const ITEM_KIND_LABELS: Record<string, string> = {
  sandbox_launch: 'Agent or sandbox run',
  host_command: 'Host-management command',
  terminal: 'Terminal',
  host_terminal: 'Host-management terminal',
  browser: 'Browser',
  native_proxy: 'Network proxy',
  legacy_history: 'Earlier history',
  unattributed: 'Unattributed record',
  platform_containment: 'Agent processes',
};
/** English source strings for item reasons. */
export const ITEM_REASON_LABELS: Record<string, string> = {
  unresolved: 'still running or not yet confirmed stopped',
  uncontained_launch: 'this host cannot prove its processes stopped',
  untracked_launch: 'started before launches were tracked',
  launches_before_journals: 'may include runs from before tracking existed',
  host_effects_may_survive: 'detached host work may survive',
  other_workspace: 'recorded for another workspace',
  no_binding_generation: 'no recorded environment history',
  binding_changed_without_generation: 'the workspace changed without a record',
  descendants_not_contained: 'this host cannot prove child processes stopped',
};

/** English source strings for the preview's `blockedBy` reasons. */
export const BLOCKER_LABELS: Record<string, string> = {
  coordinator_not_available: 'Environment switching is disabled on this Gateway',
  resource_preflight_required: 'The Node has not checked both workspaces yet',
  node_policy_mismatch: 'The Node and Gateway policies differ',
  resource_overlap_requires_review: 'The two workspaces overlap',
  resource_unavailable: 'A workspace folder is unavailable',
  source_has_pending_work: 'The conversation still has pending work',
  source_already_fenced: 'Another switch already fences this conversation',
  mode_unavailable: 'A workspace mode is unavailable',
  preview_stale: 'The environment changed since this review',
  cross_node_handoff_not_available: 'Switching to another Node is not available',
  environment_unchanged: 'The conversation is already in this workspace',
  node_unavailable_or_unsupported: 'The Node is offline or does not support switching',
  revocation_unconfirmed: 'The Node cannot confirm or acknowledge revocation',
  target_installation_unavailable: 'The Node cannot install a new environment',
};

// ---- controller -------------------------------------------------------------------

export const BACKOFF_START_MS = 1000;
export const BACKOFF_MAX_MS = 30_000;
/** Delay before the `attempt`-th unchanged read (0-based): doubling up to the maximum. */
export const backoff = (attempt: number) =>
  Math.min(BACKOFF_MAX_MS, BACKOFF_START_MS * 2 ** Math.max(0, attempt));

export interface EnvironmentSwitchOptions {
  sessionId: string;
  api?: typeof environmentTransitionApi;
  onchange?: (state: SwitchState) => void;
  /** The binding after an installation; later commands send it as `expectedBinding`. */
  onbinding?: (binding: ConversationBinding) => void;
  sleep?: (ms: number, signal: AbortSignal) => Promise<void>;
}

const defaultSleep = (ms: number, signal: AbortSignal) =>
  new Promise<void>((resolve, reject) => {
    const timer = setTimeout(resolve, ms);
    signal.addEventListener(
      'abort',
      () => {
        clearTimeout(timer);
        reject(new DOMException('Aborted', 'AbortError'));
      },
      { once: true },
    );
  });

const errorOf = (error: unknown): NonNullable<SwitchState['error']> =>
  error instanceof ApiError
    ? {
        status: error.status,
        code: error.code,
        message: error.message,
        reason: classifySwitchFailure(error),
      }
    : { message: error instanceof Error ? error.message : String(error), reason: 'ambiguous' };

/** A read without `progress` (the receipt GET) keeps the last progress of the same state. */
function merge(previous: TransitionStatus | undefined, next: TransitionStatus): TransitionStatus {
  if (
    next.progress === undefined &&
    previous?.transition.operationId === next.transition.operationId &&
    previous.transition.state === next.transition.state
  )
    return { ...next, progress: previous.progress };
  return next;
}

/**
 * One conversation's environment switch, in memory. Request failures are
 * recorded on the state, not thrown.
 */
export class EnvironmentSwitch {
  readonly sessionId: string;
  private readonly api: typeof environmentTransitionApi;
  private readonly onchange: (state: SwitchState) => void;
  private readonly onbinding: (binding: ConversationBinding) => void;
  private readonly sleep: (ms: number, signal: AbortSignal) => Promise<void>;
  private readonly controller = new AbortController();
  private current: SwitchState = { phase: 'idle' };
  private polling = false;
  /** The lease automatic reads use; reads without one stay read-only. */
  private lease: TransitionLease | undefined;

  constructor(options: EnvironmentSwitchOptions) {
    this.sessionId = options.sessionId;
    this.api = options.api ?? environmentTransitionApi;
    this.onchange = options.onchange ?? (() => {});
    this.onbinding = options.onbinding ?? (() => {});
    this.sleep = options.sleep ?? defaultSleep;
  }

  get state(): SwitchState {
    return this.current;
  }
  /** Stops automatic reads; the Gateway's own sweep keeps authorized steps going. */
  dispose() {
    this.controller.abort();
  }
  /** The current control lease (or none); used by automatic reads only. */
  setLease(lease: TransitionLease | undefined) {
    this.lease = lease && lease.sessionId === this.sessionId ? lease : undefined;
  }

  private get disposed() {
    return this.controller.signal.aborted;
  }
  private set(next: SwitchState) {
    if (this.disposed) return;
    this.current = next;
    this.onchange(next);
  }

  private applyPreview(preview: PreviewView, extra: Partial<SwitchState> = {}) {
    const phase: SwitchPhase = preview.blockedBy.includes('coordinator_not_available')
      ? 'switching_disabled'
      : preview.state === 'stale' || preview.blockedBy.includes('preview_stale')
        ? 'review_stale'
        : preview.canConfirm && preview.observationHash
          ? 'review'
          : 'review_blocked';
    const next: SwitchState = { ...this.current, ...extra, phase, preview };
    delete next.error;
    if (extra.error) next.error = extra.error;
    this.set(next);
  }

  private async applyStatus(
    status: TransitionStatus,
    extra: Partial<SwitchState> = {},
    startPoll = true,
  ) {
    const merged = merge(this.current.status, status);
    const phase = transitionPhase(merged);
    const next: SwitchState = {
      ...this.current,
      stalled: false,
      ...extra,
      phase,
      operationId: merged.transition.operationId,
      status: merged,
      nodeUnavailable: merged.reconciliationState === 'node_unavailable',
    };
    if (!extra.error) delete next.error;
    if (!extra.digestChanged) delete next.digestChanged;
    const result = resultOf(merged);
    if (result) next.result = result;
    this.set(next);
    if (phase === 'switched') await this.adoptBinding();
    if (startPoll && pollable(phase)) void this.poll();
  }

  /** After installation the binding changed; later commands must carry the new one. */
  private async adoptBinding() {
    try {
      const { environment } = await this.api.environment(this.sessionId, this.controller.signal);
      this.set({ ...this.current, binding: environment.binding });
      if (!this.disposed) this.onbinding(environment.binding);
    } catch (error) {
      if (!isAbort(error)) this.set({ ...this.current, error: errorOf(error) });
    }
  }

  /** A read of the accepted transition: `advance` with control, else the receipt GET. */
  private read(useAdvance: boolean) {
    const id = this.current.operationId!;
    return useAdvance && this.lease && !this.current.cancelRequested
      ? this.api.advance(this.lease, id)
      : this.api.status(this.sessionId, id, this.controller.signal);
  }

  /** One reader: backs off while nothing changes; stops on a definite failure. */
  private async poll() {
    if (this.polling) return;
    this.polling = true;
    let attempt = 0;
    let last = JSON.stringify(this.current.status);
    try {
      for (;;) {
        await this.sleep(backoff(attempt), this.controller.signal);
        if (this.disposed || !pollable(this.current.phase) || this.current.stalled) return;
        try {
          const status = await this.read(true);
          const merged = merge(this.current.status, status);
          const phase = transitionPhase(merged);
          const nodeUnavailable = merged.reconciliationState === 'node_unavailable';
          const next: SwitchState = {
            ...this.current,
            phase,
            status: merged,
            nodeUnavailable,
          };
          delete next.error;
          const result = resultOf(merged);
          if (result) next.result = result;
          this.set(next);
          if (phase === 'switched') await this.adoptBinding();
          if (!pollable(phase)) return;
          const seen = JSON.stringify(merged);
          attempt = seen === last ? attempt + 1 : 0;
          last = seen;
        } catch (error) {
          if (isAbort(error)) return;
          const failure = errorOf(error);
          if (failure.reason === 'ambiguous') {
            // A read: keep reading, more slowly.
            this.set({ ...this.current, error: failure });
            attempt += 1;
            continue;
          }
          this.set({ ...this.current, error: failure, stalled: true });
          return;
        }
      }
    } catch (error) {
      if (!isAbort(error)) throw error;
    } finally {
      this.polling = false;
    }
  }

  /**
   * After a load or reload: reads the binding and any active transition. An
   * active acceptance is read with `advance` when control is held.
   */
  async discover(): Promise<void> {
    let found: Awaited<ReturnType<typeof environmentTransitionApi.environment>>;
    try {
      found = await this.api.environment(this.sessionId, this.controller.signal);
    } catch (error) {
      if (!isAbort(error)) this.set({ ...this.current, error: errorOf(error) });
      return;
    }
    const active = found.activeTransition;
    if (!active) {
      if (!this.current.operationId || PREVIEW_PHASES.includes(this.current.phase)) return;
      return this.refresh();
    }
    if (active.state === 'fenced') {
      this.set({ phase: 'legacy_fence', operationId: active.operationId });
      return;
    }
    if (this.current.operationId !== active.operationId)
      this.current = { phase: 'unknown_state', operationId: active.operationId };
    await this.refresh();
  }

  /** A new review: a fresh operation identity per user action. */
  async preview(targetWorkspaceId: string, expectedBinding: ConversationBinding) {
    // An accepted transition still in progress must end first.
    const s = this.current;
    if (s.status && !resultOf(s.status) && !PREVIEW_PHASES.includes(s.phase)) return false;
    const input: PreviewInput = { operationId: uuid(), targetWorkspaceId, expectedBinding };
    this.set({
      phase: 'previewing',
      operationId: input.operationId,
      targetWorkspaceId,
      expectedBinding,
    });
    await this.sendPreview(input);
    return true;
  }

  private async sendPreview(input: PreviewInput) {
    try {
      this.applyPreview(await this.api.preview(this.sessionId, input));
    } catch (error) {
      const failure = errorOf(error);
      if (failure.reason === 'ambiguous') return this.readPreview();
      this.set({
        ...this.current,
        phase: failure.reason === 'stale' ? 'review_stale' : 'rejected',
        error: failure,
      });
    }
  }

  private async readPreview() {
    try {
      this.applyPreview(
        await this.api.previewStatus(
          this.sessionId,
          this.current.operationId!,
          this.controller.signal,
        ),
      );
    } catch (error) {
      if (isAbort(error)) return;
      const failure = errorOf(error);
      this.set({
        ...this.current,
        phase: failure.reason === 'not_found' ? 'preview_missing' : 'preview_unknown',
        error: failure,
      });
    }
  }

  /** Confirms the shown preview with its exact hashes and the current lease, then advances. */
  async confirm(current: TransitionLease) {
    const preview = this.current.preview;
    if (
      this.current.phase !== 'review' ||
      !preview?.canConfirm ||
      !preview.observationHash ||
      current.sessionId !== this.sessionId
    )
      return false;
    const confirmation: ConfirmInput = {
      planHash: preview.planHash,
      observationHash: preview.observationHash,
      clientId: current.clientId,
      generation: current.generation,
    };
    this.lease = current;
    this.set({ ...this.current, phase: 'confirming', confirmation });
    await this.sendConfirm(confirmation, current);
    return true;
  }

  private async sendConfirm(confirmation: ConfirmInput, current: TransitionLease) {
    const id = this.current.operationId!;
    let status: TransitionStatus;
    try {
      status = await this.api.confirm(this.sessionId, id, confirmation);
    } catch (error) {
      const failure = errorOf(error);
      if (failure.reason === 'ambiguous') return this.readConfirm();
      const phase: SwitchPhase =
        failure.reason === 'disabled'
          ? 'switching_disabled'
          : failure.reason === 'stale'
            ? 'review_stale'
            : 'rejected';
      this.set({ ...this.current, phase, error: failure });
      return;
    }
    // The user confirmed the switch: continue it once now; polling follows from there.
    const more = !resultOf(status) && !this.current.cancelRequested;
    await this.applyStatus(status, {}, !more);
    if (more) await this.step(() => this.api.advance(current, id));
  }

  private async readConfirm() {
    try {
      await this.applyStatus(
        await this.api.status(this.sessionId, this.current.operationId!, this.controller.signal),
      );
    } catch (error) {
      if (isAbort(error)) return;
      const failure = errorOf(error);
      this.set({
        ...this.current,
        phase: failure.reason === 'not_found' ? 'confirm_missing' : 'confirm_unknown',
        error: failure,
      });
    }
  }

  /** Re-sends the same preview or confirmation after its record was not found. */
  async resend(current?: TransitionLease) {
    const s = this.current;
    if (
      s.phase === 'preview_missing' &&
      s.operationId &&
      s.targetWorkspaceId &&
      s.expectedBinding
    ) {
      this.set({ ...s, phase: 'previewing' });
      await this.sendPreview({
        operationId: s.operationId,
        targetWorkspaceId: s.targetWorkspaceId,
        expectedBinding: s.expectedBinding,
      });
      return true;
    }
    if (
      s.phase === 'confirm_missing' &&
      s.confirmation &&
      current &&
      current.sessionId === this.sessionId &&
      current.clientId === s.confirmation.clientId &&
      current.generation === s.confirmation.generation
    ) {
      this.set({ ...s, phase: 'confirming' });
      await this.sendConfirm(s.confirmation, current);
      return true;
    }
    return false;
  }

  /**
   * Runs one Gateway step and adopts its status. A passed-through refusal keeps
   * the request and re-reads; an ambiguous reply is resolved by a read.
   */
  private async step(run: () => Promise<TransitionStatus>, extra: Partial<SwitchState> = {}) {
    try {
      await this.applyStatus(await run(), extra);
    } catch (error) {
      if (isAbort(error)) return;
      const failure = errorOf(error);
      try {
        // Re-read: `advance` with control (it never acknowledges or cancels), else GET.
        const useAdvance =
          failure.reason !== 'lost_control' &&
          !this.current.cancelRequested &&
          !extra.cancelRequested;
        await this.applyStatus(await this.read(useAdvance), {
          ...extra,
          error: failure,
          digestChanged: failure.reason === 'digest_changed',
          stalled: failure.reason !== 'ambiguous',
        });
      } catch (readError) {
        if (isAbort(readError)) return;
        this.set({ ...this.current, ...extra, error: failure, stalled: true });
      }
    }
  }

  /** Reads the transition again: `advance` with control, else read-only. */
  async refresh(current?: TransitionLease) {
    if (current) this.setLease(current);
    const s = this.current;
    if (s.phase === 'confirm_unknown' || s.phase === 'confirm_missing') return this.readConfirm();
    if (PREVIEW_PHASES.includes(s.phase)) return s.operationId ? this.readPreview() : undefined;
    if (!s.operationId) return;
    try {
      await this.applyStatus(await this.read(true));
    } catch (error) {
      if (isAbort(error)) return;
      this.set({ ...this.current, error: errorOf(error), stalled: true });
    }
  }

  /**
   * The explicit "Acknowledge and switch": sends exactly the digest of the items
   * shown. A changed digest re-reads and shows the new items; nothing retries it.
   */
  async acknowledge(current: TransitionLease) {
    const s = this.current;
    const digest = s.status?.progress?.revocation?.digest;
    if (
      s.phase !== 'needs_acknowledgement' ||
      !digest ||
      !s.operationId ||
      current.sessionId !== this.sessionId
    )
      return false;
    this.lease = current;
    const id = s.operationId;
    await this.step(() => this.api.acknowledge(current, id, digest));
    return true;
  }

  /** Explicit cancel, until installation. Later reads stay read-only. */
  async cancel(current: TransitionLease) {
    const s = this.current;
    if (!s.operationId || !allowedSwitchActions(s, current).includes('cancel')) return false;
    if (current.sessionId !== this.sessionId) return false;
    const id = s.operationId;
    this.set({ ...s, cancelRequested: true });
    await this.step(() => this.api.cancel(current, id), { cancelRequested: true });
    return true;
  }

  /** Forgets a finished or abandoned review locally. */
  discard() {
    if (!allowedSwitchActions(this.current, undefined).includes('discard')) return false;
    this.set({ phase: 'idle' });
    return true;
  }
}
