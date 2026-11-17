/**
 * Every build ships a service worker file that differs from the previous one.
 *
 * Browsers decide whether a new service worker exists by comparing the bytes of
 * `sw.js`. That file is copied as it is, so a build that changed the app but not
 * the worker would leave pages that are already open without any sign of an
 * update: they would keep the old shell until they were reloaded by chance. The
 * build writes an identifier derived from the files it produced into `sw.js`,
 * so an open page sees a new worker, installs it and offers the update (see
 * `registerPwa` in src/lib/pwa.ts); the worker's shell cache is then replaced.
 */
export const BUILD_ID_MARKER = '__PIRC_BUILD_ID__';

/** FNV-1a over the UTF-16 code units of `text`, 32 bit, from the given offset basis. */
function fnv1a(text: string, basis: number): number {
  let hash = basis;
  for (let index = 0; index < text.length; index++) {
    hash ^= text.charCodeAt(index);
    hash = Math.imul(hash, 0x01000193);
  }
  return hash >>> 0;
}

/** A short, stable identifier of the strings given (two FNV-1a passes with different seeds). */
export function buildId(parts: string[]): string {
  const text = parts.join('\u0000');
  const hex = (value: number) => value.toString(16).padStart(8, '0');
  return hex(fnv1a(text, 0x811c9dc5)) + hex(fnv1a(`${text.length}:${text}`, 0x9747b28c));
}

/** `sw.js` with this build's identifier in place of the marker. */
export function stampServiceWorker(source: string, id: string): string {
  if (!source.includes(BUILD_ID_MARKER)) throw new Error('sw.js has no build identifier marker');
  return source.split(BUILD_ID_MARKER).join(id);
}
