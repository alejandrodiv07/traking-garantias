import { defineConfig } from "vitest/config";
import react from "@vitejs/plugin-react";

// Config de pruebas separada del build: el build lleva el react-compiler y
// tailwind, que aquí no aportan nada y ralentizan cada corrida. Solo se que
// el JSX compile y que el DOM sea real (jsdom).
export default defineConfig({
  plugins: [react()],
  esbuild: { jsx: "automatic" },
  test: {
    environment: "jsdom",
    // globals: true deja el afterEach global visible a testing-library, que lo
    // usa para desmontar el árbol entre tests (sin él, cada render queda vivo
    // y los queries duplican elementos).
    globals: true,
    // Las Edge Functions (Deno) se prueban aquí con `Deno` y supabase-js
    // simulados: no hay runtime Deno en esta máquina ni en CI.
    include: ["src/**/*.test.jsx", "../supabase/functions/**/*.test.ts"],
    setupFiles: ["./src/test/setup.js"],
  },
});