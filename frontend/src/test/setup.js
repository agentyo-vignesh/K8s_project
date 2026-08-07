import '@testing-library/jest-dom/vitest';
import { afterEach, beforeEach, vi } from 'vitest';
import { cleanup } from '@testing-library/react';

/**
 * Global test setup.
 *
 * `window.__APP_CONFIG__` is normally injected by the container entrypoint; tests provide it so
 * `config.js` resolves the same way it does in a browser.
 */
window.__APP_CONFIG__ = { apiBaseUrl: '', appEnv: 'test' };

// jsdom does not implement matchMedia, which MUI's useMediaQuery calls during layout rendering.
if (!window.matchMedia) {
  window.matchMedia = (query) => ({
    matches: false,
    media: query,
    onchange: null,
    addListener: () => {},
    removeListener: () => {},
    addEventListener: () => {},
    removeEventListener: () => {},
    dispatchEvent: () => false,
  });
}

beforeEach(() => {
  localStorage.clear();
});

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});
