import { defineConfig } from "vitest/config";

// `defineConfig` viene de `vitest/config`, no de `vite`: el proyecto usa
// vite@8 (rolldown-vite) para su propio dev/build, pero Vitest trae
// internamente su propia copia de Vite para transformar los archivos de
// prueba (vite-node). Mezclar ambas versiones -- importar `defineConfig`
// de `vite` y aplicar el plugin `react()` sobre la copia de Vitest --
// producía un fallo silencioso: el JSX quedaba sin transformar
// ("React is not defined") porque el plugin no enganchaba con el pipeline
// de Vitest. Sin el plugin, Vitest usa esbuild directamente para `.jsx`
// con el runtime automático como valor por defecto, que es exactamente lo
// que este proyecto necesita para las pruebas (no para el build real,
// donde `vite.config.js` sigue intacto).
export default defineConfig({
  esbuild: {
    jsx: "automatic",
    jsxImportSource: "react",
  },
  test: {
    environment: "jsdom",
    globals: true,
    setupFiles: ["./src/test/setup.js"],
    css: false,
    clearMocks: true,
  },
});
