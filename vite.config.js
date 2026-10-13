import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

export default defineConfig({
  // GitHub Pages publishes this repository under /episode/.
  base: '/episode/',
  plugins: [react()],
  build: { outDir: 'dist', sourcemap: false }
});