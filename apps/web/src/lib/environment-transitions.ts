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
 * - C1–C4 (Gateway 1032): the receipt GET is the complete read model for devices
 *   without control; operation authority with explicit reauthorization; paged,
 *   immutable revocation evaluations with inherited risk; serialized
 *   cancellation and separate runtime readiness after installation.
 */
import { conversationEnvironment, type ConversationEnvironment } from './conversation-environment';
import { ApiError, isAbort, requestWithStatus } from './http';
import { uuid } from './id';
import type { ConversationBinding } from './types';

// ---- wire shapes ----------------------------------------------------------------

/**
 * `activeTransition` from the environment read. `reconciliation_required` (older
 * Gateways: `fenced`) is a Node fence with no Gateway acceptance.
 */
export interface ActiveTransition {
  operationId: string;
  state: string;
  targetWorkspaceId: string | null;
  recoveryReason: string | null;
  safeActions: string[];
}
/** A public transition summary: `lastFinishedTransition` and history items. */
export interface TransitionSummary {
  operationId: string;
  state: string;
  createdAt: number;
  targetWorkspaceId: string | null;
  targetInstalled: boolean;
  revocationConfirmed: boolean;
}
export interface TransitionHistoryPage {
  items: TransitionSummary[];
  next: string | null;
}
/** C1: finite backend permission to finish one accepted plan, shown before Confirm. */
export interface OperationAuthorityOffer {
  available: boolean;
  durationSeconds: number | null;
}
export interface AuthorityStatus {
  revision: number;
  deadlineAt: number;
  /** `active`, `expired`, `revoked` or `clock_uncertain`. */
  state: string;
  reauthorizationRequired: boolean;
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
  operationAuthority: OperationAuthorityOffer;
}
export interface RevocationItem {
  kind: string;
  reason: string;
  acknowledgeable: boolean;
  /** C2: from an earlier binding generation (or unattributed legacy evidence). */
  inherited: boolean;
  /** The recorded binding generation, or `null` for legacy rows. */
  generation: number | null;
}
export interface Revocation {
  /** Cumulative over every retained risk: `pending`, `blocked`, `unproven` or `confirmed`. */
  status: string;
  /** Kept internally; an acknowledgement binds to exactly this value. */
  digest: string | null;
  /** C2: the immutable snapshot these items belong to. */
  evaluationId: string | null;
  itemsTotal: number;
  confirmsContainment: boolean;
  /** The first page of items only; the full set is paged by `evaluationId`. */
  items: RevocationItem[];
  /** The current generation's own settlement, separate from the cumulative status. */
  currentGeneration: { status: string | null; itemsTotal: number } | null;
}
export interface Installation {
  revocation: unknown;
  environmentEvent: unknown;
  bindingCommitted: boolean;
  policyValidated: boolean;
  /** `not_started`, `ready`, `failed` or `unknown`; `null` from older Gateways. */
  runtimeReady: string | null;
}
export interface Progress {
  state: string | null;
  errorCode: string | null;
  revocationConfirmed: boolean;
  targetInstalled: boolean;
  revocation: Revocation | null;
  installation: Installation | null;
  /** When the Gateway stored this receipt (ms). */
  observedAt: number | null;
  /** G4: `review_required` for an acceptance that can no longer be sent as reviewed. */
  stage: string | null;
  waitReason: string | null;
  safeActions: string[];
  /** C3: the Node's view of a requested cancellation. */
  cancellation: { requestedAt: number | null; pendingReason: string | null } | null;
}
/** One page of an immutable evaluation snapshot. */
export interface EvaluationPage {
  evaluationId: string;
  digest: string;
  status: string;
  itemsTotal: number;
  items: RevocationItem[];
  next: string | null;
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
  /** C1: `null` without operation authority; `undefined` from older Gateways. */
  authority?: AuthorityStatus | null;
  /** C3: the Gateway's durable cancellation intent. */
  cancellation?: { requestedAt: number } | null;
}

const text = (v: unknown): v is string => typeof v === 'string' && v.length > 0;
const strings = (v: unknown) => (Array.isArray(v) ? v.filter(text) : []);
const integer = (v: unknown): v is number => typeof v === 'number' && Number.isSafeInteger(v);
const textOrNull = (v: unknown) => (text(v) ? v : null);
const object = (v: unknown): v is Record<string, any> =>
  !!v && typeof v === 'object' && !Array.isArray(v);

export function parseActiveTransition(raw: unknown): ActiveTransition | null {
  const value = raw as Record<string, unknown> | null | undefined;
  if (!value || typeof value !== 'object' || !text(value.operationId) || !text(value.state))
    return null;
  // An older Gateway's `fenced` is the same bare-fence condition.
  const bare = value.state === 'fenced' || value.state === 'reconciliation_required';
  return {
    operationId: value.operationId,
    state: bare ? 'reconciliation_required' : value.state,
    targetWorkspaceId: textOrNull(value.targetWorkspaceId),
    recoveryReason: textOrNull(value.recoveryReason),
    safeActions: bare ? ['reconcile'] : strings(value.safeActions),
  };
}

export function parseSummary(raw: any): TransitionSummary | null {
  if (!object(raw) || !text(raw.operationId) || !text(raw.state)) return null;
  return {
    operationId: raw.operationId,
    state: raw.state,
    createdAt: integer(raw.createdAt) ? raw.createdAt : 0,
    targetWorkspaceId: textOrNull(raw.targetWorkspaceId),
    targetInstalled: raw.state === 'installed' && raw.targetInstalled === true,
    revocationConfirmed: raw.state === 'installed' && raw.revocationConfirmed === true,
  };
}

function parseAuthority(raw: any): AuthorityStatus | null | undefined {
  if (raw === undefined) return undefined;
  if (!object(raw) || !integer(raw.revision) || !text(raw.state)) return null;
  return {
    revision: raw.revision,
    deadlineAt: integer(raw.deadlineAt) ? raw.deadlineAt : 0,
    state: raw.state,
    // Anything but `active` needs reauthorization, even if the flag were missing.
    reauthorizationRequired: raw.reauthorizationRequired === true || raw.state !== 'active',
  };
}

function parseItem(item: any): RevocationItem {
  return {
    kind: String(item?.kind ?? 'unknown'),
    reason: String(item?.reason ?? 'unknown'),
    acknowledgeable: item?.acknowledgeable === true,
    inherited: item?.inherited === true,
    generation: integer(item?.generation) ? item.generation : null,
  };
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
    operationAuthority: {
      available: raw.operationAuthority?.available === true,
      durationSeconds: integer(raw.operationAuthority?.durationSeconds)
        ? raw.operationAuthority.durationSeconds
        : null,
    },
  };
}

function parseRevocation(raw: any): Revocation | null {
  if (!raw || typeof raw !== 'object' || !text(raw.status)) return null;
  const items: RevocationItem[] = Array.isArray(raw.items) ? raw.items.map(parseItem) : [];
  const current = raw.currentGeneration;
  return {
    status: raw.status,
    digest: text(raw.digest) ? raw.digest : null,
    evaluationId: textOrNull(raw.evaluationId),
    itemsTotal: integer(raw.itemsTotal) ? raw.itemsTotal : items.length,
    confirmsContainment: raw.confirmsContainment === true,
    items,
    currentGeneration:
      object(current) && (text(current.status) || integer(current.itemsTotal))
        ? {
            status: textOrNull(current.status),
            itemsTotal: integer(current.itemsTotal) ? current.itemsTotal : 0,
          }
        : null,
  };
}

export function parseEvaluationPage(raw: any): EvaluationPage {
  const e = raw?.evaluation;
  if (!text(e?.evaluationId) || !text(e?.digest))
    throw new Error('Unsupported revocation evaluation page');
  const items = Array.isArray(e.items) ? e.items.map(parseItem) : [];
  return {
    evaluationId: e.evaluationId,
    digest: e.digest,
    status: String(e.status ?? ''),
    itemsTotal: integer(e.itemsTotal) ? e.itemsTotal : items.length,
    items,
    next: text(e.next) ? e.next : null,
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
            installation: object(p.installation)
              ? {
                  revocation: p.installation.revocation,
                  environmentEvent: p.installation.environmentEvent,
                  bindingCommitted: p.installation.bindingCommitted === true,
                  policyValidated: p.installation.policyValidated === true,
                  runtimeReady: textOrNull(p.installation.runtimeReady),
                }
              : null,
            observedAt: integer(p.observedAt) ? p.observedAt : null,
            stage: textOrNull(p.stage),
            waitReason: textOrNull(p.waitReason),
            safeActions: strings(p.safeActions),
            cancellation: object(p.cancellation)
              ? {
                  requestedAt: integer(p.cancellation.requestedAt)
                    ? p.cancellation.requestedAt
                    : null,
                  pendingReason: textOrNull(p.cancellation.pendingReason),
                }
              : null,
          }
        : null;
  const authority = parseAuthority(raw.authority);
  const cancellation =
    raw.cancellation === undefined
      ? undefined
      : object(raw.cancellation) && integer(raw.cancellation.requestedAt)
        ? { requestedAt: raw.cancellation.requestedAt }
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
    ...(authority !== undefined ? { authority } : {}),
    ...(cancellation !== undefined ? { cancellation } : {}),
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
const post = async (path: string, body?: unknown) =>
  (
    await requestWithStatus<unknown>(path, {
      method: 'POST',
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    })
  ).body;
const page = (params: { cursor?: string; limit?: number }) => {
  const search = new URLSearchParams();
  if (params.cursor !== undefined) search.set('cursor', params.cursor);
  if (params.limit !== undefined) search.set('limit', String(params.limit));
  const text = search.toString();
  return text ? `?${text}` : '';
};
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
      /** G2: the newest installed or released transition, after `activeTransition` is gone. */
      lastFinishedTransition: parseSummary(raw?.lastFinishedTransition),
    };
  },
  /** G2: one page of this conversation's accepted transitions, newest first. */
  history: async (
    sessionId: string,
    params: { cursor?: string; limit?: number } = {},
    signal?: AbortSignal,
  ): Promise<TransitionHistoryPage> => {
    const raw = (await get(`${transitions(sessionId)}${page(params)}`, signal)) as any;
    const list = raw?.transitions;
    return {
      items: Array.isArray(list?.items)
        ? list.items.map(parseSummary).filter((i: TransitionSummary | null) => !!i)
        : [],
      next: text(list?.next) ? list.next : null,
    };
  },
  preview: async (sessionId: string, input: PreviewInput) =>
    parsePreview(await post(`${transitions(sessionId)}/previews`, input)),
  previewStatus: async (sessionId: string, operationId: string, signal?: AbortSignal) =>
    parsePreview(await get(`${transitions(sessionId)}/previews/${op(operationId)}`, signal)),
  confirm: async (sessionId: string, operationId: string, input: ConfirmInput) =>
    parseStatus(await post(`${transitions(sessionId)}/previews/${op(operationId)}/confirm`, input)),
  /**
   * The complete persisted read model of an accepted transition (G1): progress
   * with `observedAt`, authority and cancellation. No lease, no Node call.
   */
  status: async (sessionId: string, operationId: string, signal?: AbortSignal) =>
    parseStatus(await get(`${transitions(sessionId)}/receipts/${op(operationId)}`, signal)),
  /** Continues already-authorized steps and returns the status with `progress`. */
  advance: async (l: TransitionLease, operationId: string) =>
    parseStatus(await post(`${transitions(l.sessionId)}/${op(operationId)}/advance`, lease(l))),
  /** Consent covers every item of the evaluation snapshot `evaluationId` (C2). */
  acknowledge: async (
    l: TransitionLease,
    operationId: string,
    digest: string,
    evaluationId?: string | null,
  ) =>
    parseStatus(
      await post(`${transitions(l.sessionId)}/${op(operationId)}/acknowledge`, {
        digest,
        ...(evaluationId ? { evaluationId } : {}),
        ...lease(l),
      }),
    ),
  /** C1: the next authority revision for the same operation (current control only). */
  reauthorize: async (l: TransitionLease, operationId: string) =>
    parseStatus(await post(`${transitions(l.sessionId)}/${op(operationId)}/reauthorize`, lease(l))),
  /** G3: read-only receipt reconciliation, the only action for a bare Node fence. */
  reconcile: async (sessionId: string, operationId: string) => {
    const raw = (await post(
      `${transitions(sessionId)}/previews/${op(operationId)}/reconcile`,
    )) as any;
    return { state: text(raw?.state) ? raw.state : 'unknown' };
  },
  /** C2: one page of an immutable evaluation snapshot; read-only, no control. */
  evaluation: async (
    sessionId: string,
    operationId: string,
    evaluationId: string,
    params: { cursor?: string; limit?: number } = {},
    signal?: AbortSignal,
  ) =>
    parseEvaluationPage(
      await get(
        `${transitions(sessionId)}/${op(operationId)}/evaluations/${op(evaluationId)}${page(params)}`,
        signal,
      ),
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
  // C1–C3
  'operation_authority_missing',
  'operation_authority_superseded',
  'operation_authority_revoked',
  'operation_authority_expired',
  'operation_authority_clock_uncertain',
  'operation_authority_revision',
  'operation_authority_unavailable',
  'plan_changed',
  'transition_ended',
  'transition_cancel_requested',
] as const;

/** G5: only these 404s mean "not stored"; any other 404 is a definite refusal. */
export const NOT_STORED = [
  'preview_not_found',
  'acceptance_not_found',
  'receipt_not_found',
  'conversation_not_found',
] as const;

/**
 * `ambiguous`: network loss or any 5xx (including `transition_step_failed` and
 * `invalid_transition_receipt`); resolved by GET or `advance`, never by a
 * mutation with a new identity. `not_found`: one of {@link NOT_STORED}.
 * `disabled`: switching is off on this Gateway. `stale`: review again.
 * `authority`: operation authority cannot be used (reauthorize).
 * `plan_changed`: a new transition is needed. Every other code is definite.
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
  | 'authority'
  | 'authority_unavailable'
  | 'plan_changed'
  | 'cancel_requested'
  | 'rejected';
export function classifySwitchFailure(error: unknown): SwitchFailure {
  if (!(error instanceof ApiError)) return 'ambiguous';
  if (error.status >= 500) return 'ambiguous';
  if (error.status === 404)
    return (NOT_STORED as readonly string[]).includes(error.code) ? 'not_found' : 'rejected';
  if (error.code === 'operation_authority_unavailable') return 'authority_unavailable';
  if (error.code.startsWith('operation_authority_')) return 'authority';
  switch (error.code) {
    case 'plan_changed':
      return 'plan_changed';
    case 'transition_cancel_requested':
      return 'cancel_requested';
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
  | 'review_required' // `accepted` that can no longer be sent as reviewed (G4): cancel only
  | 'outcome_unknown' // `outcome_unknown`: the Node fence is being reconciled
  | 'draining' // `node_fenced` without progress, or revocation `pending`
  | 'blocked' // revocation `blocked`: shown, never acknowledgeable
  | 'needs_acknowledgement' // revocation `unproven`
  | 'installing' // revocation `confirmed`, not installed yet
  | 'authority_required' // ready to install, but operation authority lapsed (C1)
  | 'cancel_pending' // cancellation requested, not yet settled (C3)
  | 'switched' // `installed`; readiness is reported separately
  | 'cancelled' // `released`
  | 'deleted' // `deleted`
  | 'reconciliation_required' // a Node fence without a Gateway acceptance: reconcile only
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
  | 'reauthorize'
  | 'reconcile'
  | 'more_items'
  | 'discard';

export type SwitchResult =
  | 'revocation_confirmed' // "switched; revocation confirmed"
  | 'revocation_not_fully_confirmed' // "switched; revocation not fully confirmed"
  | 'original_kept'; // "cancelled; original workspace kept"

const TERMINAL = ['installed', 'released', 'deleted'];

/** Maps an accepted transition's state, progress, authority and cancellation to a phase. */
export function transitionPhase(status: TransitionStatus): SwitchPhase {
  const state = status.transition.state;
  const p = status.progress;
  if (state === 'reconciliation_required' || state === 'fenced') return 'reconciliation_required';
  if (!TERMINAL.includes(state)) {
    // A requested cancellation wins: no install, acknowledgement or reauthorization follows.
    if (status.cancellation || p?.cancellation?.requestedAt != null) return 'cancel_pending';
    if (state === 'accepted' && p?.stage === 'review_required') return 'review_required';
  }
  switch (state) {
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
          return status.authority?.reauthorizationRequired ? 'authority_required' : 'installing';
        default:
          return 'unknown_state';
      }
    case 'installed':
      return 'switched';
    case 'released':
      return 'cancelled';
    case 'deleted':
      return 'deleted';
    default:
      return 'unknown_state';
  }
}

/** C3: runtime readiness of an installed transition (`undefined` before installation). */
export function readinessOf(status: TransitionStatus | undefined): string | null | undefined {
  if (status?.transition.state !== 'installed') return undefined;
  return status.progress?.installation?.runtimeReady ?? null;
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
  phase === 'draining' ||
  phase === 'outcome_unknown' ||
  phase === 'installing' ||
  phase === 'awaiting_dispatch' ||
  phase === 'cancel_pending';

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
  /** C2: the full item set paged so far from one immutable evaluation snapshot. */
  evaluation?: {
    evaluationId: string;
    digest: string;
    itemsTotal: number;
    items: RevocationItem[];
    next: string | null;
    complete: boolean;
  };
  /** G2: the newest finished transition, from the environment read. */
  lastFinished?: TransitionSummary | null;
  /** G3: why a bare Node fence needs reconciliation, and the reviewed target. */
  recoveryReason?: string | null;
  /** The last read-only reconciliation's observation (`fenced`, `node_unavailable`, …). */
  reconciliation?: string;
}

/** C1: authority lapsed on a transition that can still install. */
export function needsReauthorization(state: SwitchState): boolean {
  const status = state.status;
  return (
    !!status?.authority?.reauthorizationRequired &&
    !TERMINAL.includes(status.transition.state) &&
    state.phase !== 'cancel_pending' &&
    state.phase !== 'reconciliation_required'
  );
}

/** What the user may do now. No automatic acknowledgement, cancel or resend. */
export function allowedSwitchActions(
  state: SwitchState,
  current: TransitionLease | undefined,
): SwitchAction[] {
  const control = !!current;
  const reauthorize: SwitchAction[] = control && needsReauthorization(state) ? ['reauthorize'] : [];
  const revocation = state.status?.progress?.revocation;
  const more: SwitchAction[] =
    revocation?.evaluationId &&
    revocation.itemsTotal > revocation.items.length &&
    !(state.evaluation?.evaluationId === revocation.evaluationId && state.evaluation.complete)
      ? ['more_items']
      : [];
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
    case 'installing':
      return control ? [...reauthorize, 'refresh', 'cancel'] : ['refresh'];
    case 'blocked':
      return control ? [...more, ...reauthorize, 'refresh', 'cancel'] : [...more, 'refresh'];
    case 'authority_required':
      return control ? ['reauthorize', 'refresh', 'cancel'] : ['refresh'];
    case 'review_required':
      // G4 `safeActions: ["cancel"]`: nothing reaches the Node.
      return control ? ['cancel', 'refresh'] : ['refresh'];
    case 'cancel_pending':
      return ['refresh'];
    case 'needs_acknowledgement':
      return control && revocation?.digest
        ? [...more, 'acknowledge', ...reauthorize, 'refresh', 'cancel']
        : [...more, 'refresh'];
    case 'switched': {
      const ready = readinessOf(state.status);
      return ready && ready !== 'ready' ? ['refresh', 'discard'] : ['discard'];
    }
    case 'cancelled':
    case 'deleted':
      return ['discard'];
    case 'reconciliation_required':
      return ['reconcile'];
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

/** C3: why a requested cancellation has not settled yet. */
export const CANCEL_PENDING_LABELS: Record<string, string> = {
  drain_active: 'work is still stopping',
  resources_unresolved: 'some resources are not settled yet',
  original_binding_invalid: 'the original workspace is no longer valid; access is not restored',
};
/** C3: runtime readiness after installation. */
export const READINESS_LABELS: Record<string, string> = {
  not_started: 'Switched; execution not started.',
  ready: 'Switched; execution ready.',
  failed: 'Switched; execution failed to start.',
  unknown: 'Switched; execution state unknown.',
};
/** G4 wait reasons and G3 recovery reasons. */
export const WAIT_REASON_LABELS: Record<string, string> = {
  lost_control: 'control moved to another device',
  stale_environment: 'the reviewed environment changed',
  no_gateway_acceptance: 'the Node holds a fence this Gateway never accepted',
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
    // Pages belong to one immutable snapshot; a new evaluation needs a new review.
    const evaluationId = merged.progress?.revocation?.evaluationId;
    if (next.evaluation && next.evaluation.evaluationId !== evaluationId) {
      delete next.evaluation;
      if (evaluationId) next.digestChanged = true;
    }
    const result = resultOf(merged);
    if (result) next.result = result;
    this.set(next);
    if (phase === 'switched' && !this.current.binding) await this.adoptBinding();
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

  /**
   * A read of the accepted transition: `advance` with control, else the receipt
   * GET (the complete read model, G1). After a cancel the Gateway has not
   * recorded yet, only the GET is used, so nothing can install past it; once the
   * cancellation is recorded, `advance` only drives the Node drain (C3).
   */
  private read(useAdvance: boolean) {
    const id = this.current.operationId!;
    const unrecordedCancel = this.current.cancelRequested && !this.current.status?.cancellation;
    return useAdvance && this.lease && !unrecordedCancel
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
          await this.applyStatus(await this.read(true), {}, false);
          if (!pollable(this.current.phase)) return;
          const seen = JSON.stringify(this.current.status);
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
    const lastFinished = found.lastFinishedTransition;
    if (!active) {
      if (!this.current.operationId || PREVIEW_PHASES.includes(this.current.phase)) {
        this.set({ ...this.current, lastFinished });
        return;
      }
      this.current = { ...this.current, lastFinished };
      return this.refresh();
    }
    if (active.state === 'reconciliation_required') {
      // Not consent: only the read-only reconciliation is offered (G3).
      this.set({
        phase: 'reconciliation_required',
        operationId: active.operationId,
        targetWorkspaceId: active.targetWorkspaceId ?? undefined,
        recoveryReason: active.recoveryReason,
        lastFinished,
        ...(this.current.operationId === active.operationId && this.current.reconciliation
          ? { reconciliation: this.current.reconciliation }
          : {}),
      });
      return;
    }
    if (this.current.operationId !== active.operationId)
      this.current = {
        phase: 'unknown_state',
        operationId: active.operationId,
        targetWorkspaceId: active.targetWorkspaceId ?? undefined,
      };
    this.current = { ...this.current, lastFinished };
    await this.refresh();
  }

  /** G3: the read-only receipt reconciliation of a bare Node fence, then a fresh read. */
  async reconcile() {
    const s = this.current;
    if (s.phase !== 'reconciliation_required' || !s.operationId) return false;
    try {
      const { state } = await this.api.reconcile(this.sessionId, s.operationId);
      this.set({ ...this.current, reconciliation: state });
    } catch (error) {
      if (isAbort(error)) return true;
      this.set({ ...this.current, error: errorOf(error) });
      return true;
    }
    await this.discover();
    return true;
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
    const revocation = s.status?.progress?.revocation;
    const digest = revocation?.digest;
    if (
      s.phase !== 'needs_acknowledgement' ||
      !digest ||
      !s.operationId ||
      current.sessionId !== this.sessionId
    )
      return false;
    this.lease = current;
    const id = s.operationId;
    // The consent covers all `itemsTotal` items of this snapshot, not the page shown.
    const evaluationId = revocation.evaluationId;
    await this.step(() => this.api.acknowledge(current, id, digest, evaluationId));
    return true;
  }

  /** C1: renews operation authority (next revision, same operation) with current control. */
  async reauthorize(current: TransitionLease) {
    const s = this.current;
    if (!s.operationId || current.sessionId !== this.sessionId) return false;
    if (!allowedSwitchActions(s, current).includes('reauthorize')) return false;
    this.lease = current;
    const id = s.operationId;
    await this.step(() => this.api.reauthorize(current, id));
    return true;
  }

  /**
   * C2: pages the full item set of the evaluation shown, from its immutable
   * snapshot. Pages of a snapshot that is no longer current are dropped.
   */
  async loadMoreItems(limit?: number) {
    const s = this.current;
    const revocation = s.status?.progress?.revocation;
    const evaluationId = revocation?.evaluationId;
    if (!s.operationId || !evaluationId) return false;
    const known = s.evaluation?.evaluationId === evaluationId ? s.evaluation : undefined;
    if (known?.complete) return false;
    try {
      const page = await this.api.evaluation(
        this.sessionId,
        s.operationId,
        evaluationId,
        { cursor: known?.next ?? undefined, limit },
        this.controller.signal,
      );
      const now = this.current.status?.progress?.revocation;
      if (page.evaluationId !== evaluationId || now?.evaluationId !== evaluationId) return true;
      if (known && (page.digest !== known.digest || page.next === known.next))
        throw new Error('The evaluation pages did not form one snapshot');
      this.set({
        ...this.current,
        evaluation: {
          evaluationId,
          digest: page.digest,
          itemsTotal: page.itemsTotal,
          items: [...(known?.items ?? []), ...page.items],
          next: page.next,
          complete: page.next === null,
        },
      });
    } catch (error) {
      if (!isAbort(error)) this.set({ ...this.current, error: errorOf(error) });
    }
    return true;
  }

  /** Pages the whole snapshot (bounded by its total). */
  async loadAllItems(limit?: number) {
    for (let guard = 0; guard < 10_000; guard++) {
      const before = this.current.evaluation;
      if (!(await this.loadMoreItems(limit))) return;
      const after = this.current.evaluation;
      if (!after || after.complete || after === before || this.current.error) return;
    }
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
