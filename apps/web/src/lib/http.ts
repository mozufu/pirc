import { writable } from 'svelte/store';
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

/**
 * Header every state-changing request carries (any method but GET, HEAD and
 * OPTIONS). The gateway accepts such a request only with this header or with a
 * JSON body, which a plain HTML form cannot produce.
 */
export const REQUEST_HEADER = 'x-pirc-request';
export const REQUEST_VALUE = '1';

/** The error code of a request the gateway refuses because of how it was made. */
export const REQUEST_SHAPE_CODE = 'request_shape_required';

/**
 * True once the gateway refused a request with {@link REQUEST_SHAPE_CODE}: this
 * page was built before the rule and cannot work with the gateway until it is
 * reloaded (the shell is then replaced). The app shows a reload prompt.
 */
export const clientOutdated = writable(false);

const isStateChanging = (method: string | undefined): boolean =>
  !['GET', 'HEAD', 'OPTIONS'].includes((method ?? 'GET').toUpperCase());

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
  if (isStateChanging(init.method)) headers.set(REQUEST_HEADER, REQUEST_VALUE);
  const response = await fetch(path, { ...init, headers, credentials: 'include' });
  if (!response.ok) {
    const body = await response.json().catch(() => null);
    const code = body?.error?.code ?? body?.code;
    if (response.status === 415 && code === REQUEST_SHAPE_CODE) clientOutdated.set(true);
    throw new ApiError(
      (options.errorMessage ?? defaultMessage)(body, response.status),
      response.status,
      code,
    );
  }
  if (response.status === 204) return { status: 204, body: undefined as T };
  return { status: response.status, body: (await response.json()) as T };
}

/** True for the rejection of an aborted request. */
export const isAbort = (error: unknown): boolean =>
  error instanceof DOMException && error.name === 'AbortError';
