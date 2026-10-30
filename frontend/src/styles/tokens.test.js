// Los tokens son la única fuente de color (styles/tokens.css): cada color existe
// en claro y en oscuro, y los pares de uso real cumplen WCAG AA.
import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

// vitest corre desde frontend/ (jsdom no deja usar import.meta.url con file:)
const css = readFileSync("src/styles/tokens.css", "utf8");

function bloque(texto) {
  const t = {};
  for (const m of texto.matchAll(/(--c-[a-z0-9-]+):\s*([^;]+);/g)) t[m[1]] = m[2].trim();
  return t;
}
const iOscuro = css.indexOf("@media (prefers-color-scheme: dark)");
const claro = bloque(css.slice(css.indexOf(":root {"), iOscuro));
const oscuro = { ...claro, ...bloque(css.slice(iOscuro)) };

const esColor = (v) => /^(#|rgba?\()/.test(v);

function aRgba(v) {
  if (v.startsWith("#")) {
    const h = v.slice(1);
    const n = h.length === 3 ? [...h].map((c) => c + c).join("") : h;
    return [0, 2, 4].map((i) => parseInt(n.slice(i, i + 2), 16)).concat(1);
  }
  const [r, g, b, a = 1] = v.match(/[\d.]+/g).map(Number);
  return [r, g, b, a];
}
const sobre = (fg, bg) => {
  const [r, g, b, a] = aRgba(fg);
  const [R, G, B] = aRgba(bg);
  return [r * a + R * (1 - a), g * a + G * (1 - a), b * a + B * (1 - a)];
};
const lum = ([r, g, b]) => {
  const f = (c) => ((c /= 255) <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4);
  return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b);
};
function contraste(tokens, fg, bg) {
  const fondo = aRgba(tokens[bg]).slice(0, 3);
  const L1 = lum(sobre(tokens[fg], `rgb(${fondo.join(",")})`));
  const L2 = lum(fondo);
  return (Math.max(L1, L2) + 0.05) / (Math.min(L1, L2) + 0.05);
}

const PARES = [
  // [texto, fondo, mínimo]
  ["--c-text", "--c-surface", 4.5],
  ["--c-text", "--c-bg", 4.5],
  ["--c-text-2", "--c-surface", 4.5],
  ["--c-text-3", "--c-bg", 4.5],
  ["--c-accent-text", "--c-surface", 4.5],
  ["--c-cta-fg", "--c-cta", 4.5],
  ["--c-placeholder", "--c-field-bg", 4.5],
  ["--c-error", "--c-surface", 4.5],
  ["--c-neutro-fg", "--c-neutro-bg", 4.5],
  ["--c-progreso-fg", "--c-progreso-bg", 4.5],
  ["--c-resuelto-fg", "--c-resuelto-bg", 4.5],
  ["--c-adverso-fg", "--c-adverso-bg", 4.5],
  // Borde de un campo contra la superficie: 3:1 (WCAG 1.4.11)
  ["--c-field-border", "--c-surface", 3],
];

describe("tokens de diseño", () => {
  it("el oscuro redefine superficies, texto y estados (no hereda el claro)", () => {
    const deben = Object.keys(claro).filter((k) =>
      /^--c-(bg|surface|surface-2|field-bg|text|text-2|text-3|cta|cta-fg|inverso|neutro-bg|progreso-bg|resuelto-bg|adverso-bg|error)$/.test(k),
    );
    expect(deben.length).toBeGreaterThan(10);
    expect(deben.filter((k) => oscuro[k] === claro[k])).toEqual([]);
  });

  for (const [tema, tokens] of [["claro", claro], ["oscuro", oscuro]]) {
    for (const [fg, bg, min] of PARES) {
      it(`${tema}: ${fg} sobre ${bg} ≥ ${min}:1`, () => {
        expect(contraste(tokens, fg, bg)).toBeGreaterThanOrEqual(min);
      });
    }
  }
});
