/** Client for the side-panel endpoints (files, Git, memory, background, terminals). */
import { request } from './http';
import { getClientId } from './storage';

export type PanelTab = 'files' | 'git' | 'memory' | 'context' | 'tasks' | 'terminal' | 'browser';

export interface CheckpointVersion {
  kind: 'file' | 'absent' | 'excluded';
  hash?: string;
  size?: number;
  executable?: boolean;
  reason?: string;
}

export interface CheckpointOperation {
  id: string;
  path: string;
  state: string;
  before: CheckpointVersion;
  after?: CheckpointVersion;
}

export interface CheckpointCapture {
  id: string;
  state: string;
  coverage: string;
  gaps: boolean | string[];
  pinned: boolean;
  created?: number | string;
  createdAt?: number | string;
  run?: string | { id?: string; status?: string } | null;
  operations: CheckpointOperation[];
  operationsTruncated?: boolean;
}

export interface CheckpointPathReview {
  path: string;
  status: 'inverse_reviewed_observation' | 'review_observational' | 'conflict' | 'excluded';
  before: CheckpointVersion;
  after: CheckpointVersion;
  current: CheckpointVersion;
  candidate: CheckpointVersion;
}

export interface CheckpointRecoveryJob {
  id: string;
  state: 'preparing' | 'ready' | 'opened' | 'stale' | 'failed' | 'interrupted' | string;
  revision: number;
  reservedBytes: number;
  captureId: string;
  operations: string[];
  manifest: {
    paths: CheckpointPathReview[];
    exclusions: Record<string, string>;
    copiedBytes: number;
    coverage: string;
  };
  continuation?: { sessionId: string; workspaceId: string };
}

export interface CheckpointList {
  version: 1;
  enabled: boolean;
  origin?: {
    sessionId: string;
    workspaceId: string;
    jobId: string;
    captureId: string;
  } | null;
  captures: CheckpointCapture[];
  jobs: CheckpointRecoveryJob[];
  more: boolean;
  cursor?: string;
}

export interface CheckpointPreview {
  version: 1;
  revision: string;
  copiedBytes: number;
  exclusions: Record<string, string>;
  coverage: string;
}

export interface CheckpointFileView {
  path: string;
  side: 'before' | 'after' | 'current' | 'candidate';
  text: string | null;
  binary: boolean;
  absent: boolean;
  excluded: boolean;
  truncated: boolean;
  executable?: boolean;
}

export interface ContextPanel {
  agentRunning: boolean;
  source: 'live' | 'snapshot';
  snapshot: {
    version: 1;
    id: string;
    takenAt: number;
    model: { provider: string; id: string; contextWindow?: number };
    sections: Array<{
      id: string;
      title: string;
      source: string;
      text: string;
      frozen?: boolean;
      filePath?: string;
      estimatedTokens: number;
    }>;
    /** What the provider sees: `ptc`, `ptc_docs` and the direct core capabilities. */
    tools: Array<{
      name: string;
      description: string;
      parameters: Record<string, unknown>;
      estimatedTokens: number;
    }>;
    /** Capabilities `ptc` scripts may call; no schemas, they are not in the context. */
    capabilities?: Array<{
      name: string;
      category: string;
      uiLabel: string;
      effects: string[];
      approval: string;
    }>;
    usage: {
      estimatedInput: number;
      reportedInput?: number;
      scale: number;
      remaining: number | null;
      buckets: { system: number; tools: number; messages: number; memory: number };
    };
  };
}

const base = (sessionId: string) => `/api/sessions/${encodeURIComponent(sessionId)}`;
const qs = (params: Record<string, string | number | boolean | undefined>) => {
  const query = new URLSearchParams();
  for (const [key, value] of Object.entries(params))
    if (value !== undefined && value !== false && value !== '')
      query.set(key, value === true ? '1' : String(value));
  const text = query.toString();
  return text ? `?${text}` : '';
};

export interface GitFile {
  path: string;
  origPath?: string;
  index: string;
  worktree: string;
}
export type GitStatus =
  | { repo: false }
  | {
      repo: true;
      root: string;
      branch: string | null;
      upstream: string | null;
      ahead: number;
      behind: number;
      files: GitFile[];
      truncated: boolean;
    };
export interface Commit {
  sha: string;
  short: string;
  author: string;
  email: string;
  time: number;
  refs: string[];
  subject: string;
}
export interface CommitDetail {
  sha: string;
  author: string;
  email: string;
  time: number;
  refs: string[];
  message: string;
  diff: string;
  truncated: boolean;
}
export interface DirEntry {
  name: string;
  kind: 'dir' | 'file' | 'symlink' | 'other';
  size?: number;
}
export interface FileContent {
  path: string;
  size: number;
  modifiedAt: number;
  binary: boolean;
  truncated: boolean;
  content?: string;
  /** The whole file, for images (by extension) up to the node's inline limit. */
  image?: { mimeType: string; dataBase64: string };
  /** An image over that limit: not previewed. */
  imageTooLarge?: boolean;
}
export interface Meter {
  value: number;
  max: number;
}
export type Relevance = 'low' | 'medium' | 'high' | 'critical';
export interface MemoryPanel {
  architecture?: 'handoff';
  handoff?: {
    snapshots: number;
    latest: string | null;
    legacyAncestry: string | null;
    textOnly: boolean;
  };
  enabled: boolean;
  passive: boolean;
  thresholds: {
    observation: Meter;
    reflection: Meter;
    compaction: Meter;
    visiblePool: Meter;
    activePool: Meter;
  };
  counts: {
    observations: number;
    active: number;
    dropped: number;
    visibleObservations: number;
    reflections: number;
    visibleReflections: number;
    compactions: number;
  };
  observations: Array<{
    id: string;
    content: string;
    timestamp: string;
    relevance: Relevance;
    tokenCount: number;
    dropped: boolean;
    visible: boolean;
  }>;
  reflections: Array<{
    id: string;
    content: string;
    supportingObservationIds: string[];
    tokenCount: number;
    visible: boolean;
  }>;
  lastCompactionAt?: number;
}
export interface MemoryRuntime {
  phase: string | null;
  autoCompacting: boolean;
  rateLimited: Array<{ model: string; until: number }>;
  lastErrors: Record<string, string>;
}
export interface BackgroundTask {
  id: string;
  command: string;
  cwd: string;
  status: 'running' | 'stopping' | 'completed' | 'failed' | 'stopped' | 'timed_out';
  pid?: number;
  exitCode?: number | null;
  signal?: string | null;
  tty?: boolean;
  notifyOn?: string;
  matches?: number;
  startedAt: string;
  endedAt?: string;
  error?: string;
}
export interface TeamMember {
  name: string;
  kind?: string;
  mode?: 'team' | 'subagent';
  background?: boolean;
  tools?: string[];
  status?: string;
  cwd?: string;
  model?: string;
  thinking?: string;
  lastError?: string;
  task?: string;
  pid?: number;
  startedAt?: number | string;
  lastActivity?: number | string;
  activity?: unknown;
}
export interface TeamTask {
  id: string;
  subject: string;
  description: string;
  status: 'pending' | 'in_progress' | 'completed';
  owner?: string;
  blockedBy: string[];
  blocked: boolean;
  ready: boolean;
  revision: number;
}
export interface PanelState {
  agentRunning: boolean;
  memory: MemoryPanel | null;
  memoryRuntime: MemoryRuntime | null;
  workspaceMemory?: {
    writeState?: 'unknown' | 'disabled' | 'cutover_required' | 'active';
    errors: Record<string, string>;
    pendingMutations: number;
    extracting: boolean;
  } | null;
  backgroundTasks: BackgroundTask[];
  team: {
    agents: TeamMember[];
    tasks?: TeamTask[];
    events?: Array<{
      id: string;
      time: string;
      kind: string;
      from?: string;
      to?: string;
      name?: string;
      body?: string;
    }>;
  };
}
export interface TerminalInfo {
  id: string;
  /** Set by Nodes with the execution-path contract; untagged legacy terminals omit it. */
  executionPath?: 'isolated_work' | 'host_management' | string;
  sessionId: string;
  title: string;
  cwd: string;
  cols: number;
  rows: number;
  createdAt: number;
  exitCode: number | null;
  exited: boolean;
}

/** The session's browser as the node reports it (node/browser.ts). */
export interface BrowserViewState {
  active: boolean;
  url: string;
  title: string;
  mode: 'agent' | 'user';
  handoff: string | null;
  agentWaiting: boolean;
  action: string | null;
  recording: { path: string; startedAt: number } | null;
  tabs: Array<{ index: number; url: string; title: string; active: boolean }>;
  viewport: { width: number; height: number };
}
export interface BrowserLogEntry {
  index: number;
  at: number;
  actor: 'agent' | 'user';
  action: string;
  url: string;
  image: boolean;
}
export type BrowserFrame =
  | { type: 'state'; state: BrowserViewState }
  | { type: 'frame'; data: string; width: number; height: number }
  | { type: 'log'; entries: BrowserLogEntry[] }
  | { type: 'log_entry'; entry: BrowserLogEntry }
  | { type: 'log_image'; index: number; data: string | null }
  | { type: 'error'; code: string; message: string };

/** `Saved recording <path>` log entries name the file. */
export const RECORDING_LOG = /^Saved recording (\.pirc\/recordings\/\S+\.webm)$/;

/** Read endpoints take an optional signal so a superseded load can be aborted. */
const get = <T>(path: string, signal?: AbortSignal) => request<T>(path, { signal });

export const panelApi = {
  context: (sessionId: string, signal?: AbortSignal) =>
    get<ContextPanel>(`${base(sessionId)}/panel/context`, signal),
  gitStatus: (sessionId: string, signal?: AbortSignal) =>
    get<GitStatus>(`${base(sessionId)}/git/status`, signal),
  gitDiff: (
    sessionId: string,
    options: { path?: string; staged?: boolean; untracked?: boolean },
    signal?: AbortSignal,
  ) =>
    get<{ diff: string; truncated: boolean }>(`${base(sessionId)}/git/diff${qs(options)}`, signal),
  gitLog: (sessionId: string, skip = 0, limit = 50, signal?: AbortSignal) =>
    get<{ commits: Commit[]; more: boolean }>(
      `${base(sessionId)}/git/log${qs({ skip, limit })}`,
      signal,
    ),
  gitShow: (sessionId: string, sha: string, signal?: AbortSignal) =>
    get<CommitDetail>(`${base(sessionId)}/git/commits/${encodeURIComponent(sha)}`, signal),
  checkpoints: (sessionId: string, cursor?: string, signal?: AbortSignal) =>
    get<CheckpointList>(`${base(sessionId)}/checkpoints${qs({ cursor })}`, signal),
  checkpointPreview: (
    sessionId: string,
    captureId: string,
    selection: { operations: string[]; reviewObservational: boolean },
    signal?: AbortSignal,
  ) =>
    request<CheckpointPreview>(
      `${base(sessionId)}/checkpoints/${encodeURIComponent(captureId)}/preview`,
      { method: 'POST', body: JSON.stringify(selection), signal },
    ),
  prepareCheckpointRecovery: (
    sessionId: string,
    captureId: string,
    input: {
      version: 1;
      key: string;
      previewRevision: string;
      operations: string[];
      reviewObservational: boolean;
      clientId: string;
      generation: number;
    },
    signal?: AbortSignal,
  ) =>
    request<CheckpointRecoveryJob>(
      `${base(sessionId)}/checkpoints/${encodeURIComponent(captureId)}/recoveries`,
      { method: 'POST', body: JSON.stringify(input), signal },
    ),
  checkpointRecovery: (sessionId: string, captureId: string, jobId: string, signal?: AbortSignal) =>
    get<CheckpointRecoveryJob>(
      `${base(sessionId)}/checkpoints/${encodeURIComponent(captureId)}/recoveries/${encodeURIComponent(jobId)}`,
      signal,
    ),
  continueCheckpointRecovery: (
    sessionId: string,
    captureId: string,
    jobId: string,
    input: {
      revision: number;
      acceptUnresolved: boolean;
      clientId: string;
      generation: number;
    },
    signal?: AbortSignal,
  ) =>
    request<{
      session: { id: string };
      workspaceId: string;
      job: CheckpointRecoveryJob;
    }>(
      `${base(sessionId)}/checkpoints/${encodeURIComponent(captureId)}/recoveries/${encodeURIComponent(jobId)}/continue`,
      { method: 'POST', body: JSON.stringify(input), signal },
    ),
  checkpointFile: (
    sessionId: string,
    captureId: string,
    operationId: string,
    side: CheckpointFileView['side'],
    jobId?: string,
    signal?: AbortSignal,
  ) =>
    get<CheckpointFileView>(
      `${base(sessionId)}/checkpoints/${encodeURIComponent(captureId)}/file${qs({ operation: operationId, side, job: jobId })}`,
      signal,
    ),
  files: (sessionId: string, path = '', signal?: AbortSignal) =>
    get<{ path: string; entries: DirEntry[]; truncated: boolean }>(
      `${base(sessionId)}/files${qs({ path })}`,
      signal,
    ),
  file: (sessionId: string, path: string, signal?: AbortSignal) =>
    get<FileContent>(`${base(sessionId)}/files/content${qs({ path })}`, signal),
  state: (sessionId: string, signal?: AbortSignal) =>
    get<PanelState>(`${base(sessionId)}/panel/state`, signal),
  backgroundOutput: (sessionId: string, taskId: string, lines = 400, signal?: AbortSignal) =>
    get<{ task: BackgroundTask; output: string }>(
      `${base(sessionId)}/panel/background/${encodeURIComponent(taskId)}${qs({ lines })}`,
      signal,
    ),
  /** Needs the control lease; resolves once the stop is requested (status `stopping`). */
  stopBackground: (sessionId: string, taskId: string, generation: number) =>
    request<{ task: BackgroundTask }>(
      `${base(sessionId)}/panel/background/${encodeURIComponent(taskId)}/stop`,
      { method: 'POST', body: JSON.stringify({ clientId: getClientId(), generation }) },
    ),
  terminals: (sessionId: string, signal?: AbortSignal) =>
    get<{ terminals: TerminalInfo[] }>(`${base(sessionId)}/terminals`, signal),
  closeTerminal: (sessionId: string, terminalId: string, generation: number) =>
    request<void>(`${base(sessionId)}/terminals/${encodeURIComponent(terminalId)}/close`, {
      method: 'POST',
      body: JSON.stringify({ clientId: getClientId(), generation }),
    }),
  browserUrl: (sessionId: string) => {
    const protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
    return `${protocol}//${location.host}${base(sessionId)}/browser/stream`;
  },
  /** A browser recording (`.pirc/recordings/*.webm`), playable with seeking. */
  recordingUrl: (sessionId: string, path: string) =>
    `${base(sessionId)}/browser/recording${qs({ path })}`,
  terminalUrl: (sessionId: string, terminalId: string) => {
    const protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
    return `${protocol}//${location.host}${base(sessionId)}/terminals/${encodeURIComponent(terminalId)}/stream`;
  },
};
