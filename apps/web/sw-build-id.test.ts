import { describe, expect, it } from 'vitest';
import { BUILD_ID_MARKER, buildId, stampServiceWorker } from './sw-build-id';

describe('service worker build identifier', () => {
  it('is stable for the same files and different when any file differs', () => {
    const files = ['assets/index-AAAA1111.js', 'assets/index-BBBB2222.css', 'index.html:<html>'];
    expect(buildId(files)).toBe(buildId([...files]));
    expect(buildId(files)).toMatch(/^[0-9a-f]{16}$/);
    expect(buildId(['assets/index-AAAA1112.js', ...files.slice(1)])).not.toBe(buildId(files));
    expect(buildId([...files, 'assets/extra-CCCC3333.js'])).not.toBe(buildId(files));
  });

  it('stamps every marker, and refuses a worker without one', () => {
    const source = `const BUILD_ID = '${BUILD_ID_MARKER}'; // ${BUILD_ID_MARKER}`;
    const stamped = stampServiceWorker(source, 'abcdef0123456789');
    expect(stamped).toBe("const BUILD_ID = 'abcdef0123456789'; // abcdef0123456789");
    expect(stamped).not.toContain(BUILD_ID_MARKER);
    expect(() => stampServiceWorker('self.skipWaiting()', 'x')).toThrow(/marker/);
  });
});
