import process from 'node:process';

import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

/**
 * Vite configuration.
 *
 * The dev server proxies `/api` to the middleware so a developer runs the UI on :5173 against the
 * Compose stack with no CORS configuration and no hardcoded host in the code.
 *
 * The production build emits a static bundle only. The API base URL is *not* baked in at build time:
 * it is read at runtime from `window.__APP_CONFIG__`, which the container entrypoint renders from
 * environment variables. That is what lets one image be promoted from dev to prod unchanged.
 */
export default defineConfig({
  plugins: [react()],

  server: {
    port: 5173,
    strictPort: true,
    proxy: {
      '/api': {
        target: process.env.VITE_DEV_API_TARGET || 'http://localhost:8080',
        changeOrigin: true,
      },
    },
  },

  build: {
    outDir: 'dist',
    sourcemap: true,
    // Chunked so a change to application code does not invalidate the vendor bundle in every
    // browser cache on every release.
    rollupOptions: {
      output: {
        manualChunks: {
          react: ['react', 'react-dom', 'react-router-dom'],
          mui: ['@mui/material', '@mui/icons-material'],
        },
      },
    },
  },

  test: {
    environment: 'jsdom',
    globals: true,
    setupFiles: './src/test/setup.js',
    css: false,

    coverage: {
      provider: 'v8',
      // lcov is what SonarQube reads; text keeps the number visible in the log.
      reporter: ['text', 'lcov'],
      reportsDirectory: './coverage',
      // Without this only files a test imported are counted, so an untested
      // file improves coverage by being absent from the report.
      all: true,
      include: ['src/**/*.{js,jsx}'],
    },
  },
});
