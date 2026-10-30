// Pruebas de tableroService (Tarea 20 del plan).
import { beforeEach, describe, expect, it, vi } from "vitest";

const fakes = vi.hoisted(() => {
  const cadena = { select: vi.fn() };
  return { cadena };
});

vi.mock("../../lib/supabaseClient.js", () => ({
  supabase: { from: () => fakes.cadena },
}));

import { listarTablero } from "./tableroService.js";

beforeEach(() => {
  // cadena encadenable: select → order → order → limit → or/ilike/eq
  for (const m of ["order", "ilike", "eq", "or", "limit"]) {
    fakes.cadena[m] = vi.fn().mockReturnValue(fakes.cadena);
  }
  fakes.cadena.select.mockReset().mockReturnValue(fakes.cadena);
});

describe("listarTablero", () => {
  it("pide la vista y devuelve las filas", async () => {
    fakes.cadena.then = undefined;
    const r = await listarTablero({});
    expect(r.ok).toBe(true);
    expect(r.filas).toEqual([]);
  });

  it("con búsqueda consulta por serial, cliente, documento, factura y registro", async () => {
    await listarTablero({ busqueda: "RT5" });
    const filtro = fakes.cadena.or.mock.calls[0][0];
    expect(filtro).toContain("numero_registro.ilike");
    for (const campo of ["serial", "cliente", "documento", "numero_soporte"]) {
      expect(filtro).toContain(`${campo}.ilike`);
    }
  });

  it("filtra por estado y por urgencia", async () => {
    await listarTablero({ estado: "RECIBIDO", urgencia: "CRITICA" });
    const eqs = fakes.cadena.eq.mock.calls.map((c) => c[0]).sort();
    expect(eqs).toEqual(["estado", "nivel_vigencia"]);
  });
});