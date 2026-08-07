/**
 * Runtime configuration.
 *
 * Read from `window.__APP_CONFIG__`, which the container entrypoint renders from environment
 * variables at start. Nothing environment-specific is baked into the bundle, so the image built and
 * tested in CI is byte-for-byte the image promoted to production.
 *
 * An empty `apiBaseUrl` means same-origin: the Vite dev proxy handles it locally, and behind an
 * Ingress that routes `/api` to the middleware it is also correct in production.
 */
const runtime = typeof window !== 'undefined' ? window.__APP_CONFIG__ || {} : {};

export const config = {
  apiBaseUrl: (runtime.apiBaseUrl || '').replace(/\/+$/, ''),
  appEnv: runtime.appEnv || 'dev',
  apiPrefix: '/api/v1',
};

export const isProduction = config.appEnv === 'prod';

/** Storage keys, centralised so a rename cannot leave one reader behind. */
export const storageKeys = {
  accessToken: 'aip.accessToken',
  refreshToken: 'aip.refreshToken',
  user: 'aip.user',
};
