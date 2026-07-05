/// <reference types="vitest/config" />
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Dev server proxies the admin API to a locally running relay so the SPA is
// same-origin with /v1/admin in development, exactly as it is in production
// behind Caddy. No CORS anywhere.
export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    proxy: {
      "/v1/admin": {
        target: "http://127.0.0.1:8080",
        changeOrigin: false,
      },
    },
  },
  build: {
    // Recharts is only used by the dashboard; route-level code splitting in
    // App.tsx keeps it out of the initial bundle already, but give the vendor
    // chunks stable names for cacheability.
    rollupOptions: {
      output: {
        manualChunks: {
          recharts: ["recharts"],
        },
      },
    },
  },
  test: {
    environment: "jsdom",
    globals: true,
    setupFiles: ["src/test/setup.ts"],
    css: false,
  },
});
