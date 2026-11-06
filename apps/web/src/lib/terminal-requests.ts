/**
 * Client side of the terminal execution-path contract v1
 * (plans/execution-isolation.md, "Client terminal execution-path contract v1").
 *
 * - The ordinary New terminal action opens an isolated work terminal with a
 *   durable `requestId`; it never falls back to the omitted-path host terminal.
 * - Host management is a separate, explicit review → confirm action.
 * - Lost or ambiguous replies are resolved by GET. A `404` allows sending the
 *   same ID with the same intent again; a changed control lease or size only
 *   allows reading. Nothing is retried automatically.
 * - Pending request IDs live in memory only; after a reload they are rediscovered
 *   through `unresolvedRequests`, so no storage format changes.
 * - v3: an `outcome_unknown` request may be acknowledged. That is a retained user
 *   decision that hides it from discovery; its state stays `outcome_unknown`.
 */
import { ApiError, isAbort, requestWithStatus } from './http';
import { uuid } from './id';
import type { TerminalInfo } from './panel-api';

/** Discovery and result parity: the oldest Node version this client accepts. */
export const REQUIRED_WORK_REQUEST_VERSION = 2;
/** Acknowledgement and the specific error codes. */
export const ACKNOWLEDGE_VERSION = 3;
/** How often a `preparing` work request is read again. */
export const POLL_INTERVAL_MS = 1000;
/** The Node's largest unresolved-request page. */
export const MAX_PAGE = 100;

export interface TerminalCapabilities {
  enabled: boolean;
  isolatedTerminalVersion: number;
  hostTerminalReviewVersion: number;
  workTerminalRequestVersion: number;
}

/** What the ordinary and explicit terminal actions may do on this Node. */
export type TerminalOffer =
  /** No capability document, or a Node without discovery/parity: ask to update the Node. */
  | { kind: 'update_node' }
  /** No new terminal of any path; existing terminals and results stay readable. */
  | { kind: 'disabled' }
  /** The ordinary action opens an isolated work terminal. */
  | { kind: 'isolated'; hostManagement: boolean }
  /** The ordinary action shows isolation is unavailable; host management only explicitly. */
  | { kind: 'isolation_unavailable'; hostManagement: boolean };

const version = (value: unknown) =>
  typeof value === 'number' && Number.isFinite(value) ? value : 0;

/** The `terminalCapabilities` document; `null` for a Node without the query. Missing fields are 0. */
export function parseCapabilities(body: unknown): TerminalCapabilities | null {
  const raw = (body as { terminalCapabilities?: unknown } | null)?.terminalCapabilities;
  if (!raw || typeof raw !== 'object') return null;
  const caps = raw as Record<string, unknown>;
  return {
    enabled: caps.enabled === true,
    isolatedTerminalVersion: version(caps.isolatedTerminalVersion),
    hostTerminalReviewVersion: version(caps.hostTerminalReviewVersion),
    workTerminalRequestVersion: version(caps.workTerminalRequestVersion),
  };
}

export function terminalOffer(caps: TerminalCapabilities | null): TerminalOffer {
  if (!caps || caps.workTerminalRequestVersion < REQUIRED_WORK_REQUEST_VERSION)
    return { kind: 'update_node' };
  if (!caps.enabled) return { kind: 'disabled' };
  const hostManagement = caps.hostTerminalReviewVersion >= 1;
  return caps.isolatedTerminalVersion >= 1
    ? { kind: 'isolated', hostManagement }
    : { kind: 'isolation_unavailable', hostManagement };
}

/** Whether unresolved-request discovery may be read (it needs no new-terminal capability). */
export const canDiscover = (caps: TerminalCapabilities | null) =>
  !!caps && caps.workTerminalRequestVersion >= REQUIRED_WORK_REQUEST_VERSION;
/** Whether `outcome_unknown` requests may be acknowledged (it needs no new-terminal capability). */
export const canAcknowledge = (caps: TerminalCapabilities | null | undefined) =>
  !!caps && caps.workTerminalRequestVersion >= ACKNOWLEDGE_VERSION;

// ---- wire shapes ----------------------------------------------------------------

export interface WorkRequestResult {
  version: number;
  requestId: string;
  state: string;
  errorCode: string | null;
  terminalId: string | null;
  /** v3: when the user acknowledged an `outcome_unknown` request; absent or null otherwise. */
  acknowledgedAt?: number | null;
}
export interface HostReviewDetails {
  version: number;
  executionPath: 'host_management';
  workspaceId: string;
  cwd: string;
  shell: string;
  cols: number;
  rows: number;
  runnerEpoch: number;
  /** Shown verbatim. */
  warning: string;
}
export interface HostManagementResult extends WorkRequestResult {
  /** The `reviewId` to confirm. */
  id: string;
  reviewHash: string;
  review: HostReviewDetails;
  expiresAt: number;
}
export type TerminalRequestResult =
  | { workRequest: WorkRequestResult; terminal: TerminalInfo | null }
  | { hostManagement: HostManagementResult; terminal: TerminalInfo | null };
export interface TerminalRequestPage {
  terminalRequests: { version: number; items: TerminalRequestResult[]; next: string | null };
}

export type RequestKind = 'work' | 'host';
export const kindOf = (result: TerminalRequestResult): RequestKind =>
  'workRequest' in result ? 'work' : 'host';
export const recordOf = (result: TerminalRequestResult): WorkRequestResult =>
  'workRequest' in result ? result.workRequest : result.hostManagement;

/** The control lease and size a POST is bound to (the Node's intent digest covers them). */
export interface TerminalIntent {
  sessionId: string;
  clientId: string;
  generation: number;
  cols: number;
  rows: number;
}
export const sameIntent = (a: TerminalIntent | undefined, b: TerminalIntent | undefined) =>
  !!a &&
  !!b &&
  a.sessionId === b.sessionId &&
  a.clientId === b.clientId &&
  a.generation === b.generation &&
  a.cols === b.cols &&
  a.rows === b.rows;
/** The lease alone: a review fixes its own (Node-clamped) size. */
export const sameLease = (a: TerminalIntent | undefined, b: TerminalIntent | undefined) =>
  !!a &&
  !!b &&
  a.sessionId === b.sessionId &&
  a.clientId === b.clientId &&
  a.generation === b.generation;

/** One user action's ID; never minted again for the same action. */
export const newRequestId = () => uuid();

// ---- API --------------------------------------------------------------------------

const path = (sessionId: string) => `/api/sessions/${encodeURIComponent(sessionId)}/terminals`;
const query = (sessionId: string, params: Record<string, string | number | undefined>) => {
  const search = new URLSearchParams();
  for (const [key, value] of Object.entries(params))
    if (value !== undefined) search.set(key, String(value));
  return `${path(sessionId)}?${search}`;
};
const post = <T>(intent: TerminalIntent, body: Record<string, unknown>) =>
  requestWithStatus<T>(path(intent.sessionId), {
    method: 'POST',
    body: JSON.stringify({
      ...body,
      clientId: intent.clientId,
      generation: intent.generation,
      cols: intent.cols,
      rows: intent.rows,
    }),
  });

export const terminalRequestApi = {
  /** `null` for a Node that does not answer the capability query. */
  capabilities: async (sessionId: string, signal?: AbortSignal) =>
    parseCapabilities(
      (await requestWithStatus<unknown>(query(sessionId, { capabilities: 1 }), { signal })).body,
    ),
  /** `201` first finished result, `200` repeat, `202` still preparing. */
  submitWork: (intent: TerminalIntent, requestId: string) =>
    post<TerminalRequestResult>(intent, { executionPath: 'isolated_work', requestId }),
  workResult: async (sessionId: string, requestId: string, signal?: AbortSignal) =>
    (
      await requestWithStatus<TerminalRequestResult>(
        query(sessionId, { workRequestId: requestId }),
        { signal },
      )
    ).body,
  reviewHost: (intent: TerminalIntent, requestId: string) =>
    post<TerminalRequestResult>(intent, {
      executionPath: 'host_management',
      action: 'review',
      requestId,
    }),
  /** `intent` must carry the reviewed size; Node rechecks lease and size. */
  confirmHost: (intent: TerminalIntent, review: HostManagementResult) =>
    post<TerminalRequestResult>(intent, {
      executionPath: 'host_management',
      action: 'confirm',
      requestId: review.requestId,
      reviewId: review.id,
      reviewHash: review.reviewHash,
      confirmed: true,
    }),
  hostResult: async (sessionId: string, requestId: string, signal?: AbortSignal) =>
    (
      await requestWithStatus<TerminalRequestResult>(
        query(sessionId, { hostRequestId: requestId }),
        { signal },
      )
    ).body,
  unresolvedPage: async (
    sessionId: string,
    options: { after?: string; limit?: number } = {},
    signal?: AbortSignal,
  ) =>
    (
      await requestWithStatus<TerminalRequestPage>(
        query(sessionId, { unresolvedRequests: 1, limit: options.limit, after: options.after }),
        { signal },
      )
    ).body.terminalRequests,
  /**
   * v3: records the user's acknowledgement of an `outcome_unknown` request.
   * Exactly one ID and the current lease, no other fields; the state stays.
   */
  acknowledge: (
    lease: Pick<TerminalIntent, 'sessionId' | 'clientId' | 'generation'>,
    kind: RequestKind,
    requestId: string,
  ) =>
    requestWithStatus<TerminalRequestResult>(path(lease.sessionId), {
      method: 'POST',
      body: JSON.stringify({
        action: 'acknowledge',
        clientId: lease.clientId,
        generation: lease.generation,
        [kind === 'work' ? 'workRequestId' : 'hostRequestId']: requestId,
      }),
    }),
  /** Every unresolved request: pages may be short or empty; follows `next` until null. */
  unresolved: async (sessionId: string, options: { limit?: number } = {}, signal?: AbortSignal) => {
    const items: TerminalRequestResult[] = [];
    let after: string | undefined;
    for (;;) {
      const page = await terminalRequestApi.unresolvedPage(
        sessionId,
        { after, limit: options.limit },
        signal,
      );
      items.push(...(page.items ?? []));
      if (page.next == null) return items;
      if (page.next === after) throw new Error('Unresolved terminal requests did not advance');
      after = page.next;
    }
  },
};

// ---- failures ---------------------------------------------------------------------

/**
 * `ambiguous`: the request may or may not have been admitted (network loss,
 * relay `504 node_timeout`/`503 node_offline`, any 5xx); resolve by GET.
 * `not_found`: only `404 terminal_request_not_found`, the ID was not admitted;
 * any other `404` (a missing session, an older Node) is `rejected`.
 * `conflict`: the ID belongs to a different intent. `review_required`: a host
 * review that cannot be confirmed as sent. `capacity`: `409 terminal_capacity`,
 * too many terminals. `not_unknown`: acknowledging a request that is no longer
 * `outcome_unknown`. `rejected`: any other definite refusal.
 */
export type Failure =
  | 'ambiguous'
  | 'not_found'
  | 'conflict'
  | 'review_required'
  | 'capacity'
  | 'not_unknown'
  | 'rejected';
export function classifyFailure(error: unknown): Failure {
  if (!(error instanceof ApiError)) return 'ambiguous';
  if (error.status === 404)
    return error.code === 'terminal_request_not_found' ? 'not_found' : 'rejected';
  if (error.status === 409) {
    if (error.code === 'work_terminal_request_conflict') return 'conflict';
    if (error.code === 'host_terminal_review_required') return 'review_required';
    if (error.code === 'terminal_capacity') return 'capacity';
    if (error.code === 'terminal_request_not_unknown') return 'not_unknown';
  }
  return error.status >= 500 ? 'ambiguous' : 'rejected';
}

// ---- state mapping ----------------------------------------------------------------

/**
 * Client states. The first eight follow the contract's state table; the rest
 * belong to a request this page sent whose result is not known yet.
 */
export type RequestPhase =
  | 'review' // host `review`
  | 'review_unusable' // host `stale` / `expired`
  | 'preparing' // work `preparing`
  | 'live' // `launching` / `running` with `terminal`
  | 'not_started' // `not_started` + `errorCode`
  | 'start_unconfirmed' // `outcome_unknown` (and a live state without a terminal)
  | 'closed' // `settled`
  | 'closed_unconfirmed' // `unconfirmed`
  | 'unknown_state' // a state this client does not know
  | 'submitting' // POST in flight
  | 'checking' // GET after an ambiguous POST
  | 'unknown_delivery' // ambiguous POST and the GET did not answer either
  | 'not_admitted' // GET `404`
  | 'rejected'; // definite refusal before admission

export type RequestAction =
  | 'confirm' // host review: exact reviewId/reviewHash, confirmed: true
  | 'attach' // live terminal stream for terminal.id
  | 'refresh' // GET the result
  | 'resubmit' // same ID, same intent (only after a 404)
  | 'new_terminal' // a new action with a new ID
  | 'host_review' // the explicit host-management action, new ID
  | 'acknowledge' // v3: retained decision about `outcome_unknown`; hides it from discovery
  | 'dismiss'; // hide locally

/** Maps a Node result state to a client phase. */
export function phaseOf(result: TerminalRequestResult): RequestPhase {
  const { state } = recordOf(result);
  const host = kindOf(result) === 'host';
  switch (state) {
    case 'review':
      return host ? 'review' : 'unknown_state';
    case 'stale':
    case 'expired':
      return host ? 'review_unusable' : 'unknown_state';
    case 'preparing':
      return host ? 'unknown_state' : 'preparing';
    case 'launching':
    case 'running':
      // Node reports a live state only with its terminal; without one, nothing is confirmed.
      return result.terminal ? 'live' : 'start_unconfirmed';
    case 'not_started':
      return 'not_started';
    case 'outcome_unknown':
      return 'start_unconfirmed';
    case 'settled':
      return 'closed';
    case 'unconfirmed':
      return 'closed_unconfirmed';
    default:
      return 'unknown_state';
  }
}

/** States in which workspace switching may stay blocked. */
export const blocksTransitions = (phase: RequestPhase) =>
  phase === 'start_unconfirmed' || phase === 'closed_unconfirmed' || phase === 'unknown_state';

export interface TrackedRequest {
  kind: RequestKind;
  requestId: string;
  /** Known only for requests this page sent; discovered requests have none. */
  intent?: TerminalIntent;
  phase: RequestPhase;
  result?: TerminalRequestResult;
  /** The last failure, for display; `reason` tells e.g. `capacity` apart. */
  error?: { status?: number; code?: string; message: string; reason?: Failure };
  /** A `409` answered with the original request's result. */
  conflict?: boolean;
  /** Polling stopped after a failed read; `refresh` resumes it. */
  stalled?: boolean;
}

export interface ActionContext {
  /** The current lease and size; `undefined` without control. */
  intent?: TerminalIntent;
  offer: TerminalOffer;
  /** {@link canAcknowledge} for this Node (v3); off by default. */
  acknowledge?: boolean;
}

/** An `outcome_unknown` request not acknowledged yet. */
export function acknowledgeable(request: TrackedRequest): boolean {
  const record = request.result && recordOf(request.result);
  return (
    request.phase === 'start_unconfirmed' &&
    record?.state === 'outcome_unknown' &&
    record.acknowledgedAt == null
  );
}
/** Acknowledged and still `outcome_unknown`: no longer pending, and not closed either. */
const acknowledged = (result: TerminalRequestResult) => {
  const record = recordOf(result);
  return record.state === 'outcome_unknown' && record.acknowledgedAt != null;
};

/** What the user may do with a request now. No automatic retry or force-clear exists. */
export function allowedActions(request: TrackedRequest, context: ActionContext): RequestAction[] {
  const offer = context.offer;
  const hostManagement =
    (offer.kind === 'isolated' || offer.kind === 'isolation_unavailable') && offer.hostManagement;
  const canStart = offer.kind === 'isolated' && !!context.intent;
  switch (request.phase) {
    case 'review':
      return canConfirm(request, context.intent)
        ? ['confirm', 'refresh', 'dismiss']
        : ['refresh', 'dismiss'];
    case 'review_unusable':
      return [...(hostManagement && context.intent ? (['host_review'] as const) : []), 'dismiss'];
    case 'preparing':
      return request.stalled ? ['refresh'] : [];
    case 'live':
      return ['attach'];
    case 'not_started': {
      const unavailable = recordOf(request.result!).errorCode === 'isolated_terminal_unavailable';
      const next: RequestAction[] = [];
      if (request.kind === 'work' && canStart) next.push('new_terminal');
      if ((request.kind === 'host' || unavailable) && hostManagement && context.intent)
        next.push('host_review');
      return [...next, 'dismiss'];
    }
    case 'start_unconfirmed':
      // Acknowledging needs the current lease, not the one that made the request.
      return context.acknowledge && context.intent && acknowledgeable(request)
        ? ['acknowledge', 'refresh', 'dismiss']
        : ['refresh', 'dismiss'];
    case 'unknown_state':
      return ['refresh', 'dismiss'];
    case 'closed':
    case 'closed_unconfirmed':
      return ['dismiss'];
    case 'submitting':
    case 'checking':
      return [];
    case 'unknown_delivery':
      return ['refresh'];
    case 'not_admitted':
      // Same ID, same intent only; after a lease change or resize the action is dropped.
      return sameIntent(request.intent, context.intent) ? ['resubmit', 'dismiss'] : ['dismiss'];
    case 'rejected':
      return ['dismiss'];
  }
}

/**
 * A review binds the lease it was made under (its digest covers clientId and
 * generation): a changed lease needs a new review. A discovered review has no
 * known lease here, so the Node checks it.
 */
function canConfirm(request: TrackedRequest, current: TerminalIntent | undefined) {
  if (request.phase !== 'review' || !current) return false;
  if (!request.result || !('hostManagement' in request.result)) return false;
  return !request.intent || sameLease(request.intent, current);
}

/** The intent a confirm is sent with: the current lease and the reviewed (clamped) size. */
export function confirmIntent(
  review: HostManagementResult,
  current: TerminalIntent,
): TerminalIntent {
  return { ...current, cols: review.review.cols, rows: review.review.rows };
}

// ---- controller -------------------------------------------------------------------

export interface TerminalRequestsOptions {
  sessionId: string;
  /** The session's capabilities, if already read; see {@link TerminalRequests.capabilities}. */
  capabilities?: TerminalCapabilities | null;
  api?: typeof terminalRequestApi;
  /** Called after every change with the current list. */
  onchange?: (requests: TrackedRequest[]) => void;
  /** Called once per live terminal to attach its existing stream. */
  onterminal?: (terminal: TerminalInfo) => void;
  pollInterval?: number;
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

const errorOf = (error: unknown): TrackedRequest['error'] =>
  error instanceof ApiError
    ? {
        status: error.status,
        code: error.code,
        message: error.message,
        reason: classifyFailure(error),
      }
    : {
        message: error instanceof Error ? error.message : String(error),
        reason: 'ambiguous',
      };

/**
 * The terminal requests of one session, in memory. Request failures are
 * recorded on the request, not thrown; only {@link TerminalRequests.recover}
 * rejects when discovery cannot be read.
 */
export class TerminalRequests {
  readonly sessionId: string;
  /** The Node's capabilities; acknowledgement is sent only to a v3 Node. */
  capabilities: TerminalCapabilities | null;
  private readonly api: typeof terminalRequestApi;
  private readonly onchange: (requests: TrackedRequest[]) => void;
  private readonly onterminal: (terminal: TerminalInfo) => void;
  private readonly pollInterval: number;
  private readonly sleep: (ms: number, signal: AbortSignal) => Promise<void>;
  private readonly controller = new AbortController();
  private readonly requests = new Map<string, TrackedRequest>();
  private readonly polling = new Set<string>();
  private readonly attached = new Set<string>();

  constructor(options: TerminalRequestsOptions) {
    this.sessionId = options.sessionId;
    this.capabilities = options.capabilities ?? null;
    this.api = options.api ?? terminalRequestApi;
    this.onchange = options.onchange ?? (() => {});
    this.onterminal = options.onterminal ?? (() => {});
    this.pollInterval = options.pollInterval ?? POLL_INTERVAL_MS;
    this.sleep = options.sleep ?? defaultSleep;
  }

  get list(): TrackedRequest[] {
    return [...this.requests.values()];
  }
  get(requestId: string, kind: RequestKind = 'work'): TrackedRequest | undefined {
    return this.find(kind, requestId);
  }
  /** Stops polling; in-flight POSTs still finish on the Node and are rediscovered later. */
  dispose() {
    this.controller.abort();
  }
  private get disposed() {
    return this.controller.signal.aborted;
  }

  private key(kind: RequestKind, requestId: string) {
    return `${kind}:${requestId}`;
  }
  private set(request: TrackedRequest) {
    if (this.disposed) return;
    this.requests.set(this.key(request.kind, request.requestId), request);
    this.onchange(this.list);
  }
  private find(kind: RequestKind, requestId: string) {
    return this.requests.get(this.key(kind, requestId));
  }

  /** Records a Node result; attaches a live terminal and polls `preparing`. */
  private apply(
    base: TrackedRequest,
    result: TerminalRequestResult,
    extra: Partial<TrackedRequest> = {},
  ) {
    const phase = phaseOf(result);
    const next: TrackedRequest = { ...base, ...extra, phase, result, stalled: false };
    if (!extra.error) delete next.error;
    if (!extra.conflict) delete next.conflict;
    if (acknowledged(result)) {
      // The user's retained decision: no longer pending. Nothing claims it closed.
      if (!this.disposed && this.requests.delete(this.key(next.kind, next.requestId)))
        this.onchange(this.list);
      return next;
    }
    this.set(next);
    if (phase === 'live' && result.terminal && !this.attached.has(result.terminal.id)) {
      this.attached.add(result.terminal.id);
      if (!this.disposed) this.onterminal(result.terminal);
    }
    if (phase === 'preparing') void this.poll(next.kind, next.requestId);
    return next;
  }

  private read(kind: RequestKind, requestId: string) {
    const signal = this.controller.signal;
    return kind === 'work'
      ? this.api.workResult(this.sessionId, requestId, signal)
      : this.api.hostResult(this.sessionId, requestId, signal);
  }

  /** Resolves a request whose POST outcome is not known, by GET only. */
  private async resolve(base: TrackedRequest, extra: Partial<TrackedRequest> = {}) {
    this.set({ ...base, ...extra, phase: 'checking' });
    try {
      this.apply(base, await this.read(base.kind, base.requestId), extra);
    } catch (error) {
      if (isAbort(error)) return;
      const failure = classifyFailure(error);
      this.set({
        ...base,
        ...extra,
        phase: failure === 'not_found' ? 'not_admitted' : 'unknown_delivery',
        error: extra.error ?? errorOf(error),
      });
    }
  }

  /** One reader per request: GET until it leaves `preparing`. Never POSTs. */
  private async poll(kind: RequestKind, requestId: string) {
    const key = this.key(kind, requestId);
    if (this.polling.has(key)) return;
    this.polling.add(key);
    try {
      for (;;) {
        await this.sleep(this.pollInterval, this.controller.signal);
        const current = this.find(kind, requestId);
        if (this.disposed || current?.phase !== 'preparing' || current.stalled) return;
        let result: TerminalRequestResult;
        try {
          result = await this.read(kind, requestId);
        } catch (error) {
          if (isAbort(error)) return;
          // Stop reading an unreachable Node; the user resumes with refresh.
          this.set({ ...current, stalled: true, error: errorOf(error) });
          return;
        }
        // Still this loop's key, so `apply` does not start a second reader.
        if (this.apply(current, result).phase !== 'preparing') return;
      }
    } catch (error) {
      if (!isAbort(error)) throw error;
    } finally {
      this.polling.delete(key);
    }
  }

  /**
   * POSTs once. An ambiguous outcome is resolved by GET; a `409` reads the ID's
   * retained result (reading is not a retry). `exists`: the request is already
   * known to the Node (confirm), so any refusal reads its current result.
   */
  private async send(
    base: TrackedRequest,
    submit: () => Promise<{ status: number; body: TerminalRequestResult }>,
    exists = false,
  ) {
    this.set({ ...base, phase: 'submitting' });
    try {
      const { body } = await submit();
      this.apply(base, body);
    } catch (error) {
      const failure = classifyFailure(error);
      if (failure === 'ambiguous') return this.resolve(base);
      if (failure === 'conflict' || failure === 'review_required' || exists)
        return this.resolve(base, { conflict: failure === 'conflict', error: errorOf(error) });
      this.set({ ...base, phase: 'rejected', error: errorOf(error) });
    }
  }

  /** The ordinary New terminal action: one new ID per call. */
  async openWork(intent: TerminalIntent): Promise<TrackedRequest> {
    const base: TrackedRequest = {
      kind: 'work',
      requestId: newRequestId(),
      intent: { ...intent },
      phase: 'submitting',
    };
    await this.send(base, () => this.api.submitWork(base.intent!, base.requestId));
    return this.find('work', base.requestId) ?? base;
  }

  /** The explicit host-management action: a new review with a new ID. */
  async reviewHost(intent: TerminalIntent): Promise<TrackedRequest> {
    const base: TrackedRequest = {
      kind: 'host',
      requestId: newRequestId(),
      intent: { ...intent },
      phase: 'submitting',
    };
    await this.send(base, () => this.api.reviewHost(base.intent!, base.requestId));
    return this.find('host', base.requestId) ?? base;
  }

  /** Confirms a pending review with its exact `reviewId`/`reviewHash` and reviewed size. */
  async confirmHost(requestId: string, current: TerminalIntent): Promise<boolean> {
    const request = this.find('host', requestId);
    if (!request || !canConfirm(request, current) || current.sessionId !== this.sessionId)
      return false;
    const review = (request.result as { hostManagement: HostManagementResult }).hostManagement;
    const intent = confirmIntent(review, current);
    await this.send(
      { ...request, intent: request.intent ?? intent },
      () => this.api.confirmHost(intent, review),
      true,
    );
    return true;
  }

  /** Re-sends a `404` request under the same ID, only with the same intent. */
  async resubmit(requestId: string, current: TerminalIntent, kind: RequestKind = 'work') {
    const request = this.find(kind, requestId);
    if (!request || request.phase !== 'not_admitted' || !sameIntent(request.intent, current))
      return false;
    const intent = request.intent!;
    await this.send(request, () =>
      kind === 'work'
        ? this.api.submitWork(intent, requestId)
        : this.api.reviewHost(intent, requestId),
    );
    return true;
  }

  /** Reads a request again (GET only); resumes polling while it prepares. */
  async refresh(requestId: string, kind: RequestKind = 'work') {
    const request = this.find(kind, requestId);
    if (!request) return;
    if (request.phase === 'unknown_delivery') return this.resolve(request);
    try {
      this.apply(request, await this.read(kind, requestId));
    } catch (error) {
      if (isAbort(error)) return;
      if (classifyFailure(error) === 'not_found' && !request.result)
        return this.set({ ...request, phase: 'not_admitted', error: errorOf(error) });
      this.set({ ...request, stalled: true, error: errorOf(error) });
    }
  }

  /**
   * v3: acknowledges an `outcome_unknown` request under the current lease. On
   * success it leaves this list (as it leaves discovery); its state stays
   * `outcome_unknown`. A `409 terminal_request_not_unknown` or an ambiguous
   * reply reads the result again. Returns whether it was sent.
   */
  async acknowledge(requestId: string, current: TerminalIntent, kind: RequestKind = 'work') {
    const request = this.find(kind, requestId);
    if (
      !request ||
      !acknowledgeable(request) ||
      !canAcknowledge(this.capabilities) ||
      current.sessionId !== this.sessionId
    )
      return false;
    this.set({ ...request, phase: 'submitting' });
    try {
      this.apply(request, (await this.api.acknowledge(current, kind, requestId)).body);
    } catch (error) {
      const failure = classifyFailure(error);
      if (failure !== 'ambiguous' && failure !== 'not_unknown') {
        this.set({ ...request, error: errorOf(error) });
        return true;
      }
      try {
        this.apply(request, await this.read(kind, requestId), {
          error: failure === 'not_unknown' ? errorOf(error) : undefined,
        });
      } catch (readError) {
        if (!isAbort(readError)) this.set({ ...request, error: errorOf(readError) });
      }
    }
    return true;
  }

  dismiss(requestId: string, kind: RequestKind = 'work') {
    if (this.requests.delete(this.key(kind, requestId))) this.onchange(this.list);
  }

  /**
   * After a load, reload or reconnect: discovers this owner's unresolved
   * requests (`preparing`, `review`, `outcome_unknown`) through every page.
   */
  async recover(options: { limit?: number } = {}): Promise<void> {
    const items = await this.api.unresolved(this.sessionId, options, this.controller.signal);
    for (const result of items) {
      const record = recordOf(result);
      const kind = kindOf(result);
      const known = this.find(kind, record.requestId);
      this.apply(known ?? { kind, requestId: record.requestId, phase: 'checking' }, result);
    }
  }
}
