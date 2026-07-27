import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

const gcsTarget = process.env.GCS_PROXY_TARGET || 'http://localhost:4443'

// https://vite.dev/config/
export default defineConfig({
  plugins: [react()],
  server: {
    host: '0.0.0.0',
    port: 5173,
    strictPort: true,
    proxy: {
      '/storage': {
        target: gcsTarget,
        changeOrigin: true,
      },
    },
  },
})
