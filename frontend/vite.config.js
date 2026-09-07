import react, { reactCompilerPreset } from '@vitejs/plugin-react'
import babel from '@rolldown/plugin-babel'
import tailwindcss from '@tailwindcss/vite'
import { defineConfig } from 'vite'


// El preamble inline de react-refresh viola script-src 'self', asi que en dev
// servimos el HTML sin el meta CSP. En build el meta se conserva intacto.
const stripCspInDev = {
  name: 'strip-csp-in-dev',
  apply: 'serve',
  transformIndexHtml: (html) =>
    html.replace(/\s*<meta http-equiv="Content-Security-Policy"[^>]*>/, ''),
}

// https://vite.dev/config/
export default defineConfig({
  plugins: [
    react(),
    tailwindcss(),
    stripCspInDev,
    babel({ presets: [reactCompilerPreset()] })
  ],
})
