import { tr } from './i18n.svelte';
/** JSON-over-fetch shared by the gateway clients (`api.ts`, `panel-api.ts`). */

export class ApiError extends Error {
  constructor(
    message: string,
    readonly status: number,
    readonly code = 'unknown_error',
  ) {
    super(message);
    this.name = 'ApiError';
  }
}

export interface RequestOptions {
  /**
   * Map the gateway's error message to the one shown to the user (e.g. to hide
   * anything that looks like a credential). Gets the parsed error body, if any.
   */
  errorMessage?: (body: any, status: number) => string;
}

const defaultMessage = (body: any, status: number): string =>
  body?.error?.message ?? body?.message ?? tr('Request failed ({0})', [status]);

/**
 * Fetch `path` with the session cookie and parse the JSON reply. Non-2xx
 * replies throw an {@link ApiError}; an aborted `init.signal` rejects with the
 * fetch `AbortError`.
 */
export async function request<T>(
  path: string,
  init: RequestInit = {},
  options: RequestOptions = {},
): Promise<T> {
  return (await requestWithStatus<T>(path, init, options)).body;
}

/** {@link request}, keeping the success status (e.g. to tell `201` from `202`). */
export async function requestWithStatus<T>(
  path: string,
  init: RequestInit = {},
  options: RequestOptions = {},
): Promise<{ status: number; body: T }> {
  const headers = new Headers(init.headers);
  if (
    init.body &&
    !(init.body instanceof FormData) &&
    !(init.body instanceof Blob) &&
    !headers.has('content-type')
  )
    headers.set('content-type', 'application/json');
  headers.set('accept', 'application/json');
  const response = await fetch(path, { ...init, headers, credentials: 'include' });
  if (!response.ok) {
    const body = await response.json().catch(() => null);
    throw new ApiError(
      (options.errorMessage ?? defaultMessage)(body, response.status),
      response.status,
      body?.error?.code ?? body?.code,
    );
  }
  if (response.status === 204) return { status: 204, body: undefined as T };
  return { status: response.status, body: (await response.json()) as T };
}

/** True for the rejection of an aborted request. */
export const isAbort = (error: unknown): boolean =>
  error instanceof DOMException && error.name === 'AbortError';
