import { defineConfig } from '@rsbuild/core';
import { pluginReact } from '@rsbuild/plugin-react';

// R4/11B: bundler = Rsbuild (bukan Vite). Tailwind 3.4 lewat postcss.config.cjs (terbaca otomatis — T-001).
export default defineConfig({
  plugins: [pluginReact()],
  html: { title: 'Kegiatan Tim IT Vora' },
  server: { proxy: { '/api': 'http://127.0.0.1:8320' } },
});
