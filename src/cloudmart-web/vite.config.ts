import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// In development the SPA calls relative /api URLs and Vite proxies them to the API, so no CORS is needed locally.
// In Azure, public/config.json is rewritten at deploy time with the real API URL (build once, deploy many).
export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    proxy: {
      '/api': 'http://localhost:5080',
      '/health': 'http://localhost:5080',
    },
  },
});
