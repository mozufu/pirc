/**
 * Replaced when the app is built (see sw-build-id.ts), so that every build has a
 * service worker file that differs from the last: open pages then see an update
 * and offer it. The shell cache below is rewritten from the network on each visit.
 */
const BUILD_ID = '__PIRC_BUILD_ID__';
const CACHE_VERSION = 'relay-static-v1';
/** The last app shell (index.html) served by the network, for starting offline. */
const SHELL_CACHE = 'relay-shell-v1';
/** Exact interaction revocations survive worker restarts and may arrive before creation pushes. */
const RESOLVED_INTERACTION_CACHE = 'relay-interaction-resolved-v1';
const RESOLVED_INTERACTION_TTL = 48 * 60 * 60 * 1000;
const RESOLVED_INTERACTION_LIMIT = 500;
/** Serialize create/revoke handling for each exact question within this worker. */
const interactionPushChains = new Map();
const SHELL_KEY = '/';
const VERSIONED_ASSET = /^\/assets\/[\w.-]*-[A-Za-z0-9_-]{8,}\.(?:js|css|woff2?|png|svg|webp)$/;

/**
 * Only a real page is kept: not a login redirect or error page from the
 * authenticating proxy in front of the gateway.
 */
const cacheableShell = (response) =>
  response.ok &&
  response.type === 'basic' &&
  !response.redirected &&
  (response.headers.get('content-type') ?? '').includes('text/html');

self.addEventListener('install', (event) => {
  // Seed the shell so the app can start offline after its first visit. A
  // failure (offline, signed out) must not block installing the worker.
  event.waitUntil(
    fetch(new Request(SHELL_KEY, { cache: 'no-store' }))
      .then(async (response) => {
        if (cacheableShell(response))
          await (await caches.open(SHELL_CACHE)).put(SHELL_KEY, response);
      })
      .catch(() => undefined),
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) =>
        Promise.all(
          keys
            .filter(
              (key) =>
                (key.startsWith('relay-static-') && key !== CACHE_VERSION) ||
                (key.startsWith('relay-shell-') && key !== SHELL_CACHE),
            )
            .map((key) => caches.delete(key)),
        ),
      ),
  );
});

self.addEventListener('message', (event) => {
  if (event.data?.type === 'ACTIVATE_UPDATE') self.skipWaiting();
});

/**
 * Pages: network first, so an online start always gets the current build and
 * the proxy can still redirect to its login. Only when the network fails is
 * the last good shell served; its hashed assets are in the static cache from
 * that visit.
 */
async function navigate(event) {
  try {
    const response = await fetch(event.request);
    if (cacheableShell(response)) {
      const copy = response.clone();
      event.waitUntil(caches.open(SHELL_CACHE).then((cache) => cache.put(SHELL_KEY, copy)));
    }
    return response;
  } catch (error) {
    const cached = await caches.match(SHELL_KEY, { cacheName: SHELL_CACHE });
    if (cached) return cached;
    throw error;
  }
}

self.addEventListener('fetch', (event) => {
  const url = new URL(event.request.url);
  if (event.request.method !== 'GET' || url.origin !== self.location.origin) return;

  if (event.request.mode === 'navigate') {
    // API data is never cached.
    if (!url.pathname.startsWith('/api/')) event.respondWith(navigate(event));
    return;
  }
  if (!VERSIONED_ASSET.test(url.pathname)) return;

  event.respondWith(
    caches.open(CACHE_VERSION).then(async (cache) => {
      const cached = await cache.match(event.request);
      if (cached) return cached;
      const response = await fetch(event.request);
      if (response.ok && response.type === 'basic')
        await cache.put(event.request, response.clone());
      return response;
    }),
  );
});

/** The page a notification opens (see targetFromUrl in src/lib/push.ts). */
function targetUrl(target, interaction) {
  if (target?.sessionId) {
    const url = new URL('/', self.location.origin);
    url.searchParams.set('session', target.sessionId);
    if (interaction?.sessionId === target.sessionId) {
      url.searchParams.set('interactionId', interaction.interactionId);
      url.searchParams.set('interactionEpoch', interaction.interactionEpoch);
    }
    return url.pathname + url.search;
  }
  if (target?.schedules)
    return target.scheduleId
      ? `/?open=schedules&schedule=${encodeURIComponent(target.scheduleId)}`
      : '/?open=schedules';
  if (target?.calendar) {
    const url = new URL('/', self.location.origin);
    url.searchParams.set('open', 'calendar');
    if (typeof target.eventId === 'string' && target.eventId.length <= 100)
      url.searchParams.set('event', target.eventId);
    if (
      typeof target.occurrenceStart === 'string' &&
      /^\d{4}-\d{2}-\d{2}(?:T\d{2}:\d{2})?$/.test(target.occurrenceStart)
    )
      url.searchParams.set('occurrence', target.occurrenceStart);
    if (typeof target.date === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(target.date))
      url.searchParams.set('date', target.date);
    if (Number.isSafeInteger(target.startAt) && Math.abs(target.startAt) <= 8_640_000_000_000_000)
      url.searchParams.set('startAt', String(target.startAt));
    return url.pathname + url.search;
  }
  if (target?.memory) return '/?open=memory';
  return '/';
}

function interactionIdentity(message) {
  if (
    !message ||
    typeof message.sessionId !== 'string' ||
    !message.sessionId ||
    message.sessionId.length > 512 ||
    typeof message.interactionId !== 'string' ||
    !message.interactionId ||
    message.interactionId.length > 512
  )
    return undefined;
  const epoch = message.interactionEpoch;
  const canonicalEpoch =
    typeof epoch === 'number' && Number.isSafeInteger(epoch) && epoch >= 0
      ? String(epoch)
      : typeof epoch === 'string' && /^(0|[1-9]\d{0,19})$/.test(epoch)
        ? epoch
        : undefined;
  if (canonicalEpoch === undefined) return undefined;
  return {
    sessionId: message.sessionId,
    interactionId: message.interactionId,
    interactionEpoch: canonicalEpoch,
  };
}

function hexUtf8(text) {
  return Array.from(new TextEncoder().encode(text), (byte) =>
    byte.toString(16).padStart(2, '0'),
  ).join('');
}

function interactionTag(identity) {
  return `interaction:${hexUtf8(identity.sessionId)}:${identity.interactionEpoch}:${hexUtf8(identity.interactionId)}`;
}

function interactionKey(identity) {
  const tuple = `${hexUtf8(identity.sessionId)}:${identity.interactionEpoch}:${hexUtf8(identity.interactionId)}`;
  return new URL(`/__pirc_interaction_resolved__/${tuple}`, self.location.origin).href;
}

async function interactionWasResolved(identity) {
  const cache = await caches.open(RESOLVED_INTERACTION_CACHE);
  const key = interactionKey(identity);
  const response = await cache.match(key);
  if (!response) return false;
  const record = await response.json().catch(() => null);
  if (!Number.isFinite(record?.at) || Date.now() - record.at > RESOLVED_INTERACTION_TTL) {
    await cache.delete(key);
    return false;
  }
  return true;
}

async function rememberResolvedInteraction(identity) {
  const cache = await caches.open(RESOLVED_INTERACTION_CACHE);
  await cache.put(
    interactionKey(identity),
    new Response(JSON.stringify({ at: Date.now() }), {
      headers: { 'content-type': 'application/json' },
    }),
  );
  const keys = await cache.keys();
  const records = await Promise.all(
    keys.map(async (key) => {
      const response = await cache.match(key);
      const record = await response?.json().catch(() => null);
      return { key, at: Number.isFinite(record?.at) ? record.at : 0 };
    }),
  );
  const now = Date.now();
  const expired = records.filter((record) => now - record.at > RESOLVED_INTERACTION_TTL);
  await Promise.all(expired.map(({ key }) => cache.delete(key)));
  const live = records.filter((record) => !expired.includes(record)).sort((a, b) => b.at - a.at);
  await Promise.all(live.slice(RESOLVED_INTERACTION_LIMIT).map(({ key }) => cache.delete(key)));
}

function sameInteraction(a, b) {
  return (
    a?.sessionId === b.sessionId &&
    a?.interactionId === b.interactionId &&
    a?.interactionEpoch === b.interactionEpoch
  );
}

function serializeInteractionPush(identity, operation) {
  const key = interactionKey(identity);
  const previous = interactionPushChains.get(key) ?? Promise.resolve();
  const current = previous.catch(() => undefined).then(operation);
  interactionPushChains.set(key, current);
  return current.finally(() => {
    if (interactionPushChains.get(key) === current) interactionPushChains.delete(key);
  });
}

/**
 * A push from the gateway (daemon/push.ts). Nothing is shown when the user
 * is looking at the very session it is about.
 */
self.addEventListener('push', (event) => {
  let message;
  try {
    message = event.data?.json();
  } catch {
    return;
  }
  event.waitUntil(
    (async () => {
      if (message?.kind === 'interaction_refresh') {
        if (typeof message.sessionId !== 'string' || !message.sessionId) return;
        const windows = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
        for (const client of windows)
          client.postMessage({ type: 'INTERACTION_REFRESH', sessionId: message.sessionId });
        return;
      }
      if (message?.kind === 'interaction_answered') {
        const identity = interactionIdentity(message);
        if (!identity) return;
        await serializeInteractionPush(identity, async () => {
          await rememberResolvedInteraction(identity);
          const tag = interactionTag(identity);
          const notifications = await self.registration.getNotifications({ tag });
          for (const notification of notifications) {
            if (sameInteraction(notification.data?.interaction, identity)) notification.close();
          }
        });
        return;
      }
      if (message?.kind === 'interaction_created') {
        const identity = interactionIdentity(message);
        if (!identity || !message.title) return;
        await serializeInteractionPush(identity, async () => {
          if (await interactionWasResolved(identity)) return;
          const windows = await self.clients.matchAll({
            type: 'window',
            includeUncontrolled: true,
          });
          const watching = windows.some(
            (client) =>
              client.focused &&
              client.visibilityState === 'visible' &&
              new URL(client.url).searchParams.get('session') === identity.sessionId,
          );
          if (watching) return;
          await self.registration.showNotification(message.title, {
            body: message.body ?? '',
            tag: interactionTag(identity),
            renotify: true,
            icon: '/icons/icon-192.png',
            badge: '/icons/icon-192.png',
            timestamp: message.at,
            data: { target: { sessionId: identity.sessionId }, interaction: identity },
          });
        });
        return;
      }
      if (!message?.title) return;
      const sessionId = message.target?.sessionId;
      if (sessionId) {
        const windows = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
        const watching = windows.some(
          (client) =>
            client.focused &&
            client.visibilityState === 'visible' &&
            new URL(client.url).searchParams.get('session') === sessionId,
        );
        if (watching) return;
      }
      await self.registration.showNotification(message.title, {
        body: message.body ?? '',
        tag: message.tag,
        renotify: true,
        icon: '/icons/icon-192.png',
        badge: '/icons/icon-192.png',
        timestamp: message.at,
        data: { target: message.target ?? null },
      });
    })(),
  );
});

/** Open what the notification is about: in an open window if there is one. */
self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const target = event.notification.data?.target ?? null;
  const rawInteraction = event.notification.data?.interaction;
  const interaction = interactionIdentity(rawInteraction);
  const exactInteraction = interaction?.sessionId === target?.sessionId ? interaction : undefined;
  event.waitUntil(
    (async () => {
      const windows = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
      const client = windows.find((item) => new URL(item.url).origin === self.location.origin);
      if (client) {
        await client.focus();
        client.postMessage({ type: 'OPEN_TARGET', target, interaction: exactInteraction });
        return;
      }
      await self.clients.openWindow(targetUrl(target, exactInteraction));
    })(),
  );
});
