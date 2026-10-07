import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// `npm run dev` proxies /api to the FastAPI backend on :8000.
// Set VITE_API_MODE=mock (see .env.mock) to run with the built-in mock API instead.
export default defineConfig({
  plugins: [react()],
  base: './',
  server: {
    port: 5173,
    proxy: {
      '^/api/(login|register|me|logout|auth-health)$': process.env.COUNTERSIGN_AUTH_URL || 'http://127.0.0.1:3000',
      '/api': process.env.COUNTERSIGN_BACKEND_URL || 'http://127.0.0.1:8000',
    },
  },
  build: {
    outDir: 'dist',
    chunkSizeWarningLimit: 900,
  },
})
