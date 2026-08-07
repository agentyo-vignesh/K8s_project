/**
 * The single Axios instance every API call goes through.
 *
 * Three responsibilities live here so no call site has to repeat them:
 *
 *  - attach the bearer token,
 *  - attach a request id so a browser error can be matched to a server log line,
 *  - refresh the access token once on a 401 and replay the original request.
 *
 * The refresh is deduplicated: if five requests 401 at the same moment, one refresh runs and the
 * other four wait for it. Without that, a page load with several parallel requests would fire several
 * refreshes, and because refresh tokens rotate server-side, all but one would be rejected and the
 * user would be logged out for no reason.
 */
import axios from 'axios';
import { config, storageKeys } from '../config';

const REQUEST_ID_HEADER = 'X-Request-Id';

export const tokenStorage = {
  getAccessToken: () => localStorage.getItem(storageKeys.accessToken),
  getRefreshToken: () => localStorage.getItem(storageKeys.refreshToken),
  setTokens: (accessToken, refreshToken) => {
    localStorage.setItem(storageKeys.accessToken, accessToken);
    if (refreshToken) {
      localStorage.setItem(storageKeys.refreshToken, refreshToken);
    }
  },
  setUser: (user) => localStorage.setItem(storageKeys.user, JSON.stringify(user)),
  getUser: () => {
    const raw = localStorage.getItem(storageKeys.user);
    if (!raw) return null;
    try {
      return JSON.parse(raw);
    } catch {
      // Corrupt entry: treat it as absent rather than crashing the app on boot.
      return null;
    }
  },
  clear: () => {
    localStorage.removeItem(storageKeys.accessToken);
    localStorage.removeItem(storageKeys.refreshToken);
    localStorage.removeItem(storageKeys.user);
  },
};

/** Called when refresh fails; set by AuthProvider so this module needs no router import. */
let onAuthenticationLost = () => {};

export function setAuthenticationLostHandler(handler) {
  onAuthenticationLost = handler;
}

export const apiClient = axios.create({
  baseURL: `${config.apiBaseUrl}${config.apiPrefix}`,
  timeout: 30000,
  headers: { 'Content-Type': 'application/json' },
});

function newRequestId() {
  if (typeof crypto !== 'undefined' && crypto.randomUUID) {
    return crypto.randomUUID();
  }
  return `web-${Date.now()}-${Math.random().toString(16).slice(2, 10)}`;
}

apiClient.interceptors.request.use((request) => {
  const token = tokenStorage.getAccessToken();
  if (token) {
    request.headers.Authorization = `Bearer ${token}`;
  }
  request.headers[REQUEST_ID_HEADER] = newRequestId();
  return request;
});

let refreshInFlight = null;

async function refreshAccessToken() {
  const refreshToken = tokenStorage.getRefreshToken();
  if (!refreshToken) {
    throw new Error('No refresh token available');
  }

  // A bare axios call, not apiClient: going through the instance would re-enter this interceptor
  // and, on a failing refresh, loop.
  const response = await axios.post(
    `${config.apiBaseUrl}${config.apiPrefix}/auth/refresh`,
    { refreshToken },
    { headers: { 'Content-Type': 'application/json' }, timeout: 15000 },
  );
  tokenStorage.setTokens(response.data.accessToken, response.data.refreshToken);
  if (response.data.user) {
    tokenStorage.setUser(response.data.user);
  }
  return response.data.accessToken;
}

apiClient.interceptors.response.use(
  (response) => {
    // An API reply that arrives as HTML never reached the API. nginx serves the
    // SPA for any path it does not recognise, so /api/... comes back as
    // index.html with status 200 whenever nothing routes /api to the middleware
    // - no Ingress in the cluster, or a wrong apiBaseUrl.
    //
    // Status 200 means Axios resolves happily and the caller reads fields off a
    // string of HTML. The failure then surfaces somewhere unrelated, as
    // "Cannot read properties of undefined", and points at the wrong thing.
    const contentType = response.headers?.['content-type'] ?? '';
    if (contentType.includes('text/html')) {
      const error = new Error('API request was answered with HTML');
      error.isHtmlResponse = true;
      error.config = response.config;
      return Promise.reject(error);
    }
    return response;
  },
  async (error) => {
    const { response, config: originalRequest } = error;

    if (!response || !originalRequest) {
      // Network failure or timeout: nothing to refresh, so surface it as-is.
      return Promise.reject(error);
    }

    const isAuthEndpoint = originalRequest.url?.includes('/auth/');
    if (response.status !== 401 || originalRequest._retried || isAuthEndpoint) {
      return Promise.reject(error);
    }

    originalRequest._retried = true;
    try {
      // Shared promise, so concurrent 401s cause exactly one refresh.
      refreshInFlight = refreshInFlight || refreshAccessToken();
      const accessToken = await refreshInFlight;
      originalRequest.headers.Authorization = `Bearer ${accessToken}`;
      return apiClient(originalRequest);
    } catch (refreshError) {
      tokenStorage.clear();
      onAuthenticationLost();
      return Promise.reject(refreshError);
    } finally {
      refreshInFlight = null;
    }
  },
);

/**
 * Turns an Axios error into a message worth showing a user.
 *
 * Prefers the server's `message` (the API returns a human-safe string and keeps internals in the
 * logs) and falls back to something actionable rather than "Request failed with status code 500".
 */
export function describeError(error, fallback = 'Something went wrong. Please try again.') {
  if (!error) return fallback;

  const data = error.response?.data;
  if (data?.fieldErrors?.length) {
    return data.fieldErrors.map((violation) => `${violation.field}: ${violation.message}`).join('; ');
  }
  if (data?.message) {
    return data.message;
  }
  if (error.isHtmlResponse) {
    return 'The API is not reachable at this address - the server returned a web page instead of data. Check that /api is routed to the middleware.';
  }
  if (error.code === 'ECONNABORTED') {
    return 'The request timed out. The server may be busy; please try again.';
  }
  if (!error.response) {
    return 'Cannot reach the server. Check that the middleware is running.';
  }
  return fallback;
}

/** The request id the server echoed, for quoting in a bug report. */
export function requestIdOf(error) {
  return error?.response?.data?.requestId || error?.response?.headers?.['x-request-id'] || null;
}
