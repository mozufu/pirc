// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from 'vitest';
import { REQUEST_HEADER, REQUEST_VALUE, request, requestWithStatus } from './http';

afterEach(() => vi.unstubAllGlobals());

function stub() {
  const fetch = vi.fn(
    async (_path: string, _init: RequestInit) => new Response('{}', { status: 200 }),
  );
  vi.stubGlobal('fetch', fetch);
  return fetch;
}

const sent = (fetch: ReturnType<typeof stub>) => {
  const init = fetch.mock.calls[fetch.mock.calls.length - 1]![1];
  return { headers: new Headers(init.headers), init };
};

describe('state-changing requests', () => {
  it.each(['POST', 'PUT', 'PATCH', 'DELETE', 'post', 'delete'])(
    'send the request header with %s',
    async (method) => {
      const fetch = stub();
      await request('/api/x', { method });
      expect(sent(fetch).headers.get(REQUEST_HEADER)).toBe(REQUEST_VALUE);
    },
  );

  it('keeps JSON for bodies and sends the header with it', async () => {
    const fetch = stub();
    await request('/api/x', { method: 'POST', body: JSON.stringify({ a: 1 }) });
    const { headers } = sent(fetch);
    expect(headers.get('content-type')).toBe('application/json');
    expect(headers.get(REQUEST_HEADER)).toBe('1');
  });

  it('sends the header with uploads of raw bytes and with empty bodies', async () => {
    const fetch = stub();
    await request('/api/sessions/s1/uploads', {
      method: 'POST',
      headers: { 'content-type': 'application/octet-stream' },
      body: new Blob(['bytes']),
    });
    expect(sent(fetch).headers.get(REQUEST_HEADER)).toBe('1');
    expect(sent(fetch).headers.get('content-type')).toBe('application/octet-stream');
    await requestWithStatus('/api/sessions/s1/read', { method: 'POST' });
    expect(sent(fetch).headers.get(REQUEST_HEADER)).toBe('1');
    expect(sent(fetch).init.body).toBeUndefined();
  });

  it('cannot be asked to leave the header out', async () => {
    const fetch = stub();
    await request('/api/x', { method: 'POST', headers: { [REQUEST_HEADER]: '0' } });
    expect(sent(fetch).headers.get(REQUEST_HEADER)).toBe('1');
  });

  it('leaves reads alone', async () => {
    const fetch = stub();
    await request('/api/x');
    await request('/api/x', { method: 'GET' });
    for (const call of fetch.mock.calls)
      expect(new Headers(call[1].headers).has(REQUEST_HEADER)).toBe(false);
  });
});

describe('the one place requests are made', () => {
  const sources = import.meta.glob(['./**/*.svelte', './**/*.ts', '../*.svelte', '../*.ts'], {
    query: '?raw',
    import: 'default',
    eager: true,
  }) as Record<string, string>;
  const code = Object.entries(sources).filter(([path]) => !/\.test\.ts$/.test(path));

  it('is http.ts: nothing else calls fetch, XHR or sendBeacon', () => {
    const offenders = code
      .filter(
        ([path, text]) =>
          path !== './http.ts' && /\bfetch\s*\(|XMLHttpRequest|sendBeacon/.test(text),
      )
      .map(([path]) => path);
    expect(offenders).toEqual([]);
  });

  it('is http.ts: no component submits a form natively to the network', () => {
    const offenders = code
      .filter(([, text]) => /<form[^>]*\saction=|\.submit\(\)|requestSubmit\(/.test(text))
      .map(([path]) => path);
    expect(offenders).toEqual([]);
  });
});
