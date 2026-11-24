import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import tailwindcss from '@tailwindcss/vite';

export default defineConfig({
  root: 'web',
  plugins: [react(), tailwindcss()],
  server: { port: 5173, proxy: { '/api': `http://127.0.0.1:${process.env.API_PORT || 3001}` }, strictPort: true },
  build: { outDir: '../dist', emptyOutDir: true },
});
