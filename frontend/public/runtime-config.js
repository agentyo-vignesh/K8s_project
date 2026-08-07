// Development placeholder.
//
// In a container this file is overwritten at start-up by docker-entrypoint.sh, which renders it
// from the API_BASE_URL and APP_ENV environment variables. It exists in `public/` so that
// `npm run dev` and `npm run preview` serve it instead of returning 404 for the <script> tag in
// index.html, and so Vite copies it verbatim rather than attempting to bundle it.
//
// The empty apiBaseUrl makes the browser issue same-origin requests, which the Vite dev-server
// proxy forwards to the middleware (see vite.config.js).
window.__APP_CONFIG__ = {
  apiBaseUrl: '',
  appEnv: 'dev',
};
